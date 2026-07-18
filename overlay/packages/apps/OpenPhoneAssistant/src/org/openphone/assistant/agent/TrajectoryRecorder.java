package org.openphone.assistant.agent;

import android.content.Context;
import android.content.ContentValues;
import android.net.Uri;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Base64;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.surface.AdaptiveSurface;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public final class TrajectoryRecorder {
    private static final String TAG = "OpenPhoneTrajectory";
    private static final String DIR_NAME = "openphone-trajectories";

    private final File mSessionDir;
    private final File mEventsFile;
    private final long mStartedAtMillis;
    private int mEventIndex;
    private int mScreenshotIndex;

    private TrajectoryRecorder(File sessionDir) {
        mSessionDir = sessionDir;
        mEventsFile = new File(sessionDir, "events.jsonl");
        mStartedAtMillis = System.currentTimeMillis();
    }

    public static TrajectoryRecorder start(Context context, String taskId, String goal,
            String provider, String model, boolean cloudModel, String disclosure) {
        File root = new File(context.getFilesDir(), DIR_NAME);
        if (!root.exists() && !root.mkdirs()) {
            Log.w(TAG, "Failed to create trajectory root: " + root);
        }
        String timestamp = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
                .format(new Date());
        String safeTaskId = sanitize(taskId == null ? "task" : taskId);
        File sessionDir = new File(root, timestamp + "-" + safeTaskId);
        if (!sessionDir.exists() && !sessionDir.mkdirs()) {
            Log.w(TAG, "Failed to create trajectory dir: " + sessionDir);
        }

        TrajectoryRecorder recorder = new TrajectoryRecorder(sessionDir);
        try {
            recorder.append("task_started", new JSONObject()
                    .put("task_id", taskId == null ? "" : taskId)
                    .put("goal", goal == null ? "" : goal)
                    .put("provider", provider == null ? "" : provider)
                    .put("model", model == null ? "" : model)
                    .put("cloud_model", cloudModel)
                    .put("disclosure", disclosure == null ? "" : disclosure));
        } catch (JSONException e) {
            Log.w(TAG, "Failed to write trajectory start event", e);
        }
        return recorder;
    }

    public synchronized void recordToolCall(String toolName, String argumentsJson) {
        try {
            append("tool_call", new JSONObject()
                    .put("tool", toolName == null ? "" : toolName)
                    .put("arguments", parseOrRaw(argumentsJson)));
        } catch (JSONException e) {
            Log.w(TAG, "Failed to record tool call", e);
        }
    }

    public synchronized void recordToolResult(String toolName, String resultJson) {
        try {
            append("tool_result", new JSONObject()
                    .put("tool", toolName == null ? "" : toolName)
                    .put("result", sanitizeResultForStorage(resultJson)));
        } catch (JSONException e) {
            Log.w(TAG, "Failed to record tool result", e);
        }
    }

    public synchronized void recordAgentResult(String resultJson) {
        try {
            JSONObject summary = new JSONObject()
                    .put("duration_ms", System.currentTimeMillis() - mStartedAtMillis)
                    .put("result", parseOrRaw(resultJson));
            append("agent_result", summary);
            writeFile(new File(mSessionDir, "summary.json"), summary.toString(2));
        } catch (JSONException e) {
            Log.w(TAG, "Failed to record agent result", e);
        }
    }

    public synchronized void recordSurfacePresented(AdaptiveSurface surface) {
        if (surface == null) {
            return;
        }
        try {
            append("surface_presented", new JSONObject()
                    .put("surface_id", surface.surfaceId)
                    .put("revision", surface.revision)
                    .put("session_id", surface.sessionId)
                    .put("runtime", surface.runtime)
                    .put("presentation", surface.presentation)
                    .put("sensitivity", surface.sensitivity));
        } catch (JSONException e) {
            Log.w(TAG, "Failed to record surface presentation", e);
        }
    }

    public String sessionPath() {
        return mSessionDir.getAbsolutePath();
    }

    public static String exportLatestToDownloads(Context context) throws IOException {
        File latest = latestSessionDir(context);
        if (latest == null) {
            return "No trajectory has been recorded yet.";
        }

        String displayName = latest.getName() + ".zip";
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
        values.put(MediaStore.MediaColumns.MIME_TYPE, "application/zip");
        values.put(MediaStore.MediaColumns.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + "/OpenPhone");
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);

        Uri uri = context.getContentResolver().insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        if (uri == null) {
            throw new IOException("MediaStore did not return an export URI");
        }

        try (OutputStream stream = context.getContentResolver().openOutputStream(uri)) {
            if (stream == null) {
                throw new IOException("Could not open export URI");
            }
            try (ZipOutputStream zip = new ZipOutputStream(stream)) {
                zipDirectory(latest, latest.getName(), zip);
            }
        } catch (IOException e) {
            context.getContentResolver().delete(uri, null, null);
            throw e;
        }

        ContentValues done = new ContentValues();
        done.put(MediaStore.MediaColumns.IS_PENDING, 0);
        context.getContentResolver().update(uri, done, null, null);
        return "Exported " + displayName + " to Downloads/OpenPhone.";
    }

    private void append(String eventType, JSONObject payload) throws JSONException {
        JSONObject event = new JSONObject()
                .put("schema", "openphone.trajectory_event.v1")
                .put("index", mEventIndex++)
                .put("timestamp_ms", System.currentTimeMillis())
                .put("event", eventType)
                .put("payload", payload);
        appendLine(mEventsFile, event.toString());
    }

    private Object sanitizeResultForStorage(String resultJson) throws JSONException {
        Object parsed = parseOrRaw(resultJson);
        if (parsed instanceof JSONObject) {
            return sanitizeObject((JSONObject) parsed);
        }
        if (parsed instanceof JSONArray) {
            return sanitizeArray((JSONArray) parsed);
        }
        return parsed;
    }

    private JSONObject sanitizeObject(JSONObject object) throws JSONException {
        JSONObject copy = new JSONObject(object.toString());
        JSONObject screenshot = copy.optJSONObject("screenshot");
        if (screenshot != null) {
            saveScreenshotPayload(screenshot);
        }
        JSONArray names = copy.names();
        if (names == null) {
            return copy;
        }
        for (int i = 0; i < names.length(); i++) {
            String name = names.getString(i);
            Object value = copy.opt(name);
            if (isSecretField(name)) {
                copy.put(name, "<redacted>");
            } else if (value instanceof JSONObject) {
                copy.put(name, sanitizeObject((JSONObject) value));
            } else if (value instanceof JSONArray) {
                copy.put(name, sanitizeArray((JSONArray) value));
            }
        }
        return copy;
    }

    private JSONArray sanitizeArray(JSONArray array) throws JSONException {
        JSONArray copy = new JSONArray();
        for (int i = 0; i < array.length(); i++) {
            Object value = array.opt(i);
            if (value instanceof JSONObject) {
                copy.put(sanitizeObject((JSONObject) value));
            } else if (value instanceof JSONArray) {
                copy.put(sanitizeArray((JSONArray) value));
            } else {
                copy.put(value);
            }
        }
        return copy;
    }

    private void saveScreenshotPayload(JSONObject screenshot) throws JSONException {
        String data = screenshot.optString("data", "");
        if (data.isEmpty() || !"base64".equals(screenshot.optString("encoding"))) {
            return;
        }
        String mimeType = screenshot.optString("mime_type", "image/jpeg");
        String extension = mimeType.contains("png") ? ".png" : ".jpg";
        String filename = String.format(Locale.US, "screenshot_%03d%s",
                mScreenshotIndex++, extension);
        File screenshotFile = new File(mSessionDir, filename);
        try {
            byte[] bytes = Base64.decode(data, Base64.DEFAULT);
            try (FileOutputStream stream = new FileOutputStream(screenshotFile)) {
                stream.write(bytes);
            }
            screenshot.put("data", "<stored:" + filename + ">");
            screenshot.put("file", filename);
            screenshot.put("bytes", bytes.length);
        } catch (IllegalArgumentException | IOException e) {
            screenshot.put("data", "<base64 chars=" + data.length() + ">");
            screenshot.put("store_error", e.getClass().getSimpleName());
            Log.w(TAG, "Failed to persist screenshot payload", e);
        }
    }

    private static Object parseOrRaw(String json) throws JSONException {
        if (json == null || json.trim().isEmpty()) {
            return "";
        }
        String trimmed = json.trim();
        if (trimmed.startsWith("{")) {
            return new JSONObject(trimmed);
        }
        if (trimmed.startsWith("[")) {
            return new JSONArray(trimmed);
        }
        return trimmed;
    }

    private static boolean isSecretField(String name) {
        String lower = name == null ? "" : name.toLowerCase(Locale.US);
        return lower.contains("api_key") || lower.contains("authorization")
                || lower.contains("token") || lower.contains("secret");
    }

    private static String sanitize(String value) {
        return value.replaceAll("[^A-Za-z0-9._-]", "_");
    }

    private static void appendLine(File file, String text) {
        try (FileOutputStream stream = new FileOutputStream(file, true)) {
            stream.write(text.getBytes(StandardCharsets.UTF_8));
            stream.write('\n');
        } catch (IOException e) {
            Log.w(TAG, "Failed to append trajectory event", e);
        }
    }

    private static void writeFile(File file, String text) {
        try (FileOutputStream stream = new FileOutputStream(file, false)) {
            stream.write(text.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            Log.w(TAG, "Failed to write trajectory file", e);
        }
    }

    private static File latestSessionDir(Context context) {
        File root = new File(context.getFilesDir(), DIR_NAME);
        File[] sessions = root.listFiles();
        if (sessions == null || sessions.length == 0) {
            return null;
        }
        File latest = null;
        for (File session : sessions) {
            if (!session.isDirectory()) {
                continue;
            }
            if (latest == null || session.getName().compareTo(latest.getName()) > 0) {
                latest = session;
            }
        }
        return latest;
    }

    private static void zipDirectory(File file, String entryName, ZipOutputStream zip)
            throws IOException {
        if (file.isDirectory()) {
            String directoryName = entryName.endsWith("/") ? entryName : entryName + "/";
            zip.putNextEntry(new ZipEntry(directoryName));
            zip.closeEntry();
            File[] children = file.listFiles();
            if (children == null) {
                return;
            }
            for (File child : children) {
                zipDirectory(child, directoryName + child.getName(), zip);
            }
            return;
        }

        zip.putNextEntry(new ZipEntry(entryName));
        byte[] buffer = new byte[8192];
        try (FileInputStream input = new FileInputStream(file)) {
            int read;
            while ((read = input.read(buffer)) != -1) {
                zip.write(buffer, 0, read);
            }
        }
        zip.closeEntry();
    }
}
