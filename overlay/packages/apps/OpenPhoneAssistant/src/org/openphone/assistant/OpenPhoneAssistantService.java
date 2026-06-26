package org.openphone.assistant;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.os.RemoteException;
import android.openphone.OpenPhoneAgentManager;
import android.provider.Settings;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.agent.ActionExecution;
import org.openphone.assistant.agent.AgentOrchestrator;
import org.openphone.assistant.agent.ScreenUnderstanding;
import org.openphone.assistant.agent.TaskRegistry;
import org.openphone.assistant.model.ModelEndpointConfig;
import org.openphone.assistant.model.OpenAiResponsesAgentAdapter;
import org.openphone.assistant.jobs.OpenPhoneAgentJobScheduler;
import org.openphone.assistant.policy.AuditLog;
import org.openphone.assistant.policy.PolicyDecision;
import org.openphone.assistant.policy.PolicyEngine;
import org.openphone.assistant.watchers.OpenPhoneWatcherScheduler;

import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;

public final class OpenPhoneAssistantService extends Service {
    private static final String TAG = "OpenPhoneAssistant";
    static final String ACTION_HIDE_ISLAND =
            "org.openphone.assistant.action.HIDE_ISLAND";
    static final String ACTION_SHOW_MIC_ISLAND =
            "org.openphone.assistant.action.SHOW_MIC_ISLAND";

    private OpenPhoneAgentManager mAgentManager;
    private PointerOverlayController mPointerOverlayController;
    private String mNotificationTaskId;
    private boolean mIslandHiddenByActivity;

