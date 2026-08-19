package org.openphone.assistant;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import org.openphone.assistant.commitments.CommitmentRecord;
import org.openphone.assistant.jobs.AgentJobRecord;
import org.openphone.assistant.watchers.OpenPhoneWatcherReceiver;
import org.openphone.assistant.watchers.WatcherRecord;
import org.openphone.assistant.watchers.OpenPhoneWatcherScheduler;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public final class OpenPhoneNotificationController {
    static final String CHANNEL_ID = "openphone_agent";
    private static final String COMMITMENT_CHANNEL_ID = "openphone_commitments";
    private static final String WATCHER_CHANNEL_ID = "openphone_watchers";
    private static final String AGENT_JOB_CHANNEL_ID = "openphone_agent_jobs";
    private static final String RUNTIME_CHANNEL_ID = "openphone_runtimes";
    static final String ACTION_START = "org.openphone.assistant.action.START";
    static final String ACTION_STOP = "org.openphone.assistant.action.STOP";
    static final String ACTION_OPEN = "org.openphone.assistant.action.OPEN";
    static final String ACTION_EXTERNAL_APPROVE =
            "org.openphone.assistant.action.EXTERNAL_APPROVE";
    static final String ACTION_EXTERNAL_DENY =
            "org.openphone.assistant.action.EXTERNAL_DENY";
    static final String ACTION_BACKGROUND_APPROVE =
            "org.openphone.assistant.action.BACKGROUND_APPROVE";
    static final String ACTION_BACKGROUND_DENY =
            "org.openphone.assistant.action.BACKGROUND_DENY";
    static final String EXTRA_EXTERNAL_CONFIRMATION_ID =
            "org.openphone.assistant.extra.EXTERNAL_CONFIRMATION_ID";
    static final String EXTRA_BACKGROUND_CONFIRMATION_ID =
            "org.openphone.assistant.extra.BACKGROUND_CONFIRMATION_ID";
    static final int NOTIFICATION_ID = 1001;
    private static final int COMMITMENT_NOTIFICATION_BASE_ID = 5000;
    private static final int WATCHER_NOTIFICATION_BASE_ID = 6000;
    private static final int AGENT_JOB_NOTIFICATION_BASE_ID = 7000;
    private static final int RUNTIME_NOTIFICATION_BASE_ID = 8000;

    private OpenPhoneNotificationController() {}

    static void showReady(Context context) {
        show(context, false, context.getString(R.string.notification_agent_ready));
    }

    static void showActive(Context context, String taskId) {
        String detail = taskId == null ? context.getString(R.string.notification_agent_active)
                : context.getString(R.string.notification_agent_active) + " " + taskId;
        show(context, true, detail);
    }

    static void cancel(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager != null) {
            manager.cancel(NOTIFICATION_ID);
        }
    }

    public static void showCommitmentDue(Context context, CommitmentRecord commitment) {
        if (context == null || commitment == null) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureCommitmentChannel(context, manager);
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle("Open loop due")
                .setContentText(commitment.title)
                .setStyle(new Notification.BigTextStyle().bigText(commitment.title))
                .setShowWhen(true)
                .setWhen(commitment.dueAtMillis > 0
                        ? commitment.dueAtMillis : System.currentTimeMillis())
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN,
                        requestCode(commitment.id, 10)))
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Complete",
                        commitmentAction(context,
                                OpenPhoneWatcherScheduler.ACTION_COMPLETE_COMMITMENT,
                                commitment.id, 11)).build())
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Snooze",
                        commitmentAction(context,
                                OpenPhoneWatcherScheduler.ACTION_SNOOZE_COMMITMENT,
                                commitment.id, 12)).build())
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Dismiss",
                        commitmentAction(context,
                                OpenPhoneWatcherScheduler.ACTION_DISMISS_COMMITMENT,
                                commitment.id, 13)).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(COMMITMENT_CHANNEL_ID);
        }
        manager.notify(notificationId(commitment.id), builder.build());
    }

    public static void cancelCommitment(Context context, long commitmentId) {
        NotificationManager manager = context == null
                ? null : context.getSystemService(NotificationManager.class);
        if (manager != null) {
            manager.cancel(notificationId(commitmentId));
        }
    }

    public static void showWatcherFired(Context context, WatcherRecord watcher) {
        if (context == null || watcher == null) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureWatcherChannel(manager);
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle("Watcher fired")
                .setContentText(watcher.title)
                .setStyle(new Notification.BigTextStyle().bigText(watcher.title))
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis())
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN,
                        requestCode(watcher.id, 20)))
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Open",
                        pendingBroadcast(context, ACTION_OPEN,
                                requestCode(watcher.id, 21))).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(WATCHER_CHANNEL_ID);
        }
        manager.notify(watcherNotificationId(watcher.id), builder.build());
    }

    public static void showWatcherFailed(Context context, WatcherRecord watcher, String reason) {
        if (context == null || watcher == null) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureWatcherChannel(manager);
        String detail = reason == null || reason.trim().isEmpty()
                ? watcher.title : watcher.title + ": " + reason.trim();
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle("Watcher needs attention")
                .setContentText(detail)
                .setStyle(new Notification.BigTextStyle().bigText(detail))
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis())
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN,
                        requestCode(watcher.id, 30)))
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Open",
                        pendingBroadcast(context, ACTION_OPEN,
                                requestCode(watcher.id, 31))).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(WATCHER_CHANNEL_ID);
        }
        manager.notify(watcherNotificationId(watcher.id), builder.build());
    }

    public static void showAgentJobFinished(Context context, AgentJobRecord job, String result) {
        if (context == null || job == null) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureAgentJobChannel(manager);
        String detail = agentJobFinishedText(job, result);
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle(job.title)
                .setContentText(detail)
                .setStyle(new Notification.BigTextStyle().bigText(detail))
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis())
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN,
                        jobRequestCode(job.id, 10)))
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Open",
                        pendingBroadcast(context, ACTION_OPEN,
                                jobRequestCode(job.id, 11))).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(AGENT_JOB_CHANNEL_ID);
        }
        manager.notify(agentJobNotificationId(job.id), builder.build());
    }

    public static void showAgentJobFailed(Context context, AgentJobRecord job, String reason) {
        if (context == null || job == null) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureAgentJobChannel(manager);
        String detail = reason == null || reason.trim().isEmpty()
                ? job.title : job.title + ": " + reason.trim();
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle("Background job needs attention")
                .setContentText(detail)
                .setStyle(new Notification.BigTextStyle().bigText(detail))
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis())
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN,
                        jobRequestCode(job.id, 20)))
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Open",
                        pendingBroadcast(context, ACTION_OPEN,
                                jobRequestCode(job.id, 21))).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(AGENT_JOB_CHANNEL_ID);
        }
        manager.notify(agentJobNotificationId(job.id), builder.build());
    }

    public static void showAgentJobReview(Context context, AgentJobRecord job,
            JSONObject pendingRequest) {
        if (context == null || job == null || pendingRequest == null) {
            return;
        }
        String confirmationId = pendingRequest.optString("confirmation_id", "");
        if (confirmationId.trim().isEmpty()) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureAgentJobChannel(manager);
        String tool = pendingRequest.optString("tool", "OpenPhone action");
        JSONObject params = pendingRequest.optJSONObject("params");
        String exact = params == null ? "{}" : params.toString();
        String detail = pendingRequest.optString("summary", "").trim();
        if (detail.isEmpty()) {
            detail = tool + " with " + exact;
        }
        String expanded = "Job: " + job.title + "\nAction: " + tool
                + "\nExact arguments: " + exact;
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle("Review background action")
                .setContentText(summarize(detail))
                .setStyle(new Notification.BigTextStyle().bigText(expanded))
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis())
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(homePendingIntent(context,
                        jobRequestCode(job.id, 30)))
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Approve",
                        backgroundReviewAction(context, ACTION_BACKGROUND_APPROVE,
                                confirmationId, job.id, 31)).build())
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Deny",
                        backgroundReviewAction(context, ACTION_BACKGROUND_DENY,
                                confirmationId, job.id, 32)).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(AGENT_JOB_CHANNEL_ID);
        }
        manager.notify(agentJobNotificationId(job.id), builder.build());
    }

    public static void cancelAgentJobReview(Context context, long jobId) {
        NotificationManager manager = context == null
                ? null : context.getSystemService(NotificationManager.class);
        if (manager != null) {
            manager.cancel(agentJobNotificationId(jobId));
        }
    }

    public static void showRuntimeMessage(Context context, String runtime,
            String title, String text, String messageId) {
        if (context == null) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureRuntimeChannel(manager);
        String cleanRuntime = runtime == null || runtime.trim().isEmpty()
                ? "Runtime" : runtime.trim();
        String cleanTitle = title == null || title.trim().isEmpty()
                ? cleanRuntime : title.trim();
        String cleanText = text == null ? "" : text.trim();
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle(cleanTitle)
                .setContentText(cleanText)
                .setStyle(new Notification.BigTextStyle().bigText(cleanText))
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis())
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN,
                        runtimeRequestCode(messageId)));
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(RUNTIME_CHANNEL_ID);
        }
        manager.notify(runtimeNotificationId(messageId), builder.build());
    }

    public static void showRuntimeConfirmation(Context context, String confirmationId,
            String runtime, String tool, String summary) {
        if (context == null || confirmationId == null || confirmationId.trim().isEmpty()) {
            return;
        }
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        ensureRuntimeChannel(manager);
        String cleanRuntime = runtime == null || runtime.trim().isEmpty()
                ? "Runtime" : runtime.trim();
        String cleanTool = tool == null || tool.trim().isEmpty() ? "OpenPhone action" : tool.trim();
        String detail = summary == null || summary.trim().isEmpty()
                ? cleanTool : summary.trim();
        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle(cleanRuntime + " requests " + cleanTool)
                .setContentText(detail)
                .setStyle(new Notification.BigTextStyle().bigText(detail))
                .setShowWhen(true)
                .setWhen(System.currentTimeMillis())
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN,
                        runtimeRequestCode(confirmationId)))
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Approve",
                        runtimeAction(context, ACTION_EXTERNAL_APPROVE,
                                confirmationId, 1)).build())
                .addAction(new Notification.Action.Builder(
                        R.drawable.ic_openphone_tile,
                        "Deny",
                        runtimeAction(context, ACTION_EXTERNAL_DENY,
                                confirmationId, 2)).build());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(RUNTIME_CHANNEL_ID);
        }
        manager.notify(runtimeNotificationId(confirmationId), builder.build());
    }

    public static void cancelRuntimeConfirmation(Context context, String confirmationId) {
        NotificationManager manager = context == null
                ? null : context.getSystemService(NotificationManager.class);
        if (manager != null) {
            manager.cancel(runtimeNotificationId(confirmationId));
        }
    }

    private static void show(Context context, boolean active, String text) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) {
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notification_channel_agent),
                    NotificationManager.IMPORTANCE_LOW);
            manager.createNotificationChannel(channel);
        }

        Notification.Builder builder = new Notification.Builder(context)
                .setSmallIcon(R.drawable.ic_openphone_tile)
                .setContentTitle(context.getString(R.string.app_name))
                .setContentText(text)
                .setOngoing(active)
                .setShowWhen(false)
                .setContentIntent(pendingBroadcast(context, ACTION_OPEN, 1));
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(CHANNEL_ID);
        }

        if (active) {
            builder.addAction(new Notification.Action.Builder(
                    R.drawable.ic_openphone_tile,
                    context.getString(R.string.action_stop_task),
                    pendingBroadcast(context, ACTION_STOP, 2)).build());
        } else {
            builder.addAction(new Notification.Action.Builder(
                    R.drawable.ic_openphone_tile,
                    context.getString(R.string.action_start_task),
                    pendingBroadcast(context, ACTION_START, 3)).build());
        }
        builder.addAction(new Notification.Action.Builder(
                R.drawable.ic_openphone_tile,
                context.getString(R.string.action_open_assistant),
                pendingBroadcast(context, ACTION_OPEN, 4)).build());
        manager.notify(NOTIFICATION_ID, builder.build());
    }

    private static PendingIntent pendingBroadcast(Context context, String action, int requestCode) {
        Intent intent = new Intent(context, OpenPhoneTriggerReceiver.class);
        intent.setAction(action);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, flags);
    }

    private static PendingIntent commitmentAction(Context context, String action,
            long commitmentId, int actionCode) {
        Intent intent = new Intent(context, OpenPhoneWatcherReceiver.class);
        intent.setAction(action);
        intent.putExtra(OpenPhoneWatcherScheduler.EXTRA_COMMITMENT_ID, commitmentId);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(context, requestCode(commitmentId, actionCode),
                intent, flags);
    }

    private static PendingIntent runtimeAction(Context context, String action,
            String confirmationId, int actionCode) {
        Intent intent = new Intent(context, OpenPhoneTriggerReceiver.class);
        intent.setAction(action);
        intent.putExtra(EXTRA_EXTERNAL_CONFIRMATION_ID, confirmationId);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(context,
                runtimeRequestCode(confirmationId) + actionCode, intent, flags);
    }

    private static PendingIntent backgroundReviewAction(Context context, String action,
            String confirmationId, long jobId, int actionCode) {
        Intent intent = new Intent(context, OpenPhoneTriggerReceiver.class);
        intent.setAction(action);
        intent.putExtra(EXTRA_BACKGROUND_CONFIRMATION_ID, confirmationId);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(context,
                jobRequestCode(jobId, actionCode), intent, flags);
    }

    private static PendingIntent homePendingIntent(Context context, int requestCode) {
        Intent intent = new Intent(context, OpenPhoneHomeActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getActivity(context, requestCode, intent, flags);
    }

    private static void ensureCommitmentChannel(Context context, NotificationManager manager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    COMMITMENT_CHANNEL_ID,
                    "OpenPhone commitments",
                    NotificationManager.IMPORTANCE_DEFAULT);
            manager.createNotificationChannel(channel);
        }
    }

    private static void ensureWatcherChannel(NotificationManager manager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    WATCHER_CHANNEL_ID,
                    "OpenPhone watchers",
                    NotificationManager.IMPORTANCE_DEFAULT);
            manager.createNotificationChannel(channel);
        }
    }

    private static void ensureAgentJobChannel(NotificationManager manager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    AGENT_JOB_CHANNEL_ID,
                    "OpenPhone background jobs",
                    NotificationManager.IMPORTANCE_DEFAULT);
            manager.createNotificationChannel(channel);
        }
    }

    private static void ensureRuntimeChannel(NotificationManager manager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    RUNTIME_CHANNEL_ID,
                    "OpenPhone runtimes",
                    NotificationManager.IMPORTANCE_DEFAULT);
            manager.createNotificationChannel(channel);
        }
    }

    private static int notificationId(long commitmentId) {
        long bounded = Math.max(0L, Math.min(commitmentId, 999_999L));
        return COMMITMENT_NOTIFICATION_BASE_ID + (int) bounded;
    }

    private static int watcherNotificationId(long watcherId) {
        long bounded = Math.max(0L, Math.min(watcherId, 999_999L));
        return WATCHER_NOTIFICATION_BASE_ID + (int) bounded;
    }

    private static int agentJobNotificationId(long jobId) {
        long bounded = Math.max(0L, Math.min(jobId, 999_999L));
        return AGENT_JOB_NOTIFICATION_BASE_ID + (int) bounded;
    }

    private static int runtimeNotificationId(String messageId) {
        return RUNTIME_NOTIFICATION_BASE_ID
                + Math.abs((messageId == null ? "" : messageId).hashCode() % 1000);
    }

    private static int requestCode(long commitmentId, int actionCode) {
        long bounded = Math.max(0L, Math.min(commitmentId, 999_999L));
        return (int) (COMMITMENT_NOTIFICATION_BASE_ID + bounded * 10L + actionCode);
    }

    private static int jobRequestCode(long jobId, int actionCode) {
        long bounded = Math.max(0L, Math.min(jobId, 999_999L));
        return (int) (AGENT_JOB_NOTIFICATION_BASE_ID + bounded * 10L + actionCode);
    }

    private static int runtimeRequestCode(String messageId) {
        return RUNTIME_NOTIFICATION_BASE_ID + 1000
                + Math.abs((messageId == null ? "" : messageId).hashCode() % 1000);
    }

    private static String summarize(String text) {
        String clean = text.replace('\n', ' ').replace('\r', ' ').trim();
        return clean.length() <= 240 ? clean : clean.substring(0, 240);
    }

    private static String agentJobFinishedText(AgentJobRecord job, String result) {
        String deliveryText = firstNonEmpty(
                jsonString(job.deliveryJson, "notification_text"),
                jsonString(job.deliveryJson, "text"),
                jsonString(job.deliveryJson, "message"),
                jsonString(job.payloadJson, "notification_text"),
                jsonString(job.payloadJson, "text"),
                jsonString(job.payloadJson, "message"));
        if (!deliveryText.isEmpty()) {
            return summarize(deliveryText);
        }
        String exactPhrase = extractExactPhrase(job.prompt);
        if (!exactPhrase.isEmpty()) {
            return summarize(exactPhrase);
        }
        String resultSummary = resultSummary(result);
        if (!resultSummary.isEmpty()) {
            return summarize(resultSummary);
        }
        return job.title == null || job.title.trim().isEmpty()
                ? "Background job completed" : job.title.trim();
    }

    private static String resultSummary(String result) {
        String clean = result == null ? "" : result.trim();
        if (clean.isEmpty()) {
            return "";
        }
        if (!clean.startsWith("{")) {
            return clean;
        }
        try {
            JSONObject object = new JSONObject(clean);
            String rootSummary = firstNonEmpty(object.optString("summary", ""),
                    object.optString("message", ""),
                    object.optString("result", ""));
            if (!rootSummary.isEmpty()) {
                return rootSummary;
            }
            JSONArray steps = object.optJSONArray("steps");
            if (steps != null) {
                for (int i = steps.length() - 1; i >= 0; i--) {
                    JSONObject step = steps.optJSONObject(i);
                    if (step == null) {
                        continue;
                    }
                    JSONObject arguments = step.optJSONObject("arguments");
                    if (arguments == null) {
                        continue;
                    }
                    String summary = arguments.optString("summary", "");
                    if (!summary.trim().isEmpty()) {
                        return summary;
                    }
                }
            }
        } catch (JSONException ignored) {
        }
        return "Background job completed";
    }

    private static String jsonString(String json, String key) {
        if (json == null || json.trim().isEmpty()) {
            return "";
        }
        try {
            return new JSONObject(json).optString(key, "").trim();
        } catch (JSONException e) {
            return "";
        }
    }

    private static String extractExactPhrase(String text) {
        String clean = text == null ? "" : text.trim();
        if (clean.isEmpty()) {
            return "";
        }
        String marker = "exact phrase:";
        int index = clean.toLowerCase(java.util.Locale.US).indexOf(marker);
        if (index < 0) {
            return "";
        }
        String phrase = clean.substring(index + marker.length()).trim();
        if (phrase.startsWith("\"")) {
            int end = phrase.indexOf('"', 1);
            if (end > 1) {
                return phrase.substring(1, end).trim();
            }
        }
        int newline = phrase.indexOf('\n');
        if (newline >= 0) {
            phrase = phrase.substring(0, newline).trim();
        }
        if (phrase.endsWith(".") && phrase.indexOf('.') == phrase.length() - 1) {
            phrase = phrase.substring(0, phrase.length() - 1).trim();
        }
        return phrase;
    }

    private static String firstNonEmpty(String... values) {
        for (String value : values) {
            if (value != null && !value.trim().isEmpty()) {
                return value.trim();
            }
        }
        return "";
    }
}
