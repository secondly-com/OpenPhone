package org.openphone.assistant;

import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.IBinder;
import android.os.RemoteException;
import android.os.UserManager;
import android.openphone.OpenPhoneAgentManager;
import android.provider.Settings;
import android.speech.tts.TextToSpeech;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.agent.ActionExecution;
import org.openphone.assistant.agent.AgentOrchestrator;
import org.openphone.assistant.agent.ScreenUnderstanding;
import org.openphone.assistant.agent.TaskRegistry;
import org.openphone.assistant.runtime.RuntimeCallback;
import org.openphone.assistant.runtime.RuntimeConfig;
import org.openphone.assistant.runtime.RuntimeManager;
import org.openphone.assistant.runtime.RuntimeRegistry;
import org.openphone.assistant.model.ModelEndpointConfig;
import org.openphone.assistant.model.OpenAiResponsesAgentAdapter;
import org.openphone.assistant.jobs.BackgroundJobReviewManager;
import org.openphone.assistant.jobs.OpenPhoneAgentJobScheduler;
import org.openphone.assistant.platform.OpenPhoneOsToolGateway;
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
    static final String ACTION_LOG_RUNTIME_STATUS =
            "org.openphone.assistant.action.LOG_RUNTIME_STATUS";
    static final String ACTION_RELOAD_RUNTIMES =
            "org.openphone.assistant.action.RELOAD_RUNTIMES";
    public static final String ACTION_REQUEST_RUNTIME_ATTENTION =
            "org.openphone.assistant.action.REQUEST_RUNTIME_ATTENTION";
    public static final String EXTRA_RUNTIME_ATTENTION_RUNTIME =
            "org.openphone.assistant.extra.RUNTIME_ATTENTION_RUNTIME";
    public static final String EXTRA_RUNTIME_ATTENTION_TEXT =
            "org.openphone.assistant.extra.RUNTIME_ATTENTION_TEXT";
    public static final String EXTRA_RUNTIME_ATTENTION_SOURCE =
            "org.openphone.assistant.extra.RUNTIME_ATTENTION_SOURCE";
    public static final String EXTRA_RUNTIME_ATTENTION_AUTONOMY =
            "org.openphone.assistant.extra.RUNTIME_ATTENTION_AUTONOMY";
    public static final String EXTRA_RUNTIME_ATTENTION_INCLUDE_SCREEN =
            "org.openphone.assistant.extra.RUNTIME_ATTENTION_INCLUDE_SCREEN";
    public static final String ACTION_RUNTIME_SURFACE_EVENT =
            "org.openphone.assistant.action.RUNTIME_SURFACE_EVENT";
    public static final String EXTRA_RUNTIME_SURFACE_RUNTIME =
            "org.openphone.assistant.extra.RUNTIME_SURFACE_RUNTIME";
    public static final String EXTRA_RUNTIME_SURFACE_EVENT =
            "org.openphone.assistant.extra.RUNTIME_SURFACE_EVENT";
    public static final String EXTRA_RUNTIME_SURFACE_PAYLOAD =
            "org.openphone.assistant.extra.RUNTIME_SURFACE_PAYLOAD";
    private static final int MAX_PENDING_RUNTIME_VOICE_REPLIES = 16;
    private static volatile String sLatestRuntimeStatusJson =
            "{\"status\":\"disabled\",\"manager_status\":\"not_created\"}";
    private static final String USER_LOCKED_RUNTIME_STATUS =
            "{\"status\":\"locked\",\"manager_status\":\"user_locked\"}";

    private OpenPhoneAgentManager mAgentManager;
    private PointerOverlayController mPointerOverlayController;
    private RuntimeManager mRuntimeManager;
    private String mNotificationTaskId;
    private boolean mIslandHiddenByActivity;
    private TextToSpeech mRuntimeReplyTts;
    private boolean mRuntimeReplyTtsReady;
    private final Set<String> mPendingRuntimeVoicePhoneSessions = new LinkedHashSet<>();
    private volatile boolean mUnlockedStateReady;
    private BroadcastReceiver mUserUnlockReceiver;

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
            String runtimeStatus = "runtime=" + runtimeStatusJson();
            if (!mUnlockedStateReady) {
                return "assistant.locked " + runtimeStatus;
            }
            if (mAgentManager == null) {
                return "assistant.ready framework.unavailable " + runtimeStatus;
            }
            return "assistant.ready " + mAgentManager.getServiceStatus() + " " + runtimeStatus;
        }

        @Override
        public String startTask(String taskRequestJson) throws RemoteException {
            if (!mUnlockedStateReady) {
                return userLockedResponse();
            }
            if (mAgentManager != null) {
                return mAgentManager.startTask(taskRequestJson);
            }
            return mOrchestrator.startTask(taskRequestJson);
        }

        @Override
        public String getScreenContext(String taskId) throws RemoteException {
            if (!mUnlockedStateReady) {
                return userLockedResponse();
            }
            if (mAgentManager != null) {
                return mAgentManager.getScreenContext(taskId);
            }
            return mOrchestrator.getScreenContext(taskId);
        }

        @Override
        public String executeAction(String taskId, String actionRequestJson) throws RemoteException {
            if (!mUnlockedStateReady) {
                return userLockedResponse();
            }
            if (mAgentManager != null) {
                return mAgentManager.executeAction(taskId, actionRequestJson);
            }
            return mOrchestrator.executeAction(taskId, actionRequestJson);
        }

        @Override
        public String confirmAction(String pendingActionId, boolean approved)
                throws RemoteException {
            if (!mUnlockedStateReady) {
                return userLockedResponse();
            }
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
            if (!mUnlockedStateReady) {
                return "{\"events\":[],\"source\":\"assistant.user_locked\"}";
            }
            if (mAgentManager != null) {
                return mAgentManager.getAuditLog(maxEvents);
            }
            return "{\"events\":[],\"source\":\"assistant.framework_unavailable\"}";
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        if (!isUserUnlocked()) {
            waitForUserUnlock();
            return;
        }
        initializeUnlockedState();
    }

    private void initializeUnlockedState() {
        if (mUnlockedStateReady || !isUserUnlocked()) {
            return;
        }
        unregisterUserUnlockReceiver();
        mUnlockedStateReady = true;
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
        ensureRuntimeManagerReady();
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
        if (!ensureUnlockedStateReady()) {
            Log.i(TAG, "Deferring assistant service command until user unlock");
            return START_STICKY;
        }
        refreshIslandAutonomy();
        ensureRuntimeManagerReady();
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
        if (ACTION_LOG_RUNTIME_STATUS.equals(action)) {
            Log.i(TAG, "runtime status " + runtimeStatusJson());
            return START_STICKY;
        }
        if (ACTION_RELOAD_RUNTIMES.equals(action)) {
            reloadRuntimeManager();
            Log.i(TAG, "runtime reloaded " + runtimeStatusJson());
            return START_STICKY;
        }
        if (ACTION_REQUEST_RUNTIME_ATTENTION.equals(action)) {
            requestRuntimeAttention(intent);
            return START_STICKY;
        }
        if (ACTION_RUNTIME_SURFACE_EVENT.equals(action)) {
            forwardRuntimeSurfaceEvent(intent);
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
        if (OpenPhoneNotificationController.ACTION_EXTERNAL_APPROVE.equals(action)
                || OpenPhoneNotificationController.ACTION_EXTERNAL_DENY.equals(action)) {
            resolveRuntimeConfirmation(intent,
                    OpenPhoneNotificationController.ACTION_EXTERNAL_APPROVE.equals(action));
            return START_STICKY;
        }
        if (OpenPhoneNotificationController.ACTION_BACKGROUND_APPROVE.equals(action)
                || OpenPhoneNotificationController.ACTION_BACKGROUND_DENY.equals(action)) {
            final String confirmationId = intent == null ? "" : intent.getStringExtra(
                    OpenPhoneNotificationController.EXTRA_BACKGROUND_CONFIRMATION_ID);
            final boolean approved =
                    OpenPhoneNotificationController.ACTION_BACKGROUND_APPROVE.equals(action);
            new Thread(() -> BackgroundJobReviewManager.resolve(
                    OpenPhoneAssistantService.this, confirmationId, approved),
                    "OpenPhoneBackgroundReview").start();
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
        unregisterUserUnlockReceiver();
        if (mPointerOverlayController != null) {
            mPointerOverlayController.hide();
        }
        if (mRuntimeManager != null) {
            mRuntimeManager.stop();
        }
        shutdownRuntimeReplyTts();
        OpenPhoneNotificationController.cancel(this);
        super.onDestroy();
    }

    private boolean ensureUnlockedStateReady() {
        if (mUnlockedStateReady) {
            return true;
        }
        if (!isUserUnlocked()) {
            waitForUserUnlock();
            return false;
        }
        initializeUnlockedState();
        return mUnlockedStateReady;
    }

    private void waitForUserUnlock() {
        sLatestRuntimeStatusJson = USER_LOCKED_RUNTIME_STATUS;
        if (mUserUnlockReceiver != null) {
            return;
        }
        mUserUnlockReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (!Intent.ACTION_USER_UNLOCKED.equals(intent.getAction())) {
                    return;
                }
                initializeUnlockedState();
            }
        };
        registerReceiver(mUserUnlockReceiver, new IntentFilter(Intent.ACTION_USER_UNLOCKED),
                Context.RECEIVER_NOT_EXPORTED);
        if (isUserUnlocked()) {
            initializeUnlockedState();
            return;
        }
        Log.i(TAG, "Assistant service is waiting for credential-encrypted storage to unlock");
    }

    private void unregisterUserUnlockReceiver() {
        if (mUserUnlockReceiver == null) {
            return;
        }
        try {
            unregisterReceiver(mUserUnlockReceiver);
        } catch (IllegalArgumentException ignored) {
        }
        mUserUnlockReceiver = null;
    }

    private static String userLockedResponse() {
        return "{\"status\":\"denied\",\"reason\":\"user_locked\"}";
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

    private String runtimeStatusJson() {
        String status = mRuntimeManager == null
                ? (isUserUnlocked() ? "{\"status\":\"disabled\",\"manager_status\":\"not_created\"}"
                        : USER_LOCKED_RUNTIME_STATUS)
                : mRuntimeManager.statusJson();
        sLatestRuntimeStatusJson = status;
        return status;
    }

    private void forwardRuntimeSurfaceEvent(Intent intent) {
        if (mRuntimeManager == null || intent == null) {
            return;
        }
        String runtime = cleanRuntime(intent.getStringExtra(EXTRA_RUNTIME_SURFACE_RUNTIME));
        String event = cleanExtra(intent.getStringExtra(EXTRA_RUNTIME_SURFACE_EVENT), "");
        JSONObject payload = parseObject(
                intent.getStringExtra(EXTRA_RUNTIME_SURFACE_PAYLOAD));
        if (runtime.isEmpty() || event.isEmpty()) {
            return;
        }
        mRuntimeManager.sendEventToRuntime(runtime, new org.openphone.assistant.runtime.RuntimeEvent(
                event, payload));
    }

    static String latestRuntimeStatusJson() {
        return sLatestRuntimeStatusJson;
    }

    private boolean ensureRuntimeManagerReady() {
        if (!isUserUnlocked()) {
            sLatestRuntimeStatusJson = USER_LOCKED_RUNTIME_STATUS;
            Log.i(TAG, "User locked; deferring runtime manager start");
            return false;
        }
        if (mRuntimeManager == null) {
            mRuntimeManager = new RuntimeManager(
                    this, new OpenPhoneOsToolGateway(this, mAgentManager));
            configureRuntimeCallback();
            mRuntimeManager.start();
        }
        return true;
    }

    private boolean isUserUnlocked() {
        UserManager userManager = getSystemService(UserManager.class);
        return userManager == null || userManager.isUserUnlocked();
    }

    private void reloadRuntimeManager() {
        if (!isUserUnlocked()) {
            sLatestRuntimeStatusJson = USER_LOCKED_RUNTIME_STATUS;
            Log.i(TAG, "User locked; skipping runtime reload");
            return;
        }
        if (mRuntimeManager == null) {
            mRuntimeManager = new RuntimeManager(
                    this, new OpenPhoneOsToolGateway(this, mAgentManager));
        }
        configureRuntimeCallback();
        mRuntimeManager.start();
    }

    private void configureRuntimeCallback() {
        if (mRuntimeManager == null) {
            return;
        }
        mRuntimeManager.setRuntimeCallback(new RuntimeCallback() {
            @Override
            public void onRuntimeMessage(String runtime, String sessionKey, String message,
                    boolean terminal) {
                handleRuntimeMessage(runtime, sessionKey, message, terminal);
            }
        });
    }

    private void requestRuntimeAttention(Intent intent) {
        if (!ensureRuntimeManagerReady()) {
            Log.w(TAG, "runtime attention ignored while user is locked");
            return;
        }
        if (shouldReloadRuntimeManagerForAttention(mRuntimeManager.statusJson())) {
            reloadRuntimeManager();
        }
        if (mRuntimeManager == null) {
            Log.w(TAG, "runtime attention ignored; runtime manager unavailable");
            return;
        }
        String text = cleanExtra(intent == null ? "" :
                intent.getStringExtra(EXTRA_RUNTIME_ATTENTION_TEXT), "");
        String source = cleanExtra(intent == null ? "" :
                intent.getStringExtra(EXTRA_RUNTIME_ATTENTION_SOURCE), "chat");
        String runtime = runtimeForAttention(intent, source);
        String autonomy = cleanExtra(intent == null ? "" :
                intent.getStringExtra(EXTRA_RUNTIME_ATTENTION_AUTONOMY), "ask_before_action");
        boolean includeScreen = intent != null
                && intent.getBooleanExtra(EXTRA_RUNTIME_ATTENTION_INCLUDE_SCREEN, true);
        JSONObject context = buildRuntimeAttentionContext(runtime, text, source, includeScreen);
        String result = mRuntimeManager.requestRuntimeAttention(runtime, text, source,
                autonomy, includeScreen, context);
        sLatestRuntimeStatusJson = mRuntimeManager.statusJson();
        JSONObject parsed = parseObject(result);
        if (parsed.optBoolean("ok", false)) {
            Log.i(TAG, "runtime attention sent runtime=" + runtime + " source=" + source);
            rememberRuntimeVoiceReply(parsed, source);
            if (mPointerOverlayController != null && !mIslandHiddenByActivity) {
                mPointerOverlayController.setIslandState("thinking",
                        runtimeLabel(runtime) + " is working on it.");
            }
            return;
        }
        String message = parsed.optString("message",
                runtimeLabel(runtime) + " runtime is not available.");
        Log.w(TAG, "runtime attention failed runtime=" + runtime + ": " + message);
        handleRuntimeMessage(runtime, "", message, true);
    }

    private boolean shouldReloadRuntimeManagerForAttention(String statusJson) {
        JSONObject status = parseObject(statusJson);
        String statusText = status.optString("status", "");
        String manager = status.optString("manager_status", "");
        return isReloadableRuntimeState(statusText) || isReloadableRuntimeState(manager);
    }

    private static boolean isReloadableRuntimeState(String status) {
        String clean = status == null ? "" : status.trim().toLowerCase(Locale.US);
        return clean.isEmpty()
                || "disabled".equals(clean)
                || "not_configured".equals(clean)
                || "stopped".equals(clean)
                || "offline".equals(clean)
                || "insecure_transport_denied".equals(clean)
                || clean.startsWith("auth_failed")
                || clean.startsWith("error");
    }

    private JSONObject buildRuntimeAttentionContext(String runtime, String text, String source,
            boolean includeScreen) {
        JSONObject context = new JSONObject();
        try {
            context.put("trigger", "openphone_assistant")
                    .put("runtime", runtime)
                    .put("source", source)
                    .put("sentAtMs", System.currentTimeMillis());
            if (includeScreen) {
                context.put("screen_preflight", captureRuntimeAttentionScreen(runtime, text));
            }
        } catch (JSONException ignored) {
        }
        return context;
    }

    private JSONObject captureRuntimeAttentionScreen(String runtime, String prompt) {
        JSONObject compact = new JSONObject();
        if (mAgentManager == null) {
            try {
                compact.put("available", false).put("reason", "framework_unavailable");
            } catch (JSONException ignored) {
            }
            return compact;
        }
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
                return compact.put("available", false).put("reason", "missing_task_id");
            }
            String screenJson = mAgentManager.getScreen(taskId,
                    "{\"include_screenshot\":true,\"include_activity\":true,"
                            + "\"include_ui_tree\":true,"
                            + "\"max_dimension\":768,"
                            + "\"quality\":70,"
                            + "\"reason\":\"preflight context for runtime attention\"}");
            JSONObject screen = parseObject(screenJson);
            JSONObject context = screen.optJSONObject("context");
            JSONObject screenshot = compactScreenshot(screen.optJSONObject("screenshot"));
            compact.put("available", true)
                    .put("state", screen.optString("state"))
                    .put("capture_mode", screen.optString("capture_mode"))
                    .put("source", screen.optString("source"))
                    .put("visible_text", compactStringArray(
                            firstArray(screen.optJSONArray("visible_text"),
                                    context == null ? null : context.optJSONArray("visible_text")),
                            30))
                    .put("interactive_elements", compactElements(
                            firstArray(screen.optJSONArray("interactive_elements"),
                                    context == null ? null
                                            : context.optJSONArray("interactive_elements")),
                            10));
            if (context != null) {
                compact.put("foreground_app", context.optString("foreground_app"))
                        .put("activity", context.optString("activity"))
                        .put("screen_width", context.optInt("screen_width", 0))
                        .put("screen_height", context.optInt("screen_height", 0))
                        .put("risk_flags", compactStringArray(
                                context.optJSONArray("risk_flags"), 12));
            }
            if (screenshot.length() > 0) {
                compact.put("screenshot", screenshot);
            }
            Log.i(TAG, "runtime attention screen preflight runtime=" + runtime
                    + " fields=" + compact.length());
            return compact;
        } catch (RuntimeException | JSONException e) {
            Log.w(TAG, "runtime attention screen preflight failed", e);
            try {
                compact.put("available", false).put("reason", e.getClass().getSimpleName());
            } catch (JSONException ignored) {
            }
            return compact;
        } finally {
            if (taskId != null && !taskId.isEmpty()) {
                try {
                    mAgentManager.stopTask(taskId,
                            "{\"reason\":\"runtime_attention_preflight_complete\"}");
                } catch (RuntimeException ignored) {
                }
            }
        }
    }

    private static JSONObject compactScreenshot(JSONObject screenshot) throws JSONException {
        JSONObject compact = new JSONObject();
        if (screenshot == null) {
            return compact;
        }
        String data = screenshot.optString("data", "");
        String encoding = screenshot.optString("encoding", "base64");
        if (data.isEmpty() || !"base64".equalsIgnoreCase(encoding)) {
            compact.put("included", false);
            return compact;
        }
        compact.put("included", true)
                .put("encoding", "base64")
                .put("mime_type", screenshot.optString("mime_type", "image/jpeg"))
                .put("width", screenshot.optInt("width", 0))
                .put("height", screenshot.optInt("height", 0))
                .put("data", data);
        return compact;
    }

    private static JSONArray firstArray(JSONArray primary, JSONArray fallback) {
        return primary != null && primary.length() > 0 ? primary : fallback;
    }

    private static JSONArray compactStringArray(JSONArray values, int limit) throws JSONException {
        JSONArray compact = new JSONArray();
        if (values == null) {
            return compact;
        }
        int count = Math.min(values.length(), limit);
        for (int index = 0; index < count; index++) {
            String value = values.optString(index);
            if (value != null && !value.trim().isEmpty()) {
                compact.put(value.trim());
            }
        }
        return compact;
    }

    private static JSONArray compactElements(JSONArray elements, int limit) throws JSONException {
        JSONArray compact = new JSONArray();
        if (elements == null) {
            return compact;
        }
        int count = Math.min(elements.length(), limit);
        for (int index = 0; index < count; index++) {
            JSONObject element = elements.optJSONObject(index);
            if (element == null) {
                continue;
            }
            JSONObject item = new JSONObject()
                    .put("id", element.optString("id"))
                    .put("kind", element.optString("kind"))
                    .put("label", element.optString("label"))
                    .put("bounds", element.optJSONArray("bounds"));
            compact.put(item);
        }
        return compact;
    }

    private static String cleanExtra(String value, String fallback) {
        String clean = value == null ? "" : value.trim();
        return clean.isEmpty() ? fallback : clean;
    }

    private String runtimeForAttention(Intent intent, String source) {
        String requested = cleanRuntime(intent == null ? "" :
                intent.getStringExtra(EXTRA_RUNTIME_ATTENTION_RUNTIME));
        if (!requested.isEmpty()) {
            return requested;
        }
        return AssistantBrainConfig.routeRuntimeForSource(this, source, RuntimeConfig.load(this));
    }

    private static String cleanRuntime(String runtime) {
        return RuntimeRegistry.normalize(runtime);
    }

    private static String runtimeLabel(String runtime) {
        return RuntimeRegistry.label(runtime);
    }

    private void handleRuntimeMessage(String runtime, String sessionKey, String message,
            boolean terminal) {
        String clean = message == null ? "" : message.trim();
        if (clean.isEmpty()) {
            return;
        }
        Log.i(TAG, "runtime message runtime=" + runtime
                + " terminal=" + terminal + " session=" + sessionKey);
        if (mPointerOverlayController != null && terminal) {
            mPointerOverlayController.showReply(clean);
        } else if (mPointerOverlayController != null && !mIslandHiddenByActivity) {
            mPointerOverlayController.setIslandState("thinking", clean);
        }
        boolean delivered = AssistantActivityBackend.deliverRuntimeMessage(runtime, sessionKey, clean,
                terminal);
        if (terminal && !delivered && consumeRuntimeVoiceReply(sessionKey)
                && !isSystemFailureReply(clean)) {
            Log.i(TAG, "runtime service TTS speaking session=" + sessionKey
                    + " chars=" + clean.length());
            speakRuntimeReply(clean);
        }
    }

    private void rememberRuntimeVoiceReply(JSONObject result, String source) {
        if (!isVoiceSource(source)) {
            return;
        }
        String phoneSessionId = result == null ? "" : result.optString("phone_session_id", "");
        String clean = phoneSessionId == null ? "" : phoneSessionId.trim();
        if (clean.isEmpty()) {
            return;
        }
        synchronized (mPendingRuntimeVoicePhoneSessions) {
            mPendingRuntimeVoicePhoneSessions.add(clean);
            while (mPendingRuntimeVoicePhoneSessions.size() > MAX_PENDING_RUNTIME_VOICE_REPLIES) {
                java.util.Iterator<String> iterator = mPendingRuntimeVoicePhoneSessions.iterator();
                if (!iterator.hasNext()) {
                    break;
                }
                iterator.next();
                iterator.remove();
            }
        }
    }

    private boolean consumeRuntimeVoiceReply(String sessionKey) {
        String cleanSessionKey = sessionKey == null ? "" : sessionKey.trim();
        if (cleanSessionKey.isEmpty()) {
            return false;
        }
        synchronized (mPendingRuntimeVoicePhoneSessions) {
            java.util.Iterator<String> iterator = mPendingRuntimeVoicePhoneSessions.iterator();
            while (iterator.hasNext()) {
                String phoneSessionId = iterator.next();
                if (cleanSessionKey.contains(phoneSessionId)) {
                    iterator.remove();
                    return true;
                }
            }
        }
        return false;
    }

    private void speakRuntimeReply(String reply) {
        final String utterance = speechText(reply);
        if (utterance.isEmpty()) {
            return;
        }
        if (mRuntimeReplyTts == null) {
            mRuntimeReplyTtsReady = false;
            mRuntimeReplyTts = new TextToSpeech(this, status -> {
                mRuntimeReplyTtsReady = status == TextToSpeech.SUCCESS;
                if (mRuntimeReplyTtsReady && mRuntimeReplyTts != null) {
                    mRuntimeReplyTts.speak(utterance, TextToSpeech.QUEUE_FLUSH,
                            null, "openphone-runtime-service-reply");
                } else {
                    Log.w(TAG, "runtime service TTS unavailable status=" + status);
                }
            });
            return;
        }
        if (!mRuntimeReplyTtsReady) {
            Log.w(TAG, "runtime service TTS not ready");
            return;
        }
        mRuntimeReplyTts.speak(utterance, TextToSpeech.QUEUE_FLUSH,
                null, "openphone-runtime-service-reply");
    }

    private static String speechText(String reply) {
        String clean = reply == null ? "" : reply.replace('\n', ' ').replace('\r', ' ').trim();
        if (clean.length() <= 700) {
            return clean;
        }
        return clean.substring(0, 697).trim() + "...";
    }

    private void shutdownRuntimeReplyTts() {
        TextToSpeech tts = mRuntimeReplyTts;
        mRuntimeReplyTts = null;
        mRuntimeReplyTtsReady = false;
        if (tts != null) {
            try {
                tts.stop();
                tts.shutdown();
            } catch (RuntimeException e) {
                Log.w(TAG, "runtime service TTS shutdown failed", e);
            }
        }
    }

    private static boolean isVoiceSource(String source) {
        String clean = source == null ? "" : source.trim().toLowerCase(Locale.US);
        return clean.contains("voice");
    }

    private static boolean isSystemFailureReply(String reply) {
        if (reply == null) {
            return false;
        }
        return reply.startsWith("Message routing failed:")
                || reply.startsWith("Message routing timed out.")
                || reply.startsWith("I couldn't hear the task.")
                || reply.startsWith("I didn't catch that.");
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

    private void resolveRuntimeConfirmation(Intent intent, boolean approved) {
        String confirmationId = intent == null ? "" : intent.getStringExtra(
                OpenPhoneNotificationController.EXTRA_EXTERNAL_CONFIRMATION_ID);
        if (mRuntimeManager == null || confirmationId == null
                || confirmationId.trim().isEmpty()) {
            Log.w(TAG, "runtime confirmation action missing manager or id");
            return;
        }
        RuntimeManager manager = mRuntimeManager;
        String trimmedId = confirmationId.trim();
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    String result = manager.resolveRuntimeConfirmation(trimmedId, approved);
                    Log.i(TAG, "runtime confirmation resolved approved=" + approved
                            + " id=" + trimmedId + " result=" + result);
                } catch (RuntimeException e) {
                    Log.w(TAG, "runtime confirmation resolution failed id=" + trimmedId, e);
                }
            }
        }, "OpenPhoneRuntimeConfirm").start();
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
        // Sheet answers run in the assistant service with no activity-held dev key,
        // so the Secure setting is the only credential source (dev builds only) —
        // same pattern as background watcher evaluation.
        if (!"userdebug".equals(Build.TYPE) && !"eng".equals(Build.TYPE)) {
            return ModelEndpointConfig.directOpenAi("");
        }
        String apiKey = Settings.Secure.getString(getContentResolver(),
                "openphone_dev_openai_api_key");
        return ModelEndpointConfig.directOpenAi(apiKey == null ? "" : apiKey);
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

    private static JSONObject parseObject(String json) {
        try {
            return new JSONObject(json == null ? "{}" : json);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static String jsonEscape(String text) {
        return JSONObject.quote(text == null ? "" : text).replaceAll("^\"|\"$", "");
    }
}