    private final PolicyEngine mPolicyEngine = new PolicyEngine();
    private final AuditLog mAuditLog = new AuditLog(TAG);
    private final TaskRegistry mTaskRegistry = new TaskRegistry();
    private final ScreenUnderstanding mScreenUnderstanding = new ScreenUnderstanding(mAuditLog);
    private final ActionExecution mActionExecution = new ActionExecution(mPolicyEngine, mAuditLog);
    private final AgentOrchestrator mOrchestrator =
            new AgentOrchestrator(mTaskRegistry, mScreenUnderstanding, mActionExecution, mAuditLog);
    private final IOpenPhoneAssistant.Stub mBinder = new IOpenPhoneAssistant.Stub() {
        @Override
        public String getStatus() {
            if (mAgentManager == null) {
                return "assistant.ready framework.unavailable";
            }
            return "assistant.ready " + mAgentManager.getServiceStatus();
        }

        @Override
        public String startTask(String taskRequestJson) throws RemoteException {
            if (mAgentManager != null) {
                return mAgentManager.startTask(taskRequestJson);
            }
            return mOrchestrator.startTask(taskRequestJson);
        }

        @Override
        public String getScreenContext(String taskId) throws RemoteException {
            if (mAgentManager != null) {
                return mAgentManager.getScreenContext(taskId);
            }
            return mOrchestrator.getScreenContext(taskId);
        }

        @Override
        public String executeAction(String taskId, String actionRequestJson) throws RemoteException {
            if (mAgentManager != null) {
                return mAgentManager.executeAction(taskId, actionRequestJson);
            }
            return mOrchestrator.executeAction(taskId, actionRequestJson);
        }

        @Override
        public String confirmAction(String pendingActionId, boolean approved)
                throws RemoteException {
            if (mAgentManager != null) {
                return mAgentManager.confirmAction(pendingActionId, approved);
            }
            return "{\"status\":\"denied\",\"reason\":\"framework_unavailable\"}";
        }

        @Override
        public String evaluateCapability(String capabilityId) throws RemoteException {
            if (mAgentManager != null) {
                return mAgentManager.evaluateCapability(capabilityId);
            }
            PolicyDecision decision = mPolicyEngine.evaluate(capabilityId);
            mAuditLog.recordPolicyDecision(capabilityId, decision);
            return decision.toWireString();
        }

        @Override
        public String getAuditLog(int maxEvents) throws RemoteException {
            if (mAgentManager != null) {
                return mAgentManager.getAuditLog(maxEvents);
            }
            return "{\"events\":[],\"source\":\"assistant.framework_unavailable\"}";
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        mPointerOverlayController = new PointerOverlayController(this, this::answerScreenInOverlay);
        mPointerOverlayController.setConfirmationHandler(new PointerOverlayController.ConfirmationHandler() {
            @Override
            public void approve() {
                AssistantActivityBackend.confirmPendingFromOverlay(
                        OpenPhoneAssistantService.this, true);
            }

            @Override
            public void deny() {
                AssistantActivityBackend.confirmPendingFromOverlay(
                        OpenPhoneAssistantService.this, false);
            }
        });
        refreshIslandAutonomy();
        mAgentManager = getSystemService(OpenPhoneAgentManager.class);
        OpenPhoneNotificationListenerService.ensureEnabled(this);
        if (mAgentManager == null) {
            Log.w(TAG, "OpenPhone framework service is not available");
            OpenPhoneNotificationController.showReady(this);
            OpenPhoneWatcherScheduler.checkNow(this);
            OpenPhoneAgentJobScheduler.checkNow(this);
            return;
        }
        Log.i(TAG, "OpenPhone framework service status: " + mAgentManager.getServiceStatus());
        Log.i(TAG, "OpenPhone assistant service created");
        mPointerOverlayController.showMicButton();
        OpenPhoneNotificationController.showReady(this);
        OpenPhoneWatcherScheduler.checkNow(this);
        OpenPhoneAgentJobScheduler.checkNow(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        refreshIslandAutonomy();
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_HIDE_ISLAND.equals(action)) {
            mIslandHiddenByActivity = true;
            mPointerOverlayController.hide();
            return START_STICKY;
        }
        if (ACTION_SHOW_MIC_ISLAND.equals(action)) {
            mIslandHiddenByActivity = false;
            mPointerOverlayController.showMicButton();
            return START_STICKY;
        }
        if (OpenPhoneNotificationController.ACTION_START.equals(action)) {
            mIslandHiddenByActivity = false;
            mNotificationTaskId = startNotificationTask();
            mPointerOverlayController.show(mNotificationTaskId);
            OpenPhoneNotificationController.showActive(this, mNotificationTaskId);
            return START_STICKY;
        }
        if (OpenPhoneNotificationController.ACTION_STOP.equals(action)) {
            stopNotificationTask();
            return START_STICKY;
        }
        if (!mIslandHiddenByActivity) {
            mPointerOverlayController.showMicButton();
        }
        OpenPhoneNotificationController.showReady(this);
        OpenPhoneWatcherScheduler.checkNow(this);
        OpenPhoneAgentJobScheduler.checkNow(this);
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return mBinder;
    }

    @Override
    public void onDestroy() {
        if (mPointerOverlayController != null) {
            mPointerOverlayController.hide();
        }
        OpenPhoneNotificationController.cancel(this);
        super.onDestroy();
    }

    private String startNotificationTask() {
        if (mAgentManager == null) {
            return null;
        }
        String response = mAgentManager.startTask("{"
                + "\"goal\":\"Notification-triggered OpenPhone task\","
                + "\"user_visible\":true,"
                + "\"background_allowed\":false,"
                + "\"approved_capabilities\":[\"screen.read.visible\",\"tasks.observe\"]"
                + "}");
        int marker = response.indexOf("\"task_id\"");
        if (marker < 0) {
            return null;
        }
        int colon = response.indexOf(':', marker);
        int firstQuote = response.indexOf('"', colon + 1);
        int secondQuote = response.indexOf('"', firstQuote + 1);
        if (firstQuote < 0 || secondQuote < 0) {
            return null;
        }
        return response.substring(firstQuote + 1, secondQuote);
    }

    private void stopNotificationTask() {
        try {
            if (mAgentManager != null && mNotificationTaskId != null) {
                mAgentManager.stopTask(mNotificationTaskId,
                        "{\"reason\":\"user_stopped_from_notification\"}");
            }
        } catch (RuntimeException ignored) {
        } finally {
            mNotificationTaskId = null;
            if (mPointerOverlayController != null) {
                mPointerOverlayController.showMicButton();
            }
            OpenPhoneNotificationController.showReady(this);
        }
    }

    private void refreshIslandAutonomy() {
        String mode = Settings.Secure.getString(getContentResolver(),
                "openphone_autonomy_mode");
        mPointerOverlayController.setYoloActive(
                mode != null && "yolo".equals(mode.trim().toLowerCase(Locale.US)));
    }

    private void answerScreenInOverlay(String prompt,
            PointerOverlayController.ScreenAnswerCallback callback) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                callback.onAnswer(readScreenAnswer(prompt));
            }
        }, "OpenPhoneSheetScreenAnswer").start();
    }

    private String readScreenAnswer(String prompt) {
        if (mAgentManager == null) {
            return "Screen reading is unavailable because the OpenPhone framework service is not ready.";
        }
        ModelEndpointConfig endpointConfig = sheetModelEndpointConfig();
        String taskId = null;
        try {
            String response = mAgentManager.startTask("{"
                    + "\"goal\":\"" + jsonEscape(prompt) + "\","
                    + "\"user_visible\":true,"
                    + "\"background_allowed\":false,"
                    + "\"approved_capabilities\":[\"screen.read.visible\",\"tasks.observe\"]"
                    + "}");
            taskId = parseString(response, "task_id");
            if (taskId == null || taskId.isEmpty()) {
                return "I could not start a screen observation.";
            }
            if (endpointConfig.isConfigured()) {
                String screenJson = mAgentManager.getScreen(taskId,
                        "{\"include_screenshot\":true,\"include_activity\":true,"
                                + "\"include_ui_tree\":true,\"max_dimension\":512,"
                                + "\"quality\":65,"
                                + "\"reason\":\"answer from AI Sheet\"}");
                return new OpenAiResponsesAgentAdapter(endpointConfig)
                        .answerScreenQuestion(prompt
                                + " (Ignore the small OpenPhone assistant sheet overlay with"
                                + " its Reading screen card; answer about the app underneath.)",
                                screenJson);
            }
            String screenJson = mAgentManager.getScreen(taskId,
                    "{\"include_screenshot\":false,\"include_activity\":true,"
                            + "\"include_ui_tree\":false,"
                            + "\"reason\":\"answer from AI Sheet\"}");
            return summarizeScreen(prompt, screenJson, OpenPhoneAccessibilityService.snapshotJson());
        } catch (RuntimeException e) {
            return "I could not read the screen: " + e.getClass().getSimpleName();
        } finally {
            if (taskId != null && !taskId.isEmpty()) {
                try {
                    mAgentManager.stopTask(taskId, "{\"reason\":\"ai_sheet_screen_answer_complete\"}");
                } catch (RuntimeException ignored) {
                }
            }
        }
    }

    private ModelEndpointConfig sheetModelEndpointConfig() {
        return ModelEndpointConfig.fromStoredSettings(getApplicationContext());
    }

    private static String summarizeScreen(String prompt, String screenJson, String uiTreeJson) {
        try {
            JSONObject screen = new JSONObject(screenJson == null ? "{}" : screenJson);
            JSONObject uiTree = new JSONObject(uiTreeJson == null ? "{}" : uiTreeJson);
            JSONArray text = uiTree.optJSONArray("visible_text");
            if (text != null && text.length() > 0) {
                StringBuilder builder = new StringBuilder();
                builder.append(isSummaryPrompt(prompt)
                        ? "Visible screen summary: " : "On screen: ");
                Set<String> seen = new LinkedHashSet<>();
                int appended = 0;
                for (int i = 0; i < text.length() && appended < 6; i++) {
                    String[] parts = text.optString(i, "").split("[;|]");
                    for (String part : parts) {
                        String value = part.trim();
                        String normalized = normalizeVisibleText(value);
                        if (value.isEmpty() || value.length() > 80
                                || !hasLetterOrDigit(value)
                                || shouldSkipOverlayText(normalized)
                                || !seen.add(normalized)) {
                            continue;
                        }
                        if (appended > 0) {
                            builder.append("; ");
                        }
                        builder.append(value);
                        appended++;
                        if (appended >= 6) {
                            break;
                        }
                    }
                }
                if (appended > 0) {
                    return builder.toString();
                }
            }
            JSONObject context = screen.optJSONObject("context");
            if (context != null) {
                String pkg = context.optString("package",
                        context.optString("package_name", "")).trim();
                String activity = context.optString("activity", "").trim();
                if (!pkg.isEmpty() || !activity.isEmpty()) {
                    return "The current foreground surface appears to be "
                            + (pkg.isEmpty() ? "an app" : pkg)
                            + (activity.isEmpty() ? "." : " / " + activity + ".");
                }
            }
        } catch (JSONException ignored) {
        }
        return "I can see the current surface, but there is not enough readable text to summarize locally.";
    }

    private static boolean isSummaryPrompt(String prompt) {
        String text = prompt == null ? "" : prompt.toLowerCase(Locale.US);
        return text.contains("summarize") || text.contains("summarise");
    }

    private static String normalizeVisibleText(String value) {
        String text = value == null ? "" : value.trim().toLowerCase(Locale.US);
        while (text.contains("  ")) {
            text = text.replace("  ", " ");
        }
        return text;
    }

    private static boolean shouldSkipOverlayText(String value) {
        if (value.isEmpty()) {
            return true;
        }
        if (value.equals("ai")
                || value.equals("ask openphone")
                || value.equals("close")
                || value.equals("ready")
                || value.equals("screen answer")
                || value.equals("reading screen")
                || value.equals("talk")
                || value.equals("stop")
                || value.equals("chat")
                || value.equals("screen")
                || value.equals("summarize")
                || value.equals("summarise")
                || value.equals("search")
                || value.equals("notifications")
                || value.equals("settings")
                || value.equals("refresh")
                || value.equals("more")) {
            return true;
        }
        return value.contains("looking at the current screen")
                || value.startsWith("on screen:")
                || value.startsWith("visible screen summary:");
    }

    private static boolean hasLetterOrDigit(String value) {
        for (int i = 0; i < value.length(); i++) {
            if (Character.isLetterOrDigit(value.charAt(i))) {
                return true;
            }
        }
        return false;
    }

    private static String parseString(String json, String key) {
        try {
            return new JSONObject(json == null ? "{}" : json).optString(key, "");
        } catch (JSONException e) {
            return "";
        }
    }

    private static String jsonEscape(String text) {
        return JSONObject.quote(text == null ? "" : text).replaceAll("^\"|\"$", "");
    }
}
