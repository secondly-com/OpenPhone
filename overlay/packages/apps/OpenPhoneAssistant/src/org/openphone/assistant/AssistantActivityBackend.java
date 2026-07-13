package org.openphone.assistant;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.openphone.OpenPhoneAgentManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.speech.tts.TextToSpeech;
import android.util.Base64;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;

import androidx.activity.OnBackPressedCallback;
import androidx.activity.ComponentActivity;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.agent.FrameworkToolExecutor;
import org.openphone.assistant.agent.AuditEvidenceExporter;
import org.openphone.assistant.agent.TrajectoryRecorder;
import org.openphone.assistant.actions.ActionRegistry;
import org.openphone.assistant.context.ContextIndexStore;
import org.openphone.assistant.runtime.RuntimeConfig;
import org.openphone.assistant.runtime.RuntimeRegistry;
import org.openphone.assistant.model.LocalHeuristicModelAdapter;
import org.openphone.assistant.model.GeminiLiveVoiceSession;
import org.openphone.assistant.model.ModelEndpointConfig;
import org.openphone.assistant.model.ModelAdapter;
import org.openphone.assistant.model.OpenAiRealtimeAdapter;
import org.openphone.assistant.model.OpenAiRealtimeVoiceSession;
import org.openphone.assistant.model.OpenAiSpeechTranscriber;
import org.openphone.assistant.orchestrator.OpenPhoneOrchestrator;
import org.openphone.assistant.orchestrator.OperatingMode;
import org.openphone.assistant.orchestrator.OrchestratorDecision;
import org.openphone.assistant.ota.OtaUpdateClient;
import org.openphone.assistant.policy.AppCapabilityPolicy;
import org.openphone.assistant.watchers.OpenPhoneWatcherScheduler;

import java.io.IOException;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicInteger;

public class AssistantActivityBackend extends ComponentActivity {
    public interface ComposeStateCallbacks {
        void setTaskStatus(String text);
        void setContextText(String text);
        void setAuditText(String text);
        void setModelDisclosure(String text);
        void setModelConfig(boolean useRealtime, boolean useRealtime2,
                boolean useLiveRealtimeVoice, boolean useGeminiLiveVoice,
                boolean useBroker, String apiKey, String geminiApiKey,
                String brokerUrl, String brokerToken);
        void setOtaStatus(String text, boolean canDownload);
        void setRuntimeStatus(String text, String activeTaskId, boolean running,
                boolean listening);
        void setAutonomyMode(String mode);
        void setComposerText(String text);
        void addConversationMessage(String speaker, String message);
        void setPendingConfirmation(String actionId, String toolName, String summary);
        void clearPendingConfirmation();
        void showChat();
    }

    private static final String EXTRA_DEV_OPENAI_API_KEY =
            "org.openphone.assistant.extra.DEV_OPENAI_API_KEY";
    private static final String EXTRA_DEV_GEMINI_API_KEY =
            "org.openphone.assistant.extra.DEV_GEMINI_API_KEY";
    private static final String EXTRA_GOAL = "org.openphone.assistant.extra.GOAL";
    private static final String EXTRA_GOAL_BASE64 =
            "org.openphone.assistant.extra.GOAL_BASE64";
    private static final String EXTRA_RUN = "org.openphone.assistant.extra.RUN";
    static final String EXTRA_START_VOICE =
            "org.openphone.assistant.extra.START_VOICE";
    static final String EXTRA_STOP_AGENT =
            "org.openphone.assistant.extra.STOP_AGENT";
    static final String EXTRA_TOGGLE_AGENT =
            "org.openphone.assistant.extra.TOGGLE_AGENT";
    static final String EXTRA_HOLD_TO_RECORD =
            "org.openphone.assistant.extra.HOLD_TO_RECORD";
    static final String EXTRA_FINISH_VOICE_CAPTURE =
            "org.openphone.assistant.extra.FINISH_VOICE_CAPTURE";
    static final String EXTRA_CONFIRM_APPROVE =
            "org.openphone.assistant.extra.CONFIRM_APPROVE";
    static final String EXTRA_CONFIRM_DENY =
            "org.openphone.assistant.extra.CONFIRM_DENY";

    /**
     * Called from the system overlay (PointerOverlayController inline
     * Approve/Deny). Routes through AgentControlActivity so the live activity
     * state with mPendingActionId can fulfil the confirmation.
     */
    public static void confirmPendingFromOverlay(Context context, boolean approved) {
        Intent intent = new Intent(context, AgentControlActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        intent.putExtra(approved ? EXTRA_CONFIRM_APPROVE : EXTRA_CONFIRM_DENY, true);
        try {
            context.startActivity(intent);
        } catch (RuntimeException ignored) {
        }
    }

    static boolean deliverRuntimeMessage(final String runtime, final String sessionKey,
            final String message, final boolean terminal) {
        AssistantActivityBackend target = sActiveControlRunner != null
                ? sActiveControlRunner : sForegroundActivity;
        if (target == null) {
            return false;
        }
        target.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                target.handleRuntimeMessage(runtime, sessionKey, message, terminal);
            }
        });
        return true;
    }

    private static final String TAG = "OpenPhoneAssistant";
    private static final int REQUEST_RECORD_AUDIO = 1001;
    private static final long VOICE_TOGGLE_DUPLICATE_GRACE_MILLIS = 2500L;
    private static final long VOICE_PIPELINE_TOGGLE_PROTECTION_MILLIS = 60000L;
    private static final long VOLUME_CHORD_CLASSIC_HOLD_MILLIS = 520L;
    private static final long VOLUME_CHORD_DOUBLE_TAP_MILLIS = 700L;
    // Cap is a safety net; the transcriber stops earlier on speech-end silence
    // (END_SILENCE_MILLIS in OpenAiSpeechTranscriber). Bumped from 12s — long
    // questions about a screen ("Can you see what I'm looking at and tell me…")
    // were hitting the cap mid-sentence.
    private static final int VOICE_CAPTURE_MILLIS = 30000;
    // Safety cap for volume-button hold-to-record. Normal completion comes
    // from the framework key-up signal, not this timer.
    private static final int VOICE_HOLD_CAPTURE_MAX_MILLIS = 120000;
    private static final int ROUTING_TIMEOUT_MILLIS = 65000;
    private static final int SCREEN_QUESTION_TIMEOUT_MILLIS = 30000;
    private static final String PREFS = "openphone_assistant";
    private static final String PREF_GRANT_INPUT = "grant_input";
    private static final String PREF_GRANT_SCREEN_CAPTURE = "grant_screen_capture";
    private static final String PREF_GRANT_CLIPBOARD = "grant_clipboard";
    private static final String PREF_GRANT_SHARE = "grant_share";
    private static final String PREF_GRANT_NETWORK = "grant_network";
    private static final String PREF_AUTONOMY_MODE = "autonomy_mode";
    private static final String PREF_VOICE_MODE = "voice_mode";
    private static final String VOICE_MODE_CLASSIC = "classic";
    private static final String VOICE_MODE_LIVE_REALTIME_2 = "live_realtime_2";
    private static final String VOICE_MODE_GEMINI_LIVE = "gemini_live";
    private static final String[] FULL_YOLO_APPROVED_CAPABILITIES = {
            "screen.read.visible",
            "screen.capture",
            "input.perform",
            "apps.read",
            "apps.launch",
            "tasks.observe",
            "memory.read",
            "memory.write",
            "commitments.read",
            "commitments.write",
            "watchers.read",
            "watchers.write",
            "notifications.read",
            "notifications.act",
            "clipboard.read",
            "clipboard.write",
            "share.content",
            "files.read.scoped",
            "contacts.read",
            "calendar.read",
            "calendar.write",
            "calendar.delete",
            "messages.read",
            "messages.draft",
            "messages.send",
            "calls.read",
            "calls.place",
            "settings.read",
            "settings.write",
            "background.run",
            "network.use",
            "account.access"
    };
    private static final String SECURE_GRANT_INPUT = "openphone_task_grant_input";
    private static final String SECURE_GRANT_SCREEN_CAPTURE = "openphone_task_grant_screenshot";
    private static final String SECURE_GRANT_CLIPBOARD = "openphone_task_grant_clipboard";
    private static final String SECURE_GRANT_SHARE = "openphone_task_grant_share";
    private static final String SECURE_GRANT_NETWORK = "openphone_task_grant_network";
    private static final String SECURE_AUTONOMY_MODE = "openphone_autonomy_mode";
    private static final String SECURE_VOICE_MODE = "openphone_voice_mode";
    private static final String SECURE_DEV_OPENAI_API_KEY = "openphone_dev_openai_api_key";
    private static final String SECURE_DEV_GEMINI_API_KEY = "openphone_dev_gemini_api_key";
    private static AssistantActivityBackend sActiveControlRunner;
    private static AssistantActivityBackend sForegroundActivity;
    private static long sLastQuickVolumeChordUptimeMillis;
    private final Handler mMainHandler = new Handler(Looper.getMainLooper());
    private final OpenPhoneOrchestrator mOrchestrator = new OpenPhoneOrchestrator();
    private OpenPhoneAgentManager mAgentManager;
    private PointerOverlayController mPointerOverlayController;
    private ContextIndexStore mContextIndexStore;
    private ActionRegistry mActionRegistry;
    private String mActiveTaskId;
    private String mActiveTaskGoal;
    private String mPendingActionId;
    private String mPendingToolName;
    private JSONObject mPendingToolArguments;
    private String mPendingOneShotMessage;
    private volatile boolean mAgentRunCancelled;
    private boolean mIslandVoiceLaunch;
    private boolean mSuppressNextUserAppend;
    private final AtomicInteger mAgentRunGeneration = new AtomicInteger();
    private int mAuditRefreshGeneration;
    private int mVoiceRunGeneration;
    private int mChatRunGeneration;
    private Thread mAgentThread;
    private Thread mChatThread;
    private ModelAdapter mRunningModelAdapter;
    private ModelAdapter mRunningChatAdapter;
    private volatile OpenAiSpeechTranscriber mRunningSpeechTranscriber;
    private volatile OpenAiRealtimeVoiceSession mRunningRealtimeVoiceSession;
    private volatile GeminiLiveVoiceSession mRunningGeminiLiveVoiceSession;
    private volatile String mRealtimeVoiceTaskId;
    private OtaUpdateClient.Update mLatestOtaUpdate;
    private boolean mListening;
    private boolean mVoiceHoldToRecord;
    private String mVoiceRouteSource = "chat_voice";
    private TextToSpeech mRuntimeReplyTts;
    private boolean mRuntimeReplyTtsReady;
    private boolean mPendingRuntimeVoiceReply;
    private boolean mVoiceCaptureFinishRequested;
    private boolean mRealtimeVoiceErrorShown;
    private boolean mPendingVoiceForceClassic;
    private boolean mVolumeChordPendingClassic;
    private boolean mVolumeChordClassicStarted;
    private int mVolumeChordGeneration;
    private long mLastVoiceStartUptimeMillis;
    private boolean mVoicePipelineToggleProtected;
    private long mVoicePipelineStartedUptimeMillis;
    private String mComposeGoalText = "";
    private String mComposeActionJson = "";
    private String mComposeApiKey = "";
    private String mComposeGeminiApiKey = "";
    private String mComposeBrokerUrl = "";
    private String mComposeBrokerToken = "";
    private String mComposeOtaFeedUrl = "";
    private String mComposeTaskText = "";
    private String mComposeContextText = "";
    private String mComposeAuditText = "";
    private String mComposeModelDisclosureText = "";
    private String mComposeOtaStatusText = "";
    private String mLastRuntimeMessageKey = "";
    private boolean mComposeUseBroker;
    private boolean mComposeUseRealtime;
    private boolean mComposeUseRealtime2;
    private boolean mComposeUseLiveRealtimeVoice;
    private boolean mComposeUseGeminiLiveVoice;
    private boolean mComposeInputGrant = true;
    private boolean mComposeScreenCaptureGrant = true;
    private boolean mComposeClipboardGrant;
    private boolean mComposeShareGrant;
    private boolean mComposeNetworkGrant;
    private String mAutonomyMode = "reviewed";
    private boolean mComposeAdvancedVisible;
    private ComposeStateCallbacks mComposeStateCallbacks;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        mAgentManager = getSystemService(OpenPhoneAgentManager.class);
        mPointerOverlayController = new PointerOverlayController(this);
        // Wire inline Approve / Deny on the island to this activity's
        // pending-confirmation state. The service's controller has its own
        // handler, but the live controller during a task is the activity's,
        // and without this hook the buttons fire onClick but find a null
        // handler ("Approve clicked, handler=false" in logcat).
        mPointerOverlayController.setConfirmationHandler(
                new PointerOverlayController.ConfirmationHandler() {
                    @Override
                    public void approve() {
                        runOnUiThread(() -> confirmPending(true));
                    }

                    @Override
                    public void deny() {
                        runOnUiThread(() -> confirmPending(false));
                    }
                });
        mContextIndexStore = new ContextIndexStore(this);
        mContextIndexStore.backfillChatHistoryIfNeeded();
        mActionRegistry = ActionRegistry.load();
        OpenPhoneWatcherScheduler.checkNow(this);
        OpenPhoneAccessibilityService.ensureEnabled(this);
        OpenPhoneNotificationListenerService.ensureEnabled(this);
        loadComposeDefaults();
        if (isControlSurface()) {
            applyDebugIntentExtras(getIntent());
            return;
        }
        OpenPhoneBootReceiver.applyOpenPhoneWallpaperIfNeeded(this);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                if (isAdvancedVisible()) {
                    showChatSurface();
                    if (mComposeStateCallbacks != null) {
                        mComposeStateCallbacks.showChat();
                    }
                    return;
                }
                setEnabled(false);
                getOnBackPressedDispatcher().onBackPressed();
            }
        });
        setContentView(AssistantComposeHost.createView(this));
        setServiceIslandVisible(false);
        mPointerOverlayController.hide();
        refreshAll();
        applyDebugIntentExtras(getIntent());
    }

    @Override
    protected void onResume() {
        super.onResume();
        sForegroundActivity = this;
        if (isControlSurface()) {
            return;
        }
        setServiceIslandVisible(false);
        if (!mIslandVoiceLaunch) {
            mPointerOverlayController.hide();
        }
        OpenPhoneAccessibilityService.ensureEnabled(this);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        applyDebugIntentExtras(intent);
    }

    @Override
    protected void onDestroy() {
        shutdownRuntimeReplyTts();
        if (isControlSurface()) {
            super.onDestroy();
            return;
        }
        cancelAgentRun();
        if (mPointerOverlayController != null) {
            mPointerOverlayController.hide();
        }
        if (sForegroundActivity == this) {
            sForegroundActivity = null;
        }
        setServiceIslandVisible(true);
        super.onDestroy();
    }

    private void setServiceIslandVisible(boolean visible) {
        Intent intent = new Intent(this, OpenPhoneAssistantService.class);
        intent.setAction(visible
                ? OpenPhoneAssistantService.ACTION_SHOW_MIC_ISLAND
                : OpenPhoneAssistantService.ACTION_HIDE_ISLAND);
        try {
            startService(intent);
        } catch (RuntimeException ignored) {
        }
    }

    private void applyDebugIntentExtras(Intent intent) {
        if (intent == null) {
            return;
        }
        final boolean holdToRecord = intent.getBooleanExtra(EXTRA_HOLD_TO_RECORD, false);
        Log.i(TAG, "control intent startVoice="
                + intent.getBooleanExtra(EXTRA_START_VOICE, false)
                + " finishVoice=" + intent.getBooleanExtra(EXTRA_FINISH_VOICE_CAPTURE, false)
                + " stop=" + intent.getBooleanExtra(EXTRA_STOP_AGENT, false)
                + " toggle=" + intent.getBooleanExtra(EXTRA_TOGGLE_AGENT, false)
                + " hold=" + holdToRecord
                + " control=" + isControlSurface());
        if (intent.getBooleanExtra(EXTRA_START_VOICE, false)) {
            postToUi(new Runnable() {
                @Override
                public void run() {
                    startIslandVoiceAgent(holdToRecord);
                }
            });
        }
        if (intent.getBooleanExtra(EXTRA_FINISH_VOICE_CAPTURE, false)) {
            postToUi(new Runnable() {
                @Override
                public void run() {
                    finishVoiceCaptureFromHold();
                }
            });
        }
        if (intent.getBooleanExtra(EXTRA_STOP_AGENT, false)) {
            postToUi(new Runnable() {
                @Override
                public void run() {
                    AssistantActivityBackend runner = sActiveControlRunner;
                    if (runner != null && runner != AssistantActivityBackend.this) {
                        Log.i(TAG, "control stop routed to active runner");
                        runner.stopTask();
                        runner.moveTaskToBack(true);
                    } else {
                        stopTask();
                    }
                    moveTaskToBack(true);
                }
            });
        }
        if (intent.getBooleanExtra(EXTRA_CONFIRM_APPROVE, false)) {
            postToUi(new Runnable() {
                @Override
                public void run() {
                    AssistantActivityBackend runner = sActiveControlRunner;
                    if (runner != null) {
                        runner.confirmPending(true);
                    } else {
                        confirmPending(true);
                    }
                    moveTaskToBack(true);
                }
            });
        }
        if (intent.getBooleanExtra(EXTRA_CONFIRM_DENY, false)) {
            postToUi(new Runnable() {
                @Override
                public void run() {
                    AssistantActivityBackend runner = sActiveControlRunner;
                    if (runner != null) {
                        runner.confirmPending(false);
                    } else {
                        confirmPending(false);
                    }
                    moveTaskToBack(true);
                }
            });
        }
        if (intent.getBooleanExtra(EXTRA_TOGGLE_AGENT, false)) {
            postToUi(new Runnable() {
                @Override
                public void run() {
                    if (holdToRecord) {
                        handleVolumeChordToggle();
                        moveTaskToBack(true);
                        return;
                    }
                    AssistantActivityBackend runner = sActiveControlRunner;
                    if (runner != null && runner.isAgentOrVoiceActive()) {
                        if (runner.isVoiceToggleProtected()) {
                            Log.i(TAG, "voice toggle ignored while pipeline is active");
                            runner.moveTaskToBack(true);
                            moveTaskToBack(true);
                            return;
                        }
                        runner.stopTask();
                        runner.moveTaskToBack(true);
                        moveTaskToBack(true);
                    } else if (isAgentOrVoiceActive()) {
                        if (isVoiceToggleProtected()) {
                            Log.i(TAG, "voice toggle ignored while pipeline is active");
                            moveTaskToBack(true);
                            return;
                        }
                        stopTask();
                        moveTaskToBack(true);
                    } else {
                        startIslandVoiceAgent(holdToRecord);
                    }
                }
            });
        }
        if (!debugIntentExtrasAllowed()) {
            return;
        }
        String apiKey = intent.getStringExtra(EXTRA_DEV_OPENAI_API_KEY);
        if (apiKey != null) {
            mComposeUseRealtime = true;
            mComposeUseBroker = false;
            mComposeApiKey = apiKey;
            persistDebugKey(SECURE_DEV_OPENAI_API_KEY, apiKey);
            refreshModelDisclosure();
        }
        String geminiApiKey = intent.getStringExtra(EXTRA_DEV_GEMINI_API_KEY);
        if (geminiApiKey != null) {
            mComposeUseGeminiLiveVoice = true;
            mComposeUseLiveRealtimeVoice = false;
            mComposeUseBroker = false;
            mComposeGeminiApiKey = geminiApiKey;
            persistVoiceMode(VOICE_MODE_GEMINI_LIVE);
            persistDebugKey(SECURE_DEV_GEMINI_API_KEY, geminiApiKey);
            refreshModelDisclosure();
        }
        String goal = debugGoalFromIntent(intent);
        if (goal != null) {
            setCurrentGoalText(goal);
        }
        if (intent.getBooleanExtra(EXTRA_RUN, false)) {
            postToUi(new Runnable() {
                @Override
                public void run() {
                    routeMessageFromCurrentMessage();
                    if (isControlSurface()) {
                        moveTaskToBack(true);
                    }
                }
            });
        }
    }

    private static boolean debugIntentExtrasAllowed() {
        return "userdebug".equals(Build.TYPE) || "eng".equals(Build.TYPE);
    }

    protected boolean isControlSurface() {
        return false;
    }

    private boolean isAgentOrVoiceActive() {
        return mListening || mActiveTaskId != null || mAgentThread != null
                || mChatThread != null || mRunningChatAdapter != null
                || mRunningRealtimeVoiceSession != null
                || mRunningGeminiLiveVoiceSession != null;
    }

    private boolean hasPendingVolumeChord() {
        return mVolumeChordPendingClassic;
    }

    private void handleVolumeChordToggle() {
        AssistantActivityBackend runner = sActiveControlRunner;
        if (runner != null && runner != this) {
            if (runner.hasPendingVolumeChord()) {
                runner.handleVolumeChordToggleOnRunner();
                runner.moveTaskToBack(true);
                return;
            }
            if (runner.isAgentOrVoiceActive()) {
                if (runner.isVoiceToggleProtected()) {
                    Log.i(TAG, "voice toggle ignored while pipeline is active");
                    runner.moveTaskToBack(true);
                    return;
                }
                runner.stopTask();
                runner.moveTaskToBack(true);
                return;
            }
        }
        handleVolumeChordToggleOnRunner();
    }

    private void handleVolumeChordToggleOnRunner() {
        if (isAgentOrVoiceActive() && !mVolumeChordPendingClassic) {
            if (isVoiceToggleProtected()) {
                Log.i(TAG, "voice toggle ignored while pipeline is active");
                return;
            }
            stopTask();
            return;
        }
        long now = SystemClock.uptimeMillis();
        if (mVolumeChordPendingClassic
                || (sLastQuickVolumeChordUptimeMillis > 0
                        && now - sLastQuickVolumeChordUptimeMillis
                                <= VOLUME_CHORD_DOUBLE_TAP_MILLIS)) {
            Log.i(TAG, "volume chord double tap starts voice runtime="
                    + selectedVolumeRuntime());
            cancelPendingVolumeChord();
            sLastQuickVolumeChordUptimeMillis = 0L;
            startVolumeVoiceAgent(false);
            return;
        }
        Log.i(TAG, "volume chord waiting for hold-or-double");
        mVolumeChordPendingClassic = true;
        mVolumeChordClassicStarted = false;
        sLastQuickVolumeChordUptimeMillis = 0L;
        if (isControlSurface()) {
            sActiveControlRunner = this;
        }
        final int generation = ++mVolumeChordGeneration;
        setTaskText(volumeChordPrompt());
        updateIsland("Volume chord");
        postToUi(new Runnable() {
            @Override
            public void run() {
                if (generation != mVolumeChordGeneration || !mVolumeChordPendingClassic) {
                    return;
                }
                Log.i(TAG, "volume chord hold starts classic voice");
                mVolumeChordPendingClassic = false;
                mVolumeChordClassicStarted = true;
                startVolumeVoiceAgent(true);
            }
        }, VOLUME_CHORD_CLASSIC_HOLD_MILLIS);
    }

    private String selectedVolumeRuntime() {
        return AssistantBrainConfig.routeVolumeRuntime(this, RuntimeConfig.load(this));
    }

    private String volumeChordPrompt() {
        String runtime = selectedVolumeRuntime();
        if (!AssistantBrainConfig.BUILTIN.equals(runtime)) {
            return "Hold or double-click to speak to "
                    + RuntimeRegistry.label(runtime) + ".";
        }
        return "Hold for classic, double-click for " + liveVoiceLabel() + ".";
    }

    private void cancelPendingVolumeChord() {
        mVolumeChordGeneration++;
        mVolumeChordPendingClassic = false;
        mVolumeChordClassicStarted = false;
    }

    private boolean isRecentVoiceStart() {
        return mListening && mLastVoiceStartUptimeMillis > 0
                && SystemClock.uptimeMillis() - mLastVoiceStartUptimeMillis
                        < VOICE_TOGGLE_DUPLICATE_GRACE_MILLIS;
    }

    private boolean isVoiceToggleProtected() {
        if (isRecentVoiceStart()) {
            return true;
        }
        if (!mVoicePipelineToggleProtected) {
            return false;
        }
        if (mVoicePipelineStartedUptimeMillis <= 0
                || SystemClock.uptimeMillis() - mVoicePipelineStartedUptimeMillis
                        > VOICE_PIPELINE_TOGGLE_PROTECTION_MILLIS) {
            clearVoicePipelineProtection();
            return false;
        }
        return true;
    }

    private void protectVoicePipelineFromToggle() {
        mVoicePipelineToggleProtected = true;
        mVoicePipelineStartedUptimeMillis = SystemClock.uptimeMillis();
    }

    private void clearVoicePipelineProtection() {
        mVoicePipelineToggleProtected = false;
        mVoicePipelineStartedUptimeMillis = 0L;
    }

    private void finishVoicePipelineIfIdle() {
        clearVoicePipelineProtection();
        if (sActiveControlRunner == this && !isAgentOrVoiceActive()) {
            sActiveControlRunner = null;
        }
    }

    private static String debugGoalFromIntent(Intent intent) {
        String encodedGoal = intent.getStringExtra(EXTRA_GOAL_BASE64);
        if (encodedGoal != null && !encodedGoal.isEmpty()) {
            try {
                return new String(Base64.decode(encodedGoal, Base64.DEFAULT),
                        java.nio.charset.StandardCharsets.UTF_8);
            } catch (IllegalArgumentException e) {
                return "";
            }
        }
        return intent.getStringExtra(EXTRA_GOAL);
    }

    private void postToUi(Runnable runnable) {
        mMainHandler.post(runnable);
    }

    private void postToUi(Runnable runnable, long delayMillis) {
        mMainHandler.postDelayed(runnable, Math.max(0L, delayMillis));
    }

    public void setComposeStateCallbacks(ComposeStateCallbacks callbacks) {
        mComposeStateCallbacks = callbacks;
        pushComposeModelConfig();
        pushComposeAutonomyMode();
        refreshModelDisclosure();
    }

    public void onComposeComposerTextChanged(String text) {
        mComposeGoalText = text == null ? "" : text;
        updateComposerActionButton();
    }

    public void onComposeActionJsonChanged(String text) {
        mComposeActionJson = text == null ? "" : text;
    }

    public void onComposeModelConfigChanged(boolean useRealtime, boolean useRealtime2,
            boolean useLiveRealtimeVoice, boolean useGeminiLiveVoice, boolean useBroker,
            String apiKey, String geminiApiKey, String brokerUrl, String brokerToken) {
        mComposeUseRealtime = useRealtime;
        mComposeUseRealtime2 = useRealtime && useRealtime2;
        mComposeUseGeminiLiveVoice = useGeminiLiveVoice;
        mComposeUseLiveRealtimeVoice = useLiveRealtimeVoice && !useGeminiLiveVoice;
        mComposeUseBroker = useBroker;
        mComposeApiKey = apiKey == null ? "" : apiKey;
        mComposeGeminiApiKey = geminiApiKey == null ? "" : geminiApiKey;
        mComposeBrokerUrl = brokerUrl == null ? "" : brokerUrl;
        mComposeBrokerToken = brokerToken == null ? "" : brokerToken;
        persistVoiceMode(useGeminiLiveVoice ? VOICE_MODE_GEMINI_LIVE
                : useLiveRealtimeVoice ? VOICE_MODE_LIVE_REALTIME_2 : VOICE_MODE_CLASSIC);
        persistDebugKey(SECURE_DEV_OPENAI_API_KEY, mComposeApiKey);
        persistDebugKey(SECURE_DEV_GEMINI_API_KEY, mComposeGeminiApiKey);
        refreshModelDisclosure();
    }

    public void onComposeGrantsChanged(boolean input, boolean screenCapture, boolean clipboard,
            boolean share, boolean network) {
        mComposeInputGrant = input;
        mComposeScreenCaptureGrant = screenCapture;
        mComposeClipboardGrant = clipboard;
        mComposeShareGrant = share;
        mComposeNetworkGrant = network;
        persistGrantDefault(PREF_GRANT_INPUT, SECURE_GRANT_INPUT, input);
        persistGrantDefault(PREF_GRANT_SCREEN_CAPTURE, SECURE_GRANT_SCREEN_CAPTURE,
                screenCapture);
        persistGrantDefault(PREF_GRANT_CLIPBOARD, SECURE_GRANT_CLIPBOARD, clipboard);
        persistGrantDefault(PREF_GRANT_SHARE, SECURE_GRANT_SHARE, share);
        persistGrantDefault(PREF_GRANT_NETWORK, SECURE_GRANT_NETWORK, network);
    }

    public void onComposeAutonomyModeChanged(String mode) {
        mAutonomyMode = cleanAutonomyMode(mode);
        grantPrefs().edit().putString(PREF_AUTONOMY_MODE, mAutonomyMode).apply();
        try {
            Settings.Secure.putString(getContentResolver(), SECURE_AUTONOMY_MODE, mAutonomyMode);
        } catch (SecurityException ignored) {
        }
        pushIslandAutonomy();
        updateIsland(autonomyModeLabel(mAutonomyMode) + " mode");
        setTaskText("Autonomy mode: " + autonomyModeLabel(mAutonomyMode));
    }

    public void onComposeOtaFeedUrlChanged(String feedUrl) {
        mComposeOtaFeedUrl = feedUrl == null ? "" : feedUrl;
    }

    public void onComposeSend() {
        routeMessageFromCurrentMessage();
    }

    public void onComposeMic() {
        startVoiceAgent();
    }

    public void onComposeStop() {
        if (mActiveTaskId == null && mAgentThread == null && mChatThread != null) {
            cancelChatRun();
            setTaskText("Chat stopped");
            updateIsland("Ready");
            updateComposerActionButton();
            return;
        }
        stopTask();
    }

    public void onComposeShowAdvanced() {
        mComposeAdvancedVisible = true;
        showAdvancedSurface();
    }

    public void onComposeShowChat() {
        mComposeAdvancedVisible = false;
        showChatSurface();
    }

    public void onComposeShowRuntimes() {
        mComposeAdvancedVisible = true;
    }

    public String onComposeRuntimeStatusSnapshot() {
        return composeRuntimeStatusJson();
    }

    public String onComposeRefreshRuntimes() {
        startAssistantServiceAction(OpenPhoneAssistantService.ACTION_LOG_RUNTIME_STATUS);
        return composeRuntimeStatusJson();
    }

    public String onComposeReloadRuntimes() {
        startAssistantServiceAction(OpenPhoneAssistantService.ACTION_RELOAD_RUNTIMES);
        return composeRuntimeStatusJson();
    }

    public String onComposeSelectChatRuntime(String mode) {
        AssistantBrainConfig.persistMode(this, mode);
        return composeRuntimeStatusJson();
    }

    public String onComposeSelectVolumeRuntime(String mode) {
        AssistantBrainConfig.persistVolumeMode(this, mode);
        return composeRuntimeStatusJson();
    }

    public String onComposeSelectBackgroundRuntime(String mode) {
        AssistantBrainConfig.persistBackgroundMode(this, mode);
        return composeRuntimeStatusJson();
    }

    public void onComposeStartTask() {
        startTask();
    }

    public void onComposeRunAgent() {
        runAgent();
    }

    public void onComposeRefresh() {
        refreshAll();
    }

    public void onComposeCheckOta() {
        checkOtaFeed();
    }

    public void onComposeDownloadOta() {
        downloadLatestOta();
    }

    public void onComposeApprove() {
        confirmPending(true);
    }

    public void onComposeDeny() {
        confirmPending(false);
    }

    public void onComposeReadScreen() {
        readScreenContext();
    }

    public void onComposeReadScreenshot() {
        readScreenshotContext();
    }

    public void onComposeExecuteBack() {
        executeBack();
    }

    public void onComposeRunRawAction() {
        requestAction();
    }

    public void onComposeExportTrace() {
        exportLatestTrajectory();
    }

    public void onComposeExportAudit() {
        exportAuditEvidence();
    }

    private String currentGoalText() {
        return mComposeGoalText == null ? "" : mComposeGoalText;
    }

    private void setCurrentGoalText(String text) {
        mComposeGoalText = text == null ? "" : text;
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setComposerText(mComposeGoalText);
        }
        updateComposerActionButton();
    }

    private String currentActionJson() {
        return mComposeActionJson == null ? "" : mComposeActionJson;
    }

    private boolean inputGrantEnabled() {
        return mComposeInputGrant;
    }

    private boolean screenCaptureGrantEnabled() {
        return mComposeScreenCaptureGrant;
    }

    private boolean clipboardGrantEnabled() {
        return mComposeClipboardGrant;
    }

    private boolean shareGrantEnabled() {
        return mComposeShareGrant;
    }

    private boolean networkGrantEnabled() {
        return mComposeNetworkGrant;
    }

    private boolean useRealtimeModel() {
        return mComposeUseRealtime;
    }

    private boolean useLiveRealtimeVoice() {
        String voiceMode = voiceModeDefault();
        if (VOICE_MODE_LIVE_REALTIME_2.equals(voiceMode)
                || VOICE_MODE_GEMINI_LIVE.equals(voiceMode)) {
            return true;
        }
        return mComposeUseLiveRealtimeVoice || mComposeUseGeminiLiveVoice;
    }

    private boolean useOpenAiLiveRealtimeVoice() {
        if (VOICE_MODE_LIVE_REALTIME_2.equals(voiceModeDefault())) {
            return true;
        }
        return mComposeUseLiveRealtimeVoice && !mComposeUseGeminiLiveVoice;
    }

    private boolean useGeminiLiveVoice() {
        if (VOICE_MODE_GEMINI_LIVE.equals(voiceModeDefault())) {
            return true;
        }
        return mComposeUseGeminiLiveVoice;
    }

    private String liveVoiceLabel() {
        return useGeminiLiveVoice() ? "Gemini Live" : "Live Realtime 2";
    }

    private String realtimeModelId() {
        return mComposeUseRealtime2
                ? OpenAiRealtimeAdapter.REALTIME_2_MODEL
                : OpenAiRealtimeAdapter.DEFAULT_REALTIME_MODEL;
    }

    private boolean useBrokerModel() {
        return mComposeUseBroker;
    }

    private String geminiApiKey() {
        String apiKey = mComposeGeminiApiKey == null ? "" : mComposeGeminiApiKey;
        if (apiKey.isEmpty() && debugIntentExtrasAllowed()) {
            apiKey = Settings.Secure.getString(getContentResolver(), SECURE_DEV_GEMINI_API_KEY);
        }
        return apiKey == null ? "" : apiKey;
    }

    private void setTaskText(String text) {
        mComposeTaskText = text == null ? "" : text;
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setTaskStatus(mComposeTaskText);
        }
    }

    private void setContextText(String text) {
        mComposeContextText = text == null ? "" : text;
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setContextText(mComposeContextText);
        }
    }

    private void setAuditText(String text) {
        mComposeAuditText = text == null ? "" : text;
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setAuditText(mComposeAuditText);
        }
    }

    private void setModelDisclosureText(String text) {
        mComposeModelDisclosureText = text == null ? "" : text;
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setModelDisclosure(mComposeModelDisclosureText);
        }
    }

    private void pushComposeModelConfig() {
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setModelConfig(mComposeUseRealtime, mComposeUseRealtime2,
                    mComposeUseLiveRealtimeVoice, mComposeUseGeminiLiveVoice,
                    mComposeUseBroker, mComposeApiKey, mComposeGeminiApiKey,
                    mComposeBrokerUrl, mComposeBrokerToken);
        }
    }

    private void pushComposeAutonomyMode() {
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setAutonomyMode(mAutonomyMode);
        }
    }

    private void setOtaStatusText(String text) {
        mComposeOtaStatusText = text == null ? "" : text;
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setOtaStatus(mComposeOtaStatusText, mLatestOtaUpdate != null);
        }
    }

    private void loadComposeDefaults() {
        mComposeInputGrant = grantDefault(PREF_GRANT_INPUT, SECURE_GRANT_INPUT, true);
        mComposeScreenCaptureGrant = grantDefault(PREF_GRANT_SCREEN_CAPTURE,
                SECURE_GRANT_SCREEN_CAPTURE, true);
        mComposeClipboardGrant = grantDefault(PREF_GRANT_CLIPBOARD, SECURE_GRANT_CLIPBOARD,
                false);
        mComposeShareGrant = grantDefault(PREF_GRANT_SHARE, SECURE_GRANT_SHARE, false);
        mComposeNetworkGrant = grantDefault(PREF_GRANT_NETWORK, SECURE_GRANT_NETWORK, false);
        mAutonomyMode = autonomyModeDefault();
        String voiceMode = voiceModeDefault();
        mComposeUseLiveRealtimeVoice = VOICE_MODE_LIVE_REALTIME_2.equals(voiceMode);
        mComposeUseGeminiLiveVoice = VOICE_MODE_GEMINI_LIVE.equals(voiceMode);
        pushIslandAutonomy();
        if (debugIntentExtrasAllowed()) {
            String apiKey = Settings.Secure.getString(getContentResolver(),
                    SECURE_DEV_OPENAI_API_KEY);
            mComposeApiKey = apiKey == null ? "" : apiKey;
            if (!mComposeApiKey.isEmpty()) {
                mComposeUseRealtime = true;
                mComposeUseBroker = false;
            }
            String geminiApiKey = Settings.Secure.getString(getContentResolver(),
                    SECURE_DEV_GEMINI_API_KEY);
            mComposeGeminiApiKey = geminiApiKey == null ? "" : geminiApiKey;
        }
        if (mComposeUseLiveRealtimeVoice) {
            mComposeUseRealtime = true;
            mComposeUseRealtime2 = true;
            mComposeUseBroker = false;
        }
        if (mComposeUseGeminiLiveVoice) {
            mComposeUseBroker = false;
        }
    }

    private SharedPreferences grantPrefs() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    private String autonomyModeDefault() {
        String fallback = grantPrefs().getString(PREF_AUTONOMY_MODE, "reviewed");
        String secure = Settings.Secure.getString(getContentResolver(), SECURE_AUTONOMY_MODE);
        return cleanAutonomyMode(secure == null || secure.trim().isEmpty() ? fallback : secure);
    }

    private String voiceModeDefault() {
        String fallback = grantPrefs().getString(PREF_VOICE_MODE, VOICE_MODE_CLASSIC);
        String secure = Settings.Secure.getString(getContentResolver(), SECURE_VOICE_MODE);
        return cleanVoiceMode(secure == null || secure.trim().isEmpty() ? fallback : secure);
    }

    private void persistVoiceMode(String voiceMode) {
        String clean = cleanVoiceMode(voiceMode);
        grantPrefs().edit().putString(PREF_VOICE_MODE, clean).apply();
        try {
            Settings.Secure.putString(getContentResolver(), SECURE_VOICE_MODE, clean);
        } catch (SecurityException ignored) {
        }
    }

    private static String cleanVoiceMode(String voiceMode) {
        if (VOICE_MODE_LIVE_REALTIME_2.equals(voiceMode)) {
            return VOICE_MODE_LIVE_REALTIME_2;
        }
        if (VOICE_MODE_GEMINI_LIVE.equals(voiceMode)) {
            return VOICE_MODE_GEMINI_LIVE;
        }
        return VOICE_MODE_CLASSIC;
    }

    private void persistDebugKey(String secureKey, String value) {
        if (!debugIntentExtrasAllowed()) {
            return;
        }
        try {
            Settings.Secure.putString(getContentResolver(), secureKey,
                    value == null ? "" : value);
        } catch (SecurityException ignored) {
        }
    }

    private void reloadAutonomyMode() {
        String previous = mAutonomyMode;
        mAutonomyMode = autonomyModeDefault();
        if (!mAutonomyMode.equals(previous)) {
            pushIslandAutonomy();
            pushComposeAutonomyMode();
        }
    }

    private static String cleanAutonomyMode(String mode) {
        String clean = mode == null ? "" : mode.trim().toLowerCase(Locale.US);
        if ("yolo".equals(clean)) {
            return "yolo";
        }
        if ("dry_run".equals(clean) || "dry run".equals(clean) || "dry-run".equals(clean)) {
            return "dry_run";
        }
        return "reviewed";
    }

    private static String autonomyModeLabel(String mode) {
        if ("yolo".equals(mode)) {
            return "YOLO";
        }
        if ("dry_run".equals(mode)) {
            return "Dry run";
        }
        return "Reviewed";
    }

    private boolean grantDefault(String prefKey, String secureKey, boolean defaultChecked) {
        int fallback = grantPrefs().getBoolean(prefKey, defaultChecked) ? 1 : 0;
        return Settings.Secure.getInt(getContentResolver(), secureKey, fallback) == 1;
    }

    private void writeSecureGrantDefault(String secureKey, boolean enabled) {
        try {
            Settings.Secure.putInt(getContentResolver(), secureKey, enabled ? 1 : 0);
        } catch (SecurityException ignored) {
            grantPrefs();
        }
    }

    private void persistGrantDefault(String prefKey, String secureKey, boolean enabled) {
        grantPrefs().edit().putBoolean(prefKey, enabled).apply();
        writeSecureGrantDefault(secureKey, enabled);
    }

    private void updateComposerActionButton() {
    }

    private void refreshAll() {
        if (mAgentManager == null) {
            updateIsland("Assistant unavailable");
            setTaskText("OpenPhone system service is unavailable.");
            setContextText("");
            setAuditText("");
            return;
        }
        updateIsland(statusSummary(mAgentManager.getServiceStatus()));
        refreshAudit();
    }

    private void refreshModelDisclosure() {
        ModelAdapter adapter = selectedModelAdapter(modelEndpointConfig());
        String disclosure = modelRunDisclosure(adapter);
        if (adapter.usesCloud()) {
            ModelEndpointConfig endpointConfig = modelEndpointConfig();
            if (useGeminiLiveVoice()) {
                disclosure += "\n\nVoice: Gemini Live / "
                        + GeminiLiveVoiceSession.MODEL
                        + ". Volume buttons start a live speech-to-speech session. "
                        + "Mic audio and about one screen frame per second stream to Gemini "
                        + "while the session is active, and model audio is played back on "
                        + "the phone.";
            } else if (useOpenAiLiveRealtimeVoice()) {
                disclosure += "\n\nVoice: OpenAI Live Realtime 2 / "
                        + OpenAiRealtimeVoiceSession.MODEL
                        + ". Volume buttons start a live speech-to-speech session. "
                        + "Mic audio streams to OpenAI while the session is active, "
                        + "and model audio is played back on the phone.";
            } else {
                disclosure += "\n\nVoice: "
                        + (endpointConfig.isBrokerMode()
                                ? endpointConfig.providerDisplayName()
                                : OpenAiSpeechTranscriber.providerDisplayName())
                        + " / " + OpenAiSpeechTranscriber.modelName()
                        + ". " + voicePrivacyDisclosure(endpointConfig);
            }
        } else if (useGeminiLiveVoice()) {
            disclosure += "\n\nVoice: Gemini Live / "
                    + GeminiLiveVoiceSession.MODEL
                    + ". Volume buttons start a live speech-to-speech session. "
                    + "Mic audio and about one screen frame per second stream to Gemini "
                    + "while the session is active, and model audio is played back on "
                    + "the phone.";
        }
        setModelDisclosureText(disclosure);
    }

    private ModelAdapter selectedModelAdapter(ModelEndpointConfig endpointConfig) {
        return useRealtimeModel()
                ? new OpenAiRealtimeAdapter(endpointConfig, realtimeModelId(),
                        "yolo".equals(mAutonomyMode))
                : new LocalHeuristicModelAdapter();
    }

    private ModelEndpointConfig modelEndpointConfig() {
        if (useBrokerModel()) {
            return ModelEndpointConfig.broker(mComposeBrokerUrl, mComposeBrokerToken);
        }
        String apiKey = mComposeApiKey;
        if (apiKey.isEmpty() && debugIntentExtrasAllowed()) {
            apiKey = Settings.Secure.getString(getContentResolver(), SECURE_DEV_OPENAI_API_KEY);
        }
        return ModelEndpointConfig.directOpenAi(apiKey == null ? "" : apiKey);
    }

    private static String modelRunDisclosure(ModelAdapter adapter) {
        return "Provider: " + adapter.providerDisplayName()
                + "\nModel: " + adapter.modelName()
                + "\nCloud model: " + (adapter.usesCloud() ? "yes" : "no")
                + "\n" + adapter.privacyDisclosure();
    }

    private static String voicePrivacyDisclosure(ModelEndpointConfig endpointConfig) {
        if (endpointConfig != null && endpointConfig.isBrokerMode()) {
            return "Voice start records a short command and sends it to the configured "
                    + "OpenPhone model broker for transcription. The transcript becomes the "
                    + "task text; audio is not stored by OpenPhone.";
        }
        return OpenAiSpeechTranscriber.privacyDisclosure();
    }

    private void startVoiceAgent() {
        startVoiceAgent(false);
    }

    private void startVoiceAgent(boolean holdToRecord) {
        startVoiceAgent(holdToRecord, false);
    }

    private void startVoiceAgent(boolean holdToRecord, boolean forceClassic) {
        startVoiceAgent(holdToRecord, forceClassic, "chat_voice");
    }

    private void startVoiceAgent(boolean holdToRecord, boolean forceClassic,
            String routeSource) {
        mVoiceRouteSource = routeSource == null || routeSource.trim().isEmpty()
                ? "chat_voice" : routeSource.trim();
        Log.i(TAG, "voice start requested listening=" + mListening
                + " live=" + useLiveRealtimeVoice()
                + " forceClassic=" + forceClassic
                + " configured=" + modelEndpointConfig().isConfigured()
                + " broker=" + modelEndpointConfig().isBrokerMode()
                + " control=" + isControlSurface()
                + " hold=" + holdToRecord);
        if (mListening) {
            return;
        }
        if (!forceClassic && useGeminiLiveVoice() && geminiApiKey().trim().isEmpty()) {
            setTaskText("Gemini Live setup is missing. Add a Gemini API key in "
                    + "Developer settings or via openphone_dev_gemini_api_key.");
            updateIsland("Setup needed");
            if (mIslandVoiceLaunch) {
                finishIslandVoiceLaunch();
            }
            return;
        }
        if ((!useGeminiLiveVoice() || forceClassic) && !modelEndpointConfig().isConfigured()) {
            setTaskText("Model setup is missing. Open Developer settings and add a "
                    + "broker token or development API key.");
            updateIsland("Setup needed");
            if (mIslandVoiceLaunch) {
                finishIslandVoiceLaunch();
            }
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            mVoiceHoldToRecord = holdToRecord;
            mPendingVoiceForceClassic = forceClassic;
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQUEST_RECORD_AUDIO);
            return;
        }
        if (!forceClassic && useLiveRealtimeVoice()) {
            startLiveVoiceAgent();
            return;
        }
        Log.i(TAG, "voice start control=" + isControlSurface()
                + " island=" + mIslandVoiceLaunch
                + " hold=" + holdToRecord);
        listenThenRun(holdToRecord, mVoiceRouteSource);
        if (mIslandVoiceLaunch) {
            getWindow().getDecorView().post(new Runnable() {
                @Override
                public void run() {
                    moveTaskToBack(true);
                }
            });
        }
    }

    private void startIslandVoiceAgent() {
        startIslandVoiceAgent(false);
    }

    private void startIslandVoiceAgent(boolean holdToRecord) {
        startIslandVoiceAgent(holdToRecord, false);
    }

    private void startIslandVoiceAgent(boolean holdToRecord, boolean forceClassic) {
        mIslandVoiceLaunch = true;
        startVoiceAgent(holdToRecord, forceClassic, "island_voice");
    }

    private void startVolumeVoiceAgent(boolean holdToRecord) {
        mIslandVoiceLaunch = true;
        boolean forceClassic = !RuntimeRegistry.isBuiltin(selectedVolumeRuntime());
        startVoiceAgent(holdToRecord, forceClassic, "volume_voice");
    }

    private void finishIslandVoiceLaunch() {
        mIslandVoiceLaunch = false;
        moveTaskToBack(true);
    }

    private void finishVoiceCaptureFromHold() {
        AssistantActivityBackend runner = sActiveControlRunner;
        if (runner != null && runner != this) {
            runner.finishVoiceCaptureFromHold();
            moveTaskToBack(true);
            return;
        }
        if (mVolumeChordPendingClassic) {
            Log.i(TAG, "volume chord quick tap recorded");
            cancelPendingVolumeChord();
            sLastQuickVolumeChordUptimeMillis = SystemClock.uptimeMillis();
            if (sActiveControlRunner == this && !isAgentOrVoiceActive()) {
                sActiveControlRunner = null;
            }
            moveTaskToBack(true);
            return;
        }
        if (mRunningRealtimeVoiceSession != null || mRunningGeminiLiveVoiceSession != null) {
            moveTaskToBack(true);
            return;
        }
        if (!mListening || !mVoiceHoldToRecord) {
            moveTaskToBack(true);
            return;
        }
        mVoiceCaptureFinishRequested = true;
        OpenAiSpeechTranscriber speechTranscriber = mRunningSpeechTranscriber;
        if (speechTranscriber != null) {
            speechTranscriber.stopRecording();
        }
        moveTaskToBack(true);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions,
            int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQUEST_RECORD_AUDIO) {
            return;
        }
        if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            if (!mPendingVoiceForceClassic && useLiveRealtimeVoice()) {
                startLiveVoiceAgent();
            } else {
                listenThenRun(mVoiceHoldToRecord, mVoiceRouteSource);
            }
            mPendingVoiceForceClassic = false;
        } else {
            setTaskText("Microphone permission is needed before I can listen.");
            updateIsland("Mic blocked");
            mPendingVoiceForceClassic = false;
        }
    }

    private void startLiveVoiceAgent() {
        if (useGeminiLiveVoice()) {
            startGeminiLiveVoiceAgent();
        } else {
            startOpenAiRealtimeVoiceAgent();
        }
    }

    private void startOpenAiRealtimeVoiceAgent() {
        if (mRunningRealtimeVoiceSession != null) {
            return;
        }
        final ModelEndpointConfig endpointConfig = modelEndpointConfig();
        if (endpointConfig.isBrokerMode()) {
            String setupMessage = "Live Realtime 2 needs a direct OpenAI API key for now.";
            setTaskText(setupMessage);
            updateIsland("Setup needed");
            if (mIslandVoiceLaunch) {
                finishIslandVoiceLaunch();
            }
            return;
        }
        if (mAgentManager == null) {
            String setupMessage = "OpenPhone system service is unavailable.";
            setTaskText(setupMessage);
            updateIsland("Unavailable");
            if (mIslandVoiceLaunch) {
                finishIslandVoiceLaunch();
            }
            return;
        }
        if (isControlSurface()) {
            sActiveControlRunner = this;
        }
        mListening = true;
        mVoiceHoldToRecord = false;
        mVoiceCaptureFinishRequested = false;
        mPendingRuntimeVoiceReply = false;
        mRealtimeVoiceErrorShown = false;
        mLastVoiceStartUptimeMillis = SystemClock.uptimeMillis();
        clearVoicePipelineProtection();
        mAgentRunCancelled = false;
        final int voiceGeneration = ++mVoiceRunGeneration;
        final int runGeneration = mAgentRunGeneration.incrementAndGet();
        final OpenAiRealtimeVoiceSession session = new OpenAiRealtimeVoiceSession(endpointConfig,
                liveVoiceContinuityContextJson(), "yolo".equals(mAutonomyMode));
        mRunningRealtimeVoiceSession = session;
        Log.i(TAG, "live realtime voice start control=" + isControlSurface());
        setTaskText("Live Realtime 2 is listening.");
        updateIsland("Live");
        updateComposerActionButton();
        if (mIslandVoiceLaunch) {
            getWindow().getDecorView().post(new Runnable() {
                @Override
                public void run() {
                    moveTaskToBack(true);
                }
            });
        }
        Thread realtimeThread = new Thread(new Runnable() {
            @Override
            public void run() {
                String taskId = null;
                try {
                    String response = mAgentManager.startTask(taskRequestJson(
                            "Live Realtime 2 voice session"));
                    taskId = parseString(response, "task_id");
                    if (taskId == null || taskId.isEmpty()) {
                        postRealtimeVoiceError(voiceGeneration,
                                "Could not start the live voice task.");
                        postRealtimeVoiceStopped(voiceGeneration, null);
                        return;
                    }
                    final String liveTaskId = taskId;
                    mRealtimeVoiceTaskId = liveTaskId;
                    Log.i(TAG, "live realtime task started id=" + liveTaskId);
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            if (voiceGeneration == mVoiceRunGeneration) {
                                mActiveTaskId = liveTaskId;
                                mActiveTaskGoal = "Live Realtime 2 voice session";
                                updateComposerActionButton();
                            }
                        }
                    });
                    FrameworkToolExecutor toolExecutor = new FrameworkToolExecutor(
                            AssistantActivityBackend.this, mAgentManager);
                    session.run(liveTaskId, new ModelAdapter.ToolExecutor() {
                        @Override
                        public String callTool(String toolName, String argumentsJson) {
                            if (isCancelled()) {
                                return "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
                            }
                            try {
                                JSONObject toolArguments = new JSONObject(argumentsJson);
                                String yoloBypass = yoloConfirmationBypass(liveTaskId,
                                        toolExecutor, toolName, toolArguments);
                                if (yoloBypass != null) {
                                    return yoloBypass;
                                }
                                String dryRunPreview = dryRunPreview(toolName, toolArguments);
                                if (dryRunPreview != null) {
                                    return dryRunPreview;
                                }
                                String grantDenied = preflightDenial(toolName, toolArguments);
                                if (grantDenied != null) {
                                    return grantDenied;
                                }
                                movePointerFromTool(toolName, toolArguments);
                                if (isCancelled()) {
                                    return "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
                                }
                                return toolExecutor.execute(liveTaskId, toolName, toolArguments);
                            } catch (JSONException e) {
                                return "{\"status\":\"error\",\"reason\":\"bad_tool_json\"}";
                            }
                        }

                        @Override
                        public boolean isCancelled() {
                            return mAgentRunCancelled
                                    || runGeneration != mAgentRunGeneration.get()
                                    || voiceGeneration != mVoiceRunGeneration
                                    || Thread.currentThread().isInterrupted();
                        }
                    }, new OpenAiRealtimeVoiceSession.Callback() {
                        @Override
                        public void onStatus(String status) {
                            postRealtimeVoiceStatus(voiceGeneration, status);
                        }

                        @Override
                        public void onUserTranscript(String transcript) {
                            postRealtimeVoiceUserTranscript(voiceGeneration, transcript);
                        }

                        @Override
                        public void onAssistantTranscript(String transcript) {
                            postRealtimeVoiceAssistantTranscript(voiceGeneration, transcript);
                        }

                        @Override
                        public void onToolCall(String toolName) {
                            postRealtimeVoiceStatus(voiceGeneration,
                                    "Using " + (toolName == null ? "tool" : toolName));
                        }

                        @Override
                        public void onToolResult(String toolName, String resultJson) {
                            postRealtimeVoiceToolResult(voiceGeneration, toolName, resultJson);
                        }

                        @Override
                        public void onError(String message) {
                            postRealtimeVoiceError(voiceGeneration, message);
                        }

                        @Override
                        public void onStopped() {
                            postRealtimeVoiceStopped(voiceGeneration, liveTaskId);
                        }
                    });
                } catch (RuntimeException e) {
                    postRealtimeVoiceError(voiceGeneration, e.getClass().getSimpleName());
                    postRealtimeVoiceStopped(voiceGeneration, taskId);
                }
            }
        }, "OpenPhoneRealtimeVoice");
        mAgentThread = realtimeThread;
        realtimeThread.start();
    }

    private void startGeminiLiveVoiceAgent() {
        if (mRunningGeminiLiveVoiceSession != null) {
            return;
        }
        final String apiKey = geminiApiKey();
        if (apiKey == null || apiKey.trim().isEmpty()) {
            String setupMessage = "Gemini Live needs a Gemini API key.";
            setTaskText(setupMessage);
            updateIsland("Setup needed");
            if (mIslandVoiceLaunch) {
                finishIslandVoiceLaunch();
            }
            return;
        }
        if (mAgentManager == null) {
            String setupMessage = "OpenPhone system service is unavailable.";
            setTaskText(setupMessage);
            updateIsland("Unavailable");
            if (mIslandVoiceLaunch) {
                finishIslandVoiceLaunch();
            }
            return;
        }
        if (isControlSurface()) {
            sActiveControlRunner = this;
        }
        mListening = true;
        mVoiceHoldToRecord = false;
        mVoiceCaptureFinishRequested = false;
        mRealtimeVoiceErrorShown = false;
        mLastVoiceStartUptimeMillis = SystemClock.uptimeMillis();
        clearVoicePipelineProtection();
        mAgentRunCancelled = false;
        final int voiceGeneration = ++mVoiceRunGeneration;
        final int runGeneration = mAgentRunGeneration.incrementAndGet();
        final GeminiLiveVoiceSession session = new GeminiLiveVoiceSession(apiKey,
                liveVoiceContinuityContextJson(), "yolo".equals(mAutonomyMode));
        mRunningGeminiLiveVoiceSession = session;
        Log.i(TAG, "gemini live voice start control=" + isControlSurface());
        setTaskText("Gemini Live is listening.");
        updateIsland("Live");
        updateComposerActionButton();
        if (mIslandVoiceLaunch) {
            getWindow().getDecorView().post(new Runnable() {
                @Override
                public void run() {
                    moveTaskToBack(true);
                }
            });
        }
        Thread realtimeThread = new Thread(new Runnable() {
            @Override
            public void run() {
                String taskId = null;
                try {
                    String response = mAgentManager.startTask(taskRequestJson(
                            "Gemini Live voice session"));
                    taskId = parseString(response, "task_id");
                    if (taskId == null || taskId.isEmpty()) {
                        postRealtimeVoiceError(voiceGeneration,
                                "Could not start the Gemini Live voice task.");
                        postRealtimeVoiceStopped(voiceGeneration, null);
                        return;
                    }
                    final String liveTaskId = taskId;
                    mRealtimeVoiceTaskId = liveTaskId;
                    Log.i(TAG, "gemini live task started id=" + liveTaskId);
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            if (voiceGeneration == mVoiceRunGeneration) {
                                mActiveTaskId = liveTaskId;
                                mActiveTaskGoal = "Gemini Live voice session";
                                updateComposerActionButton();
                            }
                        }
                    });
                    FrameworkToolExecutor toolExecutor = new FrameworkToolExecutor(
                            AssistantActivityBackend.this, mAgentManager);
                    session.run(liveTaskId, new ModelAdapter.ToolExecutor() {
                        @Override
                        public String callTool(String toolName, String argumentsJson) {
                            if (isCancelled()) {
                                return "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
                            }
                            try {
                                JSONObject toolArguments = new JSONObject(argumentsJson);
                                String yoloBypass = yoloConfirmationBypass(liveTaskId,
                                        toolExecutor, toolName, toolArguments);
                                if (yoloBypass != null) {
                                    return yoloBypass;
                                }
                                String dryRunPreview = dryRunPreview(toolName, toolArguments);
                                if (dryRunPreview != null) {
                                    return dryRunPreview;
                                }
                                String grantDenied = preflightDenial(toolName, toolArguments);
                                if (grantDenied != null) {
                                    return grantDenied;
                                }
                                movePointerFromTool(toolName, toolArguments);
                                if (isCancelled()) {
                                    return "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
                                }
                                return toolExecutor.execute(liveTaskId, toolName, toolArguments);
                            } catch (JSONException e) {
                                return "{\"status\":\"error\",\"reason\":\"bad_tool_json\"}";
                            }
                        }

                        @Override
                        public boolean isCancelled() {
                            return mAgentRunCancelled
                                    || runGeneration != mAgentRunGeneration.get()
                                    || voiceGeneration != mVoiceRunGeneration
                                    || Thread.currentThread().isInterrupted();
                        }
                    }, new GeminiLiveVoiceSession.Callback() {
                        @Override
                        public void onStatus(String status) {
                            postRealtimeVoiceStatus(voiceGeneration, status);
                        }

                        @Override
                        public void onUserTranscript(String transcript) {
                            postRealtimeVoiceUserTranscript(voiceGeneration, transcript);
                        }

                        @Override
                        public void onAssistantTranscript(String transcript) {
                            postRealtimeVoiceAssistantTranscript(voiceGeneration, transcript);
                        }

                        @Override
                        public void onToolCall(String toolName) {
                            postRealtimeVoiceStatus(voiceGeneration,
                                    "Using " + (toolName == null ? "tool" : toolName));
                        }

                        @Override
                        public void onToolResult(String toolName, String resultJson) {
                            postRealtimeVoiceToolResult(voiceGeneration, toolName, resultJson);
                        }

                        @Override
                        public void onError(String message) {
                            postRealtimeVoiceError(voiceGeneration, message);
                        }

                        @Override
                        public void onStopped() {
                            postRealtimeVoiceStopped(voiceGeneration, liveTaskId);
                        }
                    });
                } catch (RuntimeException e) {
                    postRealtimeVoiceError(voiceGeneration, e.getClass().getSimpleName());
                    postRealtimeVoiceStopped(voiceGeneration, taskId);
                }
            }
        }, "OpenPhoneGeminiLiveVoice");
        mAgentThread = realtimeThread;
        realtimeThread.start();
    }

    private void postRealtimeVoiceStatus(final int voiceGeneration, final String status) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (voiceGeneration != mVoiceRunGeneration) {
                    return;
                }
                String clean = status == null || status.trim().isEmpty()
                        ? liveVoiceLabel() : status.trim();
                setTaskText(clean);
                updateIsland("Live");
            }
        });
    }

    private void postRealtimeVoiceUserTranscript(final int voiceGeneration,
            final String transcript) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (voiceGeneration != mVoiceRunGeneration || transcript == null
                        || transcript.trim().isEmpty()) {
                    return;
                }
                appendConversation("You", transcript.trim());
                if (mPointerOverlayController != null) {
                    mPointerOverlayController.setIslandState("realtime", liveVoiceLabel());
                }
            }
        });
    }

    private void postRealtimeVoiceAssistantTranscript(final int voiceGeneration,
            final String transcript) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (voiceGeneration != mVoiceRunGeneration || transcript == null
                        || transcript.trim().isEmpty()) {
                    return;
                }
                appendConversation("OpenPhone", transcript.trim());
                if (mPointerOverlayController != null) {
                    mPointerOverlayController.setIslandState("realtime", liveVoiceLabel());
                }
            }
        });
    }

    private void postRealtimeVoiceToolResult(final int voiceGeneration, final String toolName,
            final String resultJson) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (voiceGeneration != mVoiceRunGeneration || resultJson == null
                        || resultJson.trim().isEmpty()) {
                    return;
                }
                showRealtimeConfirmationIfNeeded(toolName, resultJson);
            }
        });
    }

    private void postRealtimeVoiceError(final int voiceGeneration, final String message) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (voiceGeneration != mVoiceRunGeneration) {
                    return;
                }
                String reply = liveVoiceLabel() + " failed."
                        + (message == null || message.trim().isEmpty()
                                ? "" : "\n\n" + message.trim());
                Log.w(TAG, "live realtime voice error: " + previewForLog(message));
                mRealtimeVoiceErrorShown = true;
                setTaskText(reply);
                showTerminalReplyOnIsland(reply);
            }
        });
    }

    private void postRealtimeVoiceStopped(final int voiceGeneration, final String taskId) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (voiceGeneration != mVoiceRunGeneration) {
                    return;
                }
                Log.i(TAG, "live realtime voice stopped task=" + taskId);
                stopFrameworkTaskAsync(taskId, "live_realtime_voice_stopped");
                mListening = false;
                mIslandVoiceLaunch = false;
                mRunningRealtimeVoiceSession = null;
                mRunningGeminiLiveVoiceSession = null;
                mAgentThread = null;
                if (taskId != null && taskId.equals(mRealtimeVoiceTaskId)) {
                    mRealtimeVoiceTaskId = null;
                }
                if (taskId != null && taskId.equals(mActiveTaskId)) {
                    mActiveTaskId = null;
                    mActiveTaskGoal = null;
                }
                if (sActiveControlRunner == AssistantActivityBackend.this) {
                    sActiveControlRunner = null;
                }
                PointerOverlayController.publishIdleState();
                OpenPhoneNotificationController.showReady(AssistantActivityBackend.this);
                if (!mRealtimeVoiceErrorShown) {
                    setTaskText("OpenPhone is ready.");
                    updateIsland("Ready");
                }
                updateComposerActionButton();
            }
        });
    }

    private void stopFrameworkTaskAsync(final String taskId, final String reason) {
        if (taskId == null || taskId.trim().isEmpty() || mAgentManager == null) {
            return;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject payload = new JSONObject()
                            .put("reason", reason == null ? "assistant_stopped" : reason);
                    mAgentManager.stopTask(taskId, payload.toString());
                } catch (JSONException | RuntimeException e) {
                    Log.w(TAG, "failed to stop framework task " + taskId
                            + ": " + e.getClass().getSimpleName());
                }
            }
        }, "OpenPhoneTaskStop").start();
    }

    private void listenThenRun(boolean holdToRecord) {
        listenThenRun(holdToRecord, "chat_voice");
    }

    private void listenThenRun(boolean holdToRecord, String routeSource) {
        final String cleanRouteSource = routeSource == null || routeSource.trim().isEmpty()
                ? "chat_voice" : routeSource.trim();
        final ModelEndpointConfig endpointConfig = modelEndpointConfig();
        if (isControlSurface()) {
            sActiveControlRunner = this;
        }
        mListening = true;
        mVoiceHoldToRecord = holdToRecord;
        mVoiceCaptureFinishRequested = false;
        mLastVoiceStartUptimeMillis = SystemClock.uptimeMillis();
        protectVoicePipelineFromToggle();
        updateComposerActionButton();
        final int voiceGeneration = ++mVoiceRunGeneration;
        setTaskText("Listening...\n\n" + voicePrivacyDisclosure(endpointConfig)
                + "\nProvider: " + (endpointConfig.isBrokerMode()
                        ? endpointConfig.providerDisplayName()
                        : OpenAiSpeechTranscriber.providerDisplayName())
                + "\nModel: " + OpenAiSpeechTranscriber.modelName());
        updateIsland("Listening...");
        new Thread(new Runnable() {
            @Override
            public void run() {
                String text = "";
                String error = null;
                OpenAiSpeechTranscriber transcriber = new OpenAiSpeechTranscriber(endpointConfig);
                mRunningSpeechTranscriber = transcriber;
                try {
                    if (holdToRecord) {
                        if (mVoiceCaptureFinishRequested) {
                            transcriber.stopRecording();
                        }
                        text = transcriber.recordAndTranscribeUntilStopped(
                                VOICE_HOLD_CAPTURE_MAX_MILLIS);
                    } else {
                        text = transcriber.recordAndTranscribe(VOICE_CAPTURE_MILLIS);
                    }
                } catch (IOException e) {
                    error = e.getMessage();
                } finally {
                    if (mRunningSpeechTranscriber == transcriber) {
                        mRunningSpeechTranscriber = null;
                    }
                }
                final String finalText = text;
                final String finalError = error;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (voiceGeneration != mVoiceRunGeneration) {
                            return;
                        }
                        mListening = false;
                        mVoiceHoldToRecord = false;
                        mVoiceCaptureFinishRequested = false;
                        updateComposerActionButton();
                        if (mIslandVoiceLaunch) {
                            mIslandVoiceLaunch = false;
                        }
                        if (finalError != null) {
                            if (sActiveControlRunner == AssistantActivityBackend.this) {
                                sActiveControlRunner = null;
                            }
                            Log.w(TAG, "voice transcription failed: "
                                    + previewForLog(finalError));
                            String reply = "I couldn't hear the task.\n\n" + finalError;
                            setTaskText(reply);
                            showTerminalReplyOnIsland(reply);
                            return;
                        }
                        if (finalText == null || finalText.trim().isEmpty()) {
                            if (sActiveControlRunner == AssistantActivityBackend.this) {
                                sActiveControlRunner = null;
                            }
                            Log.i(TAG, "voice transcription empty");
                            String reply = "I didn't catch that. Tap Speak and try again.";
                            setTaskText(reply);
                            showTerminalReplyOnIsland(reply);
                            return;
                        }
                        String transcript = finalText.trim();
                        Log.i(TAG, "voice transcript chars=" + transcript.length()
                                + " preview=\"" + previewForLog(transcript) + "\"");
                        setCurrentGoalText(transcript);
                        mPointerOverlayController.showTranscript(transcript);
                        if (voiceGeneration == mVoiceRunGeneration) {
                            Log.i(TAG, "voice transcript routing generation=" + voiceGeneration);
                            routeMessageFromCurrentMessage(cleanRouteSource);
                            if (isControlSurface()) {
                                moveTaskToBack(true);
                            }
                        }
                    }
                });
            }
        }, "OpenPhoneVoiceCommand").start();
    }

    private void startAgentFromCurrentGoal() {
        String goal = currentGoalText().trim();
        if (goal.isEmpty()) {
            setTaskText("Tell me what to do first.");
            updateIsland("Waiting for task");
            return;
        }
        if (mSuppressNextUserAppend) {
            mSuppressNextUserAppend = false;
        } else {
            appendConversation("You", goal);
        }
        if (mAgentManager == null) {
            refreshAll();
            return;
        }
        if (useRealtimeModel() && !modelEndpointConfig().isConfigured()) {
            String setupMessage = "Model setup is missing. Open Developer settings and add a "
                    + "broker token or development API key.";
            setTaskText(setupMessage);
            appendConversation("OpenPhone", setupMessage);
            updateIsland("Setup needed");
            setCurrentGoalText("");
            return;
        }
        if (!useRealtimeModel() && !LocalHeuristicModelAdapter.canHandleTask(goal)) {
            String localOnlyMessage = "I did not run that task. The local development adapter "
                    + "only handles simple Settings/Home/Back commands. Enable the "
                    + "OpenPhone model broker or development API key for full phone-agent tasks.";
            setTaskText(localOnlyMessage);
            appendConversation("OpenPhone", localOnlyMessage);
            updateIsland("Setup needed");
            setCurrentGoalText("");
            return;
        }
        if (mActiveTaskId != null && mAgentThread != null) {
            goal = continuationGoal(goal);
        }
        startTaskThenRunAgent(goal);
        setCurrentGoalText("");
    }

    private void startChatFromCurrentMessage() {
        final String message = currentGoalText().trim();
        if (message.isEmpty()) {
            setTaskText("Ask me anything, or tell me what to do on this phone.");
            updateIsland("Ready");
            return;
        }
        setCurrentGoalText("");
        startChatMessage(message, false);
    }

    private void startChatMessage(final String message, boolean alreadyAppended) {
        if (!alreadyAppended) {
            appendConversation("You", message);
        }
        cancelChatRun();
        mAgentRunCancelled = false;
        final int chatGeneration = ++mChatRunGeneration;
        final ModelAdapter adapter = selectedModelAdapter(modelEndpointConfig());
        mRunningChatAdapter = adapter;
        setTaskText("Thinking...");
        updateIsland("Thinking");
        Thread chatThread = new Thread(new Runnable() {
            @Override
            public void run() {
                final String reply = adapter.chat(message);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (chatGeneration != mChatRunGeneration) {
                            return;
                        }
                        mChatThread = null;
                        mRunningChatAdapter = null;
                        appendConversation("OpenPhone", reply);
                        setTaskText("OpenPhone is ready.");
                        if (reply != null && !reply.trim().isEmpty()
                                && mPointerOverlayController != null) {
                            showTerminalReplyOnIsland(reply);
                        }
                        updateComposerActionButton();
                    }
                });
            }
        }, "OpenPhoneChat");
        mChatThread = chatThread;
        updateComposerActionButton();
        chatThread.start();
    }

    private void routeMessageFromCurrentMessage() {
        routeMessageFromCurrentMessage("chat");
    }

    private void routeMessageFromCurrentMessage(String source) {
        final String message = currentGoalText().trim();
        if (message.isEmpty()) {
            setTaskText("Ask me anything, or tell me what to do on this phone.");
            updateIsland("Ready");
            return;
        }
        Log.i(TAG, "route start control=" + isControlSurface()
                + " message=\"" + previewForLog(message) + "\"");
        if (routeMessageToRuntime(message, source)) {
            return;
        }
        final OperatingMode operatingMode = currentOperatingMode();
        final boolean hasActiveTask = mActiveTaskId != null || mAgentThread != null;
        final String recentConversation = continuityContextJson();
        appendConversation("You", message);
        setCurrentGoalText("");
        cancelChatRun();
        mAgentRunCancelled = false;
        final int chatGeneration = ++mChatRunGeneration;
        final ModelAdapter adapter = selectedModelAdapter(modelEndpointConfig());
        mRunningChatAdapter = adapter;
        setTaskText("Thinking...");
        updateIsland("Thinking");
        final Runnable timeoutRunnable = new Runnable() {
            @Override
            public void run() {
                if (chatGeneration != mChatRunGeneration) {
                    return;
                }
                mChatRunGeneration++;
                ModelAdapter runningAdapter = mRunningChatAdapter;
                if (runningAdapter != null) {
                    runningAdapter.cancel();
                }
                Thread thread = mChatThread;
                if (thread != null) {
                    thread.interrupt();
                }
                mChatThread = null;
                mRunningChatAdapter = null;
                Log.w(TAG, "route timeout message=\"" + previewForLog(message) + "\"");
                String reply = "Message routing timed out. Try again in a moment.";
                appendConversation("OpenPhone", reply);
                setTaskText("OpenPhone is ready.");
                showTerminalReplyOnIsland(reply);
                if (isControlSurface()) {
                    moveTaskToBack(true);
                }
                updateComposerActionButton();
            }
        };
        Thread chatThread = new Thread(new Runnable() {
            @Override
            public void run() {
                final OrchestratorDecision decision = mOrchestrator.decide(adapter, message,
                        hasActiveTask, operatingMode, recentConversation);
                Log.i(TAG, "route decision mode="
                        + (decision == null ? "null" : decision.mode())
                        + " reason=\""
                        + previewForLog(decision == null ? "" : decision.reason()) + "\"");
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (chatGeneration != mChatRunGeneration) {
                            return;
                        }
                        getWindow().getDecorView().removeCallbacks(timeoutRunnable);
                        dispatchOrchestratorDecision(message, decision);
                    }
                });
            }
        }, "OpenPhoneOrchestrator");
        mChatThread = chatThread;
        updateComposerActionButton();
        getWindow().getDecorView().postDelayed(timeoutRunnable, ROUTING_TIMEOUT_MILLIS);
        chatThread.start();
    }

    private boolean routeMessageToRuntime(String message, String source) {
        RuntimeConfig config = RuntimeConfig.load(this);
        String route = routeRuntimeForSource(source, config);
        if (AssistantBrainConfig.BUILTIN.equals(route)) {
            return false;
        }
        String runtimeLabel = runtimeLabel(route);
        if (!config.configured(route)) {
            appendConversation("You", message);
            setCurrentGoalText("");
            cancelChatRun();
            mAgentRunCancelled = false;
            appendConversation("OpenPhone", runtimeLabel + " runtime is not configured.");
            setTaskText(runtimeLabel + " is not configured.");
            updateIsland(runtimeLabel);
            updateComposerActionButton();
            return true;
        }
        appendConversation("You", message);
        setCurrentGoalText("");
        cancelChatRun();
        mAgentRunCancelled = false;
        String cleanSource = source == null || source.trim().isEmpty() ? "chat" : source.trim();
        mPendingRuntimeVoiceReply = isVoiceRouteSource(cleanSource);
        Intent service = new Intent(this, OpenPhoneAssistantService.class);
        service.setAction(OpenPhoneAssistantService.ACTION_REQUEST_RUNTIME_ATTENTION);
        service.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_RUNTIME, route);
        service.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_TEXT, message);
        service.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_SOURCE, cleanSource);
        service.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_AUTONOMY,
                runtimeAutonomyMode());
        service.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_INCLUDE_SCREEN,
                screenCaptureGrantEnabled());
        try {
            startService(service);
        } catch (RuntimeException e) {
            Log.w(TAG, "Could not request runtime attention", e);
            mPendingRuntimeVoiceReply = false;
            appendConversation("OpenPhone",
                    "Message routing failed: " + runtimeLabel + " service request failed.");
            setTaskText(runtimeLabel + " request failed.");
            updateIsland("Needs review");
            return true;
        }
        setTaskText("Sent to " + runtimeLabel + ".");
        updateIsland(runtimeLabel);
        updateComposerActionButton();
        if (isControlSurface()) {
            moveTaskToBack(true);
        }
        return true;
    }

    private String routeRuntimeForSource(String source, RuntimeConfig config) {
        return AssistantBrainConfig.routeRuntimeForSource(this, source, config);
    }

    private static boolean isVoiceRouteSource(String source) {
        String clean = source == null ? "" : source.trim().toLowerCase(Locale.US);
        return clean.contains("voice");
    }

    private static String runtimeLabel(String runtime) {
        return RuntimeRegistry.label(runtime);
    }

    private String runtimeAutonomyMode() {
        reloadAutonomyMode();
        if ("yolo".equals(mAutonomyMode)) {
            return "trusted_actions";
        }
        if ("dry_run".equals(mAutonomyMode)) {
            return "observe_only";
        }
        return "ask_before_action";
    }

    private OperatingMode currentOperatingMode() {
        reloadAutonomyMode();
        if ("yolo".equals(mAutonomyMode)) {
            return OperatingMode.YOLO;
        }
        if ("dry_run".equals(mAutonomyMode)) {
            return OperatingMode.DRY_RUN;
        }
        return OperatingMode.REVIEWED;
    }

    private void dispatchOrchestratorDecision(String originalMessage,
            OrchestratorDecision decision) {
        if (decision == null) {
            startChatMessage(originalMessage, true);
            return;
        }
        String mode = decision.mode();
        if (OrchestratorDecision.MODE_STOP.equals(mode)) {
            mChatThread = null;
            mRunningChatAdapter = null;
            stopTask();
            return;
        }
        if (OrchestratorDecision.MODE_INSPECT_SCREEN.equals(mode)) {
            Log.i(TAG, "route dispatch inspect_screen");
            answerScreenQuestion(originalMessage, true);
            return;
        }
        if (decision.hasProposedActions()) {
            runOneShotActions(originalMessage, decision);
            return;
        }
        if (OrchestratorDecision.MODE_ACT.equals(mode)
                || OrchestratorDecision.MODE_RETRIEVE.equals(mode)
                || OrchestratorDecision.MODE_WATCH.equals(mode)
                || OrchestratorDecision.MODE_MEMORY.equals(mode)) {
            mChatThread = null;
            mRunningChatAdapter = null;
            String taskGoal = decision.taskGoal().trim();
            if (taskGoal.isEmpty()) {
                taskGoal = originalMessage;
            }
            clearVoicePipelineProtection();
            setCurrentGoalText(taskGoal);
            mSuppressNextUserAppend = true;
            startAgentFromCurrentGoal();
            updateComposerActionButton();
            return;
        }
        mChatThread = null;
        mRunningChatAdapter = null;
        String reply = decision.reply().trim();
        if (reply.isEmpty()) {
            startChatMessage(originalMessage, true);
            return;
        }
        appendConversation("OpenPhone", reply);
        setTaskText("OpenPhone is ready.");
        if (mPointerOverlayController != null) {
            showTerminalReplyOnIsland(reply);
        }
        updateComposerActionButton();
    }

    private void showTerminalReplyOnIsland(String reply) {
        if (mPointerOverlayController == null || reply == null || reply.trim().isEmpty()) {
            return;
        }
        if (isSystemFailureReply(reply)) {
            mPointerOverlayController.setIslandState("error", reply);
            finishVoicePipelineIfIdle();
            return;
        }
        mPointerOverlayController.showReply(reply);
        finishVoicePipelineIfIdle();
    }

    private void handleRuntimeMessage(String runtime, String sessionKey, String message,
            boolean terminal) {
        String clean = message == null ? "" : message.trim();
        if (clean.isEmpty()) {
            return;
        }
        String runtimeLabel = runtimeLabel(runtime);
        if (!terminal) {
            setTaskText(clean);
            updateIsland(runtimeLabel);
            return;
        }
        String dedupeKey = runtime + ":" + sessionKey + ":" + clean;
        if (dedupeKey.equals(mLastRuntimeMessageKey)) {
            return;
        }
        mLastRuntimeMessageKey = dedupeKey;
        mChatThread = null;
        mRunningChatAdapter = null;
        appendConversation(runtimeLabel, clean);
        setTaskText(runtimeLabel + " is ready.");
        showTerminalReplyOnIsland(clean);
        speakRuntimeReplyIfPending(clean);
        updateComposerActionButton();
    }

    private void speakRuntimeReplyIfPending(String reply) {
        if (!mPendingRuntimeVoiceReply) {
            return;
        }
        mPendingRuntimeVoiceReply = false;
        String clean = reply == null ? "" : reply.trim();
        if (clean.isEmpty() || isSystemFailureReply(clean)) {
            return;
        }
        speakRuntimeReply(clean);
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
                            null, "openphone-runtime-reply");
                } else {
                    Log.w(TAG, "runtime reply TTS unavailable status=" + status);
                }
            });
            return;
        }
        if (!mRuntimeReplyTtsReady) {
            Log.w(TAG, "runtime reply TTS not ready");
            return;
        }
        mRuntimeReplyTts.speak(utterance, TextToSpeech.QUEUE_FLUSH,
                null, "openphone-runtime-reply");
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
                Log.w(TAG, "runtime reply TTS shutdown failed", e);
            }
        }
    }

    private static boolean isSystemFailureReply(String reply) {
        if (reply == null) {
            return false;
        }
        return reply.startsWith("Message routing failed:")
                || reply.startsWith("Message routing timed out.")
                || reply.startsWith("Chat request failed:")
                || reply.startsWith("Screen question failed:")
                || reply.startsWith("Screen question timed out.")
                || reply.startsWith("I could not read the screen:")
                || reply.startsWith("I could not start a screen observation.")
                || reply.startsWith("I couldn't hear the task.")
                || reply.startsWith("I didn't catch that.")
                || reply.startsWith("Cloud screen understanding is not configured.")
                || reply.startsWith("I could not parse the screen context.")
                || reply.startsWith("Cloud chat is not configured.")
                || reply.startsWith("I could not parse the chat response.")
                || reply.startsWith("I could not decide how to handle that message.");
    }

    /**
     * Executes orchestrator-proposed one-shot tool calls through the same
     * policy chain as the agent loop (dry-run, task grants, app and action
     * policy) inside a transient task, without the screenshot task loop.
     */
    private void runOneShotActions(final String originalMessage,
            final OrchestratorDecision decision) {
        mChatThread = null;
        mRunningChatAdapter = null;
        final OpenPhoneAgentManager agentManager = mAgentManager;
        if (agentManager == null) {
            startChatMessage(originalMessage, true);
            return;
        }
        reloadAutonomyMode();
        cancelAgentRun();
        mAgentRunCancelled = false;
        final int runGeneration = mAgentRunGeneration.incrementAndGet();
        final JSONArray proposedActions = decision.proposedActions();
        final ModelAdapter adapter = selectedModelAdapter(modelEndpointConfig());
        final FrameworkToolExecutor toolExecutor = new FrameworkToolExecutor(this, agentManager);
        mRunningModelAdapter = adapter;
        setTaskText("Working on it...");
        updateIsland("Working");
        Thread oneShotThread = new Thread(new Runnable() {
            @Override
            public void run() {
                String taskId = null;
                boolean keepTaskForConfirmation = false;
                try {
                    String response = agentManager.startTask(taskRequestJson(originalMessage));
                    taskId = parseString(response, "task_id");
                    if (taskId == null || taskId.isEmpty()) {
                        postOneShotReply(runGeneration, "I could not start that action.",
                                "Needs review");
                        return;
                    }
                    TrajectoryRecorder trajectory = TrajectoryRecorder.start(
                            AssistantActivityBackend.this, taskId, originalMessage,
                            adapter.providerDisplayName(), adapter.modelName(),
                            adapter.usesCloud(), adapter.privacyDisclosure());
                    JSONArray results = new JSONArray();
                    for (int i = 0; i < proposedActions.length(); i++) {
                        if (mAgentRunCancelled || runGeneration != mAgentRunGeneration.get()) {
                            return;
                        }
                        JSONObject action = proposedActions.optJSONObject(i);
                        if (action == null) {
                            continue;
                        }
                        String toolName = action.optString("tool", "");
                        JSONObject arguments = action.optJSONObject("arguments");
                        if (arguments == null) {
                            arguments = new JSONObject();
                        }
                        trajectory.recordToolCall(toolName, arguments.toString());
                        String result = dryRunPreview(toolName, arguments);
                        if (result == null) {
                            result = preflightDenial(toolName, arguments);
                        }
                        if (result == null) {
                            movePointerFromTool(toolName, arguments);
                            result = toolExecutor.execute(taskId, toolName, arguments);
                        }
                        trajectory.recordToolResult(toolName, result);
                        JSONObject parsedResult = parseObjectOrEmpty(result);
                        if ("confirmation_required".equals(parsedResult.optString("status", ""))) {
                            keepTaskForConfirmation = true;
                            trajectory.recordAgentResult(result);
                            showOneShotConfirmation(runGeneration, taskId, originalMessage,
                                    result);
                            return;
                        }
                        try {
                            results.put(new JSONObject()
                                    .put("tool", toolName)
                                    .put("result", parsedResult));
                        } catch (JSONException ignored) {
                        }
                    }
                    trajectory.recordAgentResult(results.toString());
                    recordContextAgentEvent("assistant.agent.one_shot_finished",
                            "One-shot actions finished", originalMessage, taskId,
                            results.toString());
                    postOneShotReply(runGeneration,
                            oneShotChatReply(adapter, originalMessage, results.toString()),
                            "Done");
                } catch (RuntimeException e) {
                    postOneShotReply(runGeneration,
                            "I could not run that: " + e.getClass().getSimpleName(),
                            "Needs review");
                } finally {
                    if (!keepTaskForConfirmation && taskId != null) {
                        try {
                            agentManager.stopTask(taskId, "{\"reason\":\"one_shot_complete\"}");
                        } catch (RuntimeException ignored) {
                        }
                    }
                }
            }
        }, "OpenPhoneOneShot");
        mAgentThread = oneShotThread;
        updateComposerActionButton();
        oneShotThread.start();
    }

    private void postOneShotReply(final int runGeneration, final String reply,
            final String islandStatus) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (runGeneration != mAgentRunGeneration.get()) {
                    return;
                }
                mAgentThread = null;
                mRunningModelAdapter = null;
                appendConversation("OpenPhone", reply);
                setTaskText("OpenPhone is ready.");
                updateIsland(islandStatus);
                if (reply != null && !reply.trim().isEmpty()
                        && mPointerOverlayController != null
                        && "Done".equals(islandStatus)) {
                    mPointerOverlayController.showReply(reply);
                }
                updateComposerActionButton();
                refreshAudit();
            }
        });
    }

    private void showOneShotConfirmation(final int runGeneration, final String taskId,
            final String originalMessage, final String confirmationJson) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (runGeneration != mAgentRunGeneration.get()) {
                    try {
                        mAgentManager.stopTask(taskId, "{\"reason\":\"one_shot_cancelled\"}");
                    } catch (RuntimeException ignored) {
                    }
                    return;
                }
                mAgentThread = null;
                mRunningModelAdapter = null;
                mActiveTaskId = taskId;
                JSONObject confirmation = parseObjectOrEmpty(confirmationJson);
                String pendingActionId = findStringRecursive(confirmation, "pending_action_id");
                if (pendingActionId != null && !pendingActionId.isEmpty()
                        && !"null".equals(pendingActionId)) {
                    mPendingActionId = pendingActionId;
                }
                capturePendingToolAction(confirmation);
                mPendingOneShotMessage = originalMessage;
                String body = confirmationBodyFromAgentResult("confirmation_required",
                        confirmation);
                showPendingConfirmation(body);
                setTaskText(body);
                updateComposerActionButton();
                refreshAudit();
            }
        });
    }

    private void finishOneShotConfirmation(boolean approved, String userMessage,
            String toolName, String resultJson) {
        String taskId = mActiveTaskId;
        mActiveTaskId = null;
        if (taskId != null && mAgentManager != null) {
            try {
                mAgentManager.stopTask(taskId, "{\"reason\":\"one_shot_complete\"}");
            } catch (RuntimeException ignored) {
            }
        }
        mPointerOverlayController.showMicButton();
        recordContextAgentEvent("assistant.agent.one_shot_reviewed",
                approved ? "One-shot action approved" : "One-shot action denied",
                userMessage, taskId, resultJson);
        if (!approved) {
            appendConversation("OpenPhone", "Okay, I did not run that action.");
            setTaskText("OpenPhone is ready.");
            updateIsland("Denied");
            updateComposerActionButton();
            return;
        }
        if (isActionResultFailure(resultJson)) {
            appendConversation("OpenPhone", "I tried to run "
                    + (toolName == null || toolName.isEmpty() ? "that action" : toolName)
                    + " but it failed.");
            updateIsland("Needs review");
            updateComposerActionButton();
            return;
        }
        summarizeApprovedOneShot(userMessage, toolName, resultJson);
    }

    private void summarizeApprovedOneShot(final String userMessage, final String toolName,
            final String resultJson) {
        cancelChatRun();
        final int chatGeneration = ++mChatRunGeneration;
        final ModelAdapter adapter = selectedModelAdapter(modelEndpointConfig());
        mRunningChatAdapter = adapter;
        setTaskText("Thinking...");
        updateIsland("Thinking");
        Thread chatThread = new Thread(new Runnable() {
            @Override
            public void run() {
                String resultsJson;
                try {
                    resultsJson = new JSONArray().put(new JSONObject()
                            .put("tool", toolName == null ? "" : toolName)
                            .put("result", parseObjectOrEmpty(resultJson))).toString();
                } catch (JSONException e) {
                    resultsJson = resultJson;
                }
                final String reply = oneShotChatReply(adapter, userMessage, resultsJson);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (chatGeneration != mChatRunGeneration) {
                            return;
                        }
                        mChatThread = null;
                        mRunningChatAdapter = null;
                        appendConversation("OpenPhone", reply);
                        setTaskText("OpenPhone is ready.");
                        updateIsland("Done");
                        if (reply != null && !reply.trim().isEmpty()
                                && mPointerOverlayController != null) {
                            mPointerOverlayController.showReply(reply);
                        }
                        updateComposerActionButton();
                    }
                });
            }
        }, "OpenPhoneOneShotSummary");
        mChatThread = chatThread;
        updateComposerActionButton();
        chatThread.start();
    }

    private String oneShotChatReply(ModelAdapter adapter, String userMessage,
            String resultsJson) {
        String reply = "";
        try {
            reply = adapter.chat("The user said: \"" + userMessage + "\".\n"
                    + "I already ran the requested phone action(s); the tool results are:\n"
                    + truncateForPrompt(resultsJson, 6000)
                    + "\nReply to the user in one or two short sentences using only these "
                    + "results. Mention concrete details (names, counts, times) when "
                    + "present. Do not mention JSON or tool names.");
        } catch (RuntimeException ignored) {
        }
        if (reply == null || reply.trim().isEmpty()) {
            return "I finished that action.";
        }
        return reply.trim();
    }

    private static String truncateForPrompt(String text, int maxChars) {
        if (text == null) {
            return "";
        }
        return text.length() <= maxChars ? text : text.substring(0, maxChars);
    }

    private static String previewForLog(String text) {
        if (text == null) {
            return "";
        }
        String compact = text.replace('\n', ' ').replace('\r', ' ').trim();
        return compact.length() <= 96 ? compact : compact.substring(0, 96);
    }

    private void answerScreenQuestionFromCurrentMessage() {
        final String message = currentGoalText().trim();
        if (message.isEmpty()) {
            setTaskText("Ask me what you want to know about the current screen.");
            updateIsland("Ready");
            return;
        }
        appendConversation("You", message);
        setCurrentGoalText("");
        answerScreenQuestion(message, true);
    }

    private void answerScreenQuestion(final String message, boolean alreadyAppended) {
        cancelChatRun();
        mAgentRunCancelled = false;
        Log.i(TAG, "screen question start control=" + isControlSurface()
                + " message=\"" + previewForLog(message) + "\"");
        final int chatGeneration = ++mChatRunGeneration;
        final ModelAdapter adapter = selectedModelAdapter(modelEndpointConfig());
        mRunningChatAdapter = adapter;
        setTaskText("Reading the screen...");
        updateIsland("Reading screen");
        final Runnable timeoutRunnable = new Runnable() {
            @Override
            public void run() {
                if (chatGeneration != mChatRunGeneration) {
                    return;
                }
                mChatRunGeneration++;
                ModelAdapter runningAdapter = mRunningChatAdapter;
                if (runningAdapter != null) {
                    runningAdapter.cancel();
                }
                Thread thread = mChatThread;
                if (thread != null) {
                    thread.interrupt();
                }
                mChatThread = null;
                mRunningChatAdapter = null;
                Log.w(TAG, "screen question timeout message=\""
                        + previewForLog(message) + "\"");
                String reply = "Screen question timed out. Try again in a moment.";
                appendConversation("OpenPhone", reply);
                setTaskText("OpenPhone is ready.");
                showTerminalReplyOnIsland(reply);
                if (isControlSurface()) {
                    moveTaskToBack(true);
                }
                updateComposerActionButton();
            }
        };
        Thread chatThread = new Thread(new Runnable() {
            @Override
            public void run() {
                String taskId = mActiveTaskId;
                boolean transientTask = false;
                String screenJson = "";
                try {
                    if (mAgentManager == null) {
                        finalReply(adapter.chat(message));
                        return;
                    }
                    if (taskId == null || taskId.isEmpty()) {
                        String response = mAgentManager.startTask(taskRequestJson(message));
                        taskId = parseString(response, "task_id");
                        transientTask = taskId != null && !taskId.isEmpty();
                    }
                    if (taskId == null || taskId.isEmpty()) {
                        finalReply("I could not start a screen observation.");
                        return;
                    }
                    screenJson = mAgentManager.getScreen(taskId,
                            "{\"include_screenshot\":true,\"include_activity\":true,"
                                    + "\"include_ui_tree\":true,\"max_dimension\":512,"
                                    + "\"quality\":65,"
                                    + "\"reason\":\"answer the user's screen question\"}");
                    Log.i(TAG, "screen context chars="
                            + (screenJson == null ? 0 : screenJson.length()));
                    finalReply(adapter.answerScreenQuestion(message, screenJson));
                } catch (RuntimeException e) {
                    Log.w(TAG, "screen question failed", e);
                    finalReply("I could not read the screen: " + e.getClass().getSimpleName());
                } finally {
                    if (transientTask && taskId != null && mAgentManager != null) {
                        try {
                            mAgentManager.stopTask(taskId,
                                    "{\"reason\":\"screen_question_complete\"}");
                        } catch (RuntimeException ignored) {
                        }
                    }
                }
            }

            private void finalReply(final String reply) {
                Log.i(TAG, "screen question reply chars="
                        + (reply == null ? 0 : reply.length())
                        + " preview=\"" + previewForLog(reply) + "\"");
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (chatGeneration != mChatRunGeneration) {
                            return;
                        }
                        getWindow().getDecorView().removeCallbacks(timeoutRunnable);
                        mChatThread = null;
                        mRunningChatAdapter = null;
                        appendConversation("OpenPhone", reply);
                        setTaskText("OpenPhone is ready.");
                        if (reply != null && !reply.trim().isEmpty()
                                && mPointerOverlayController != null) {
                            showTerminalReplyOnIsland(reply);
                        }
                        if (isControlSurface()) {
                            moveTaskToBack(true);
                        }
                        updateComposerActionButton();
                    }
                });
            }
        }, "OpenPhoneScreenQuestion");
        mChatThread = chatThread;
        updateComposerActionButton();
        getWindow().getDecorView().postDelayed(timeoutRunnable, SCREEN_QUESTION_TIMEOUT_MILLIS);
        chatThread.start();
    }

    private void cancelChatRun() {
        mChatRunGeneration++;
        ModelAdapter adapter = mRunningChatAdapter;
        if (adapter != null) {
            adapter.cancel();
        }
        Thread thread = mChatThread;
        if (thread != null) {
            thread.interrupt();
        }
        mChatThread = null;
        mRunningChatAdapter = null;
    }

    private static String continuationGoal(String followUp) {
        return "Continue the current phone task from the visible screen state. "
                + "The user gave this follow-up instruction while the agent was running: "
                + (followUp == null ? "" : followUp);
    }

    private void appendConversation(String speaker, String message) {
        if (message == null || message.trim().isEmpty()) {
            return;
        }
        if (mContextIndexStore != null) {
            mContextIndexStore.recordConversationMessage(speaker, message.trim());
        }
        PointerOverlayController.rememberConversationMessage(speaker, message.trim());
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.addConversationMessage(speaker, message.trim());
        }
    }

    private String continuityContextJson() {
        if (mContextIndexStore == null) {
            return "{}";
        }
        try {
            return mContextIndexStore.continuityContextJson(16, 8);
        } catch (RuntimeException e) {
            try {
                return new JSONObject()
                        .put("recent_conversation_oldest_first",
                                new JSONArray(mContextIndexStore.recentConversationJson(10)))
                        .toString();
            } catch (JSONException ignored) {
                return "{}";
            }
        }
    }

    private String liveVoiceContinuityContextJson() {
        return "{}";
    }

    private void recordContextAgentEvent(String eventType, String title, String text,
            String taskId, String payloadJson) {
        if (mContextIndexStore == null) {
            return;
        }
        mContextIndexStore.recordAgentEvent(eventType, title, text, taskId, payloadJson);
    }

    private boolean isAdvancedVisible() {
        return mComposeAdvancedVisible;
    }

    private void showAdvancedSurface() {
        mComposeAdvancedVisible = true;
    }

    private void showChatSurface() {
        mComposeAdvancedVisible = false;
    }

    private String composeRuntimeStatusJson() {
        JSONObject status = parseObjectOrEmpty(
                OpenPhoneAssistantService.latestRuntimeStatusJson());
        try {
            RuntimeConfig config = RuntimeConfig.load(this);
            status.put("chat_runtime", AssistantBrainConfig.loadMode(this));
            status.put("effective_chat_runtime", AssistantBrainConfig.routeRuntime(this, config));
            status.put("volume_runtime", AssistantBrainConfig.loadVolumeMode(this));
            status.put("background_runtime", AssistantBrainConfig.loadBackgroundMode(this));
            JSONArray configured = new JSONArray();
            for (RuntimeConfig.RuntimeSettings settings : config.remoteSettings()) {
                configured.put(runtimeSettingsJson(settings));
            }
            status.put("configured", configured);
            if (!status.has("updated_at_ms")) {
                status.put("updated_at_ms", System.currentTimeMillis());
            }
            status.put("global_enabled", config.globallyEnabled);
        } catch (JSONException ignored) {
        }
        return status.toString();
    }

    private JSONObject runtimeSettingsJson(RuntimeConfig.RuntimeSettings settings)
            throws JSONException {
        return new JSONObject()
                .put("name", settings.runtime)
                .put("label", settings.label)
                .put("enabled", settings.enabled)
                .put("configured", settings.configured())
                .put("url", settings.url)
                .put("device_id", settings.deviceId);
    }

    private void startAssistantServiceAction(String action) {
        Intent service = new Intent(this, OpenPhoneAssistantService.class);
        service.setAction(action);
        try {
            startService(service);
        } catch (RuntimeException e) {
            Log.w(TAG, "Could not send service action " + action, e);
        }
    }

    public void onBackPressed() {
        if (isAdvancedVisible()) {
            mComposeAdvancedVisible = false;
            if (mComposeStateCallbacks != null) {
                mComposeStateCallbacks.showChat();
            }
            showChatSurface();
            return;
        }
        super.onBackPressed();
    }

    private void updateIsland(String text) {
        String status = text == null || text.isEmpty() ? "OpenPhone is ready" : text;
        String islandState = islandStateForStatus(status);
        // Always let terminal-state transitions through, even when no task is
        // active. Without this, postOneShotReply (which clears mAgentThread
        // and mActiveTaskId before calling updateIsland) leaves the island
        // stuck in its last running state — glow keeps pulsing, "Stop" stays
        // up — because the gate below would refuse the answer_ready / idle
        // / error transition that's supposed to dismiss it.
        boolean isTerminal = "answer_ready".equals(islandState)
                || "idle".equals(islandState)
                || "error".equals(islandState)
                || "needs_review".equals(islandState);
        if (mPointerOverlayController != null && islandState != null
                && (isTerminal || mIslandVoiceLaunch
                        || mListening || mRunningChatAdapter != null
                        || mChatThread != null || mActiveTaskId != null
                        || mAgentThread != null)) {
            mPointerOverlayController.setIslandState(islandState, status);
        }
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setRuntimeStatus(status, mActiveTaskId,
                    mAgentThread != null || mChatThread != null,
                    mListening || mIslandVoiceLaunch);
        }
    }

    private static String islandStateForStatus(String status) {
        switch (status) {
            case "Live":
                return "realtime";
            case "Thinking":
            case "Reading screen":
                return "thinking";
            case "Done":
            case "Trace exported":
            case "Audit exported":
                return "answer_ready";
            case "Needs review":
            case "Approval needed":
                return "needs_review";
            case "Start failed":
            case "Action failed":
            case "Export failed":
            case "Assistant unavailable":
            case "Setup needed":
            case "Mic blocked":
            case "Try again":
                return "error";
            case "Listening...":
                return "listening";
            case "Working":
            case "Waiting for task":
            case "Agent active":
            case "Agent is working":
            case "Starting":
            case "Continuing":
                return "action_running";
            case "Ready":
            case "Stopped":
            case "Denied":
                return "idle";
            default:
                return null;
        }
    }

    private void pushIslandAutonomy() {
        if (mPointerOverlayController != null) {
            mPointerOverlayController.setYoloActive("yolo".equals(mAutonomyMode));
        }
    }

    private void startTask() {
        if (mAgentManager == null) {
            refreshAll();
            return;
        }
        String goal = currentGoalText();
        String response = mAgentManager.startTask(taskRequestJson(goal));
        mActiveTaskId = parseString(response, "task_id");
        showTaskStarted(goal);
        refreshAudit();
    }

    private String taskRequestJson(String goal) {
        JSONObject request = new JSONObject();
        try {
            request.put("goal", goal == null ? "" : goal);
            request.put("user_visible", true);
            request.put("background_allowed", false);
            request.put("grant_defaults_source", "settings_secure");
            JSONArray capabilities = new JSONArray();
            if ("yolo".equals(mAutonomyMode)) {
                for (String capability : FULL_YOLO_APPROVED_CAPABILITIES) {
                    capabilities.put(capability);
                }
            } else {
                capabilities.put("screen.read.visible");
                capabilities.put("tasks.observe");
                capabilities.put("apps.launch");
                if (inputGrantEnabled()) {
                    capabilities.put("input.perform");
                }
                if (screenCaptureGrantEnabled()) {
                    capabilities.put("screen.capture");
                }
                if (clipboardGrantEnabled()) {
                    capabilities.put("clipboard.read");
                    capabilities.put("clipboard.write");
                }
                if (shareGrantEnabled()) {
                    capabilities.put("share.content");
                }
                if (networkGrantEnabled()) {
                    capabilities.put("network.use");
                }
            }
            request.put("approved_capabilities", capabilities);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
        return request.toString();
    }

    private void showTaskStarted(String goal) {
        mActiveTaskGoal = goal == null ? "" : goal;
        setTaskText("Working on: " + (goal == null ? "" : goal));
        updateIsland("Agent active");
        mPointerOverlayController.show(mActiveTaskId);
        OpenPhoneNotificationController.showActive(this, mActiveTaskId);
        recordContextAgentEvent("assistant.agent.task_started", "Agent task started",
                goal == null ? "" : goal, mActiveTaskId, "");
    }

    private void startTaskThenRunAgent(final String goal) {
        final OpenPhoneAgentManager agentManager = mAgentManager;
        if (agentManager == null) {
            refreshAll();
            return;
        }
        final String requestJson = taskRequestJson(goal);
        setTaskText("Starting: " + goal);
        updateIsland("Starting");
        new Thread(new Runnable() {
            @Override
            public void run() {
                String response = null;
                RuntimeException error = null;
                try {
                    response = agentManager.startTask(requestJson);
                } catch (RuntimeException e) {
                    error = e;
                }
                final String finalResponse = response;
                final RuntimeException finalError = error;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (finalError != null) {
                            setTaskText("Could not start task.\n\n"
                                    + finalError.getClass().getSimpleName());
                            updateIsland("Start failed");
                            return;
                        }
                        mActiveTaskId = parseString(finalResponse, "task_id");
                        if (mActiveTaskId == null || mActiveTaskId.isEmpty()) {
                            setTaskText("Could not start task.\n\n"
                                    + prettyForDisplay(finalResponse));
                            updateIsland("Start failed");
                            return;
                        }
                        showTaskStarted(goal);
                        refreshAudit();
                        runAgent(goal);
                    }
                });
            }
        }, "OpenPhoneTaskStart").start();
    }

    private void stopTask() {
        cancelPendingVolumeChord();
        String taskId = mActiveTaskId;
        if ((taskId == null || taskId.isEmpty()) && mRealtimeVoiceTaskId != null) {
            taskId = mRealtimeVoiceTaskId;
        }
        Log.i(TAG, "stop task requested taskId=" + taskId
                + " realtimeTaskId=" + mRealtimeVoiceTaskId
                + " control=" + isControlSurface());
        try {
            if (mAgentManager != null && taskId != null) {
                mAgentManager.stopTask(taskId, "{\"reason\":\"user_stopped_from_assistant\"}");
                Log.i(TAG, "framework task stopped taskId=" + taskId);
            }
        } catch (RuntimeException ignored) {
            Log.w(TAG, "framework task stop failed taskId=" + taskId);
        }
        cancelAgentRun();
        cancelChatRun();
        mVoiceRunGeneration++;
        mListening = false;
        mIslandVoiceLaunch = false;
        mVoiceHoldToRecord = false;
        mVoiceCaptureFinishRequested = false;
        mRealtimeVoiceErrorShown = false;
        clearVoicePipelineProtection();
        OpenAiSpeechTranscriber speechTranscriber = mRunningSpeechTranscriber;
        if (speechTranscriber != null) {
            speechTranscriber.cancel();
            mRunningSpeechTranscriber = null;
        }
        OpenAiRealtimeVoiceSession realtimeVoiceSession = mRunningRealtimeVoiceSession;
        if (realtimeVoiceSession != null) {
            try {
                realtimeVoiceSession.cancel();
            } catch (RuntimeException e) {
                Log.w(TAG, "live realtime cancel failed: " + e.getClass().getSimpleName());
            }
            mRunningRealtimeVoiceSession = null;
        }
        GeminiLiveVoiceSession geminiLiveVoiceSession = mRunningGeminiLiveVoiceSession;
        if (geminiLiveVoiceSession != null) {
            try {
                geminiLiveVoiceSession.cancel();
            } catch (RuntimeException e) {
                Log.w(TAG, "gemini live cancel failed: " + e.getClass().getSimpleName());
            }
            mRunningGeminiLiveVoiceSession = null;
        }
        mActiveTaskId = null;
        mActiveTaskGoal = null;
        mRealtimeVoiceTaskId = null;
        mAgentThread = null;
        mChatThread = null;
        mRunningModelAdapter = null;
        mRunningChatAdapter = null;
        mPendingActionId = null;
        mPendingOneShotMessage = null;
        clearPendingToolAction();
        hidePendingConfirmation();
        PointerOverlayController.publishIdleState();
        OpenPhoneNotificationController.showReady(this);
        if (sActiveControlRunner == this) {
            sActiveControlRunner = null;
        }
        setTaskText("Task stopped");
        recordContextAgentEvent("assistant.agent.task_stopped", "Agent task stopped",
                "The active agent task was stopped by the user.", taskId, "");
        updateIsland("Stopped");
        updateComposerActionButton();
        refreshAudit();
    }

    private void cancelAgentRun() {
        mAgentRunCancelled = true;
        mAgentRunGeneration.incrementAndGet();
        ModelAdapter adapter = mRunningModelAdapter;
        if (adapter != null) {
            adapter.cancel();
        }
        Thread thread = mAgentThread;
        if (thread != null) {
            thread.interrupt();
        }
    }

    private void readScreenContext() {
        if (mAgentManager == null || mActiveTaskId == null) {
            setContextText("Start a task first");
            return;
        }
        setContextText(prettyForDisplay(mAgentManager.getScreen(mActiveTaskId,
                "{\"include_screenshot\":false,\"include_activity\":true}")));
        refreshAudit();
    }

    private void readScreenshotContext() {
        if (mAgentManager == null || mActiveTaskId == null) {
            setContextText("Start a task first");
            return;
        }
        setContextText(prettyForDisplay(mAgentManager.getScreen(mActiveTaskId,
                "{\"include_screenshot\":true,\"include_activity\":true,"
                        + "\"max_dimension\":512,\"quality\":65}")));
        refreshAudit();
    }

    private void executeBack() {
        if (mAgentManager == null || mActiveTaskId == null) {
            setTaskText("Start a task first");
            return;
        }
        String result = mAgentManager.executeAction(mActiveTaskId, "{\"type\":\"back\"}");
        setTaskText(prettyForDisplay(result));
        refreshAudit();
    }

    private void requestAction() {
        if (mAgentManager == null || mActiveTaskId == null) {
            setTaskText("Start a task first");
            return;
        }
        String result = mAgentManager.executeAction(mActiveTaskId,
                currentActionJson());
        mPendingActionId = parseString(result, "pending_action_id");
        if (mPendingActionId != null && !mPendingActionId.isEmpty()) {
            showPendingConfirmation(confirmationBodyFromActionResult(result));
        }
        setTaskText(prettyForDisplay(result));
        movePointerFromAction();
        refreshAudit();
    }

    private void runAgent() {
        runAgent(currentGoalText());
    }

    private void runAgent(final String goal) {
        if (mAgentManager == null || mActiveTaskId == null) {
            setTaskText("Start a task first");
            return;
        }
        reloadAutonomyMode();
        cancelAgentRun();
        mAgentRunCancelled = false;
        final int runGeneration = mAgentRunGeneration.incrementAndGet();
        final String taskId = mActiveTaskId;
        final ModelEndpointConfig endpointConfig = modelEndpointConfig();
        setTaskText("Working on: " + goal);
        updateIsland("Agent is working");
        FrameworkToolExecutor toolExecutor = new FrameworkToolExecutor(this, mAgentManager);
        ModelAdapter adapter = selectedModelAdapter(endpointConfig);
        mRunningModelAdapter = adapter;
        setTaskText("Working on: " + goal + "\n\n" + modelRunDisclosure(adapter));
        TrajectoryRecorder trajectory = TrajectoryRecorder.start(this, taskId, goal,
                adapter.providerDisplayName(), adapter.modelName(), adapter.usesCloud(),
                adapter.privacyDisclosure());
        Thread agentThread = new Thread(new Runnable() {
            @Override
            public void run() {
                String result = adapter.runTask(taskId, goal, new ModelAdapter.ToolExecutor() {
                    @Override
                    public String callTool(String toolName, String argumentsJson) {
                        if (isCancelled()) {
                            return "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
                        }
                        try {
                            trajectory.recordToolCall(toolName, argumentsJson);
                            JSONObject toolArguments = new JSONObject(argumentsJson);
                            String yoloBypass = yoloConfirmationBypass(taskId, toolExecutor,
                                    toolName, toolArguments);
                            if (yoloBypass != null) {
                                trajectory.recordToolResult(toolName, yoloBypass);
                                return yoloBypass;
                            }
                            String dryRunPreview = dryRunPreview(toolName, toolArguments);
                            if (dryRunPreview != null) {
                                trajectory.recordToolResult(toolName, dryRunPreview);
                                return dryRunPreview;
                            }
                            String grantDenied = preflightDenial(toolName,
                                    toolArguments);
                            if (grantDenied != null) {
                                trajectory.recordToolResult(toolName, grantDenied);
                                return grantDenied;
                            }
                            movePointerFromTool(toolName, toolArguments);
                            if (isCancelled()) {
                                String cancelled = "{\"status\":\"cancelled\","
                                        + "\"reason\":\"user_stopped\"}";
                                trajectory.recordToolResult(toolName, cancelled);
                                return cancelled;
                            }
                            String toolResult = toolExecutor.execute(taskId, toolName,
                                    toolArguments);
                            trajectory.recordToolResult(toolName, toolResult);
                            return toolResult;
                        } catch (JSONException e) {
                            String error = "{\"status\":\"error\",\"reason\":\"bad_tool_json\"}";
                            trajectory.recordToolResult(toolName, error);
                            return error;
                        }
                    }

                    @Override
                    public boolean isCancelled() {
                        return mAgentRunCancelled
                                || runGeneration != mAgentRunGeneration.get()
                                || Thread.currentThread().isInterrupted();
                    }
                });
                trajectory.recordAgentResult(result);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (runGeneration != mAgentRunGeneration.get()) {
                            return;
                        }
                        mAgentThread = null;
                        mRunningModelAdapter = null;
                        updateComposerActionButton();
                        if (mAgentRunCancelled || isCancelledResult(result)) {
                            mPointerOverlayController.showMicButton();
                            setTaskText("Task stopped"
                                    + "\n\nTrajectory: " + trajectory.sessionPath());
                            recordContextAgentEvent("assistant.agent.task_cancelled",
                                    "Agent task cancelled", agentResultForDisplay(result),
                                    taskId, result);
                            updateIsland("Stopped");
                            refreshAudit();
                            return;
                        }
                        setTaskText(agentResultForDisplay(result)
                                + "\n\nTrajectory: " + trajectory.sessionPath());
                        showConfirmationIfNeeded(result);
                        boolean finished = result.contains("\"status\":\"task.finished\"")
                                || result.contains("\"status\": \"task.finished\"");
                        String displayReply = finished
                                ? taskFinishedMessage(result) : agentResultForDisplay(result);
                        appendConversation("OpenPhone", displayReply);
                        recordContextAgentEvent(finished
                                        ? "assistant.agent.task_finished"
                                        : "assistant.agent.task_needs_review",
                                finished ? "Agent task finished" : "Agent task needs review",
                                displayReply,
                                taskId, result);
                        updateIsland(finished
                                ? "Done" : "Needs review");
                        if (finished && displayReply != null
                                && !displayReply.trim().isEmpty()
                                && mPointerOverlayController != null) {
                            mPointerOverlayController.showReply(displayReply);
                        }
                        refreshAudit();
                    }
                });
            }
        }, "OpenPhoneModelRunner");
        mAgentThread = agentThread;
        updateComposerActionButton();
        agentThread.start();
    }

    private void confirmPending(boolean approved) {
        if (mAgentManager == null) {
            setTaskText("Agent service is unavailable.");
            return;
        }
        final String pendingActionId = mPendingActionId;
        final String pendingToolName = mPendingToolName;
        final JSONObject pendingToolArguments = copyJsonObject(mPendingToolArguments);
        final String pendingOneShotMessage = mPendingOneShotMessage;
        if (pendingActionId == null && pendingToolName == null) {
            setTaskText("There is no pending system action to approve. "
                    + "If the agent asked for review, check the request and run the task again.");
            return;
        }

        mPendingActionId = null;
        mPendingOneShotMessage = null;
        clearPendingToolAction();
        hidePendingConfirmation();
        setTaskText(approved ? "Approved. Continuing..." : "Denied.");
        updateIsland(approved ? "Continuing" : "Denied");

        new Thread(new Runnable() {
            @Override
            public void run() {
                String result;
                if (pendingActionId != null) {
                    result = mAgentManager.confirmAction(pendingActionId, approved);
                } else if (approved) {
                    result = executeApprovedPendingTool(pendingToolName, pendingToolArguments);
                } else {
                    result = "{\"status\":\"action.denied\","
                            + "\"reason\":\"user_denied_confirmation\"}";
                }
                final String finalResult = result;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        refreshAudit();
                        if (pendingOneShotMessage != null) {
                            finishOneShotConfirmation(approved, pendingOneShotMessage,
                                    pendingToolName, finalResult);
                            return;
                        }
                        setTaskText(prettyForDisplay(finalResult));
                        if (approved && mActiveTaskId != null
                                && !isActionResultFailure(finalResult)) {
                            String resumeGoal = mActiveTaskGoal == null
                                    || mActiveTaskGoal.isEmpty()
                                    ? currentGoalText() : mActiveTaskGoal;
                            runAgent("Continue this task: " + resumeGoal
                                    + "\nThe user just approved the previously blocked "
                                    + "action and its result is: " + finalResult
                                    + "\nDo not ask for that approval again; use the "
                                    + "result and finish the task.");
                        } else {
                            updateIsland(approved ? "Action failed" : "Denied");
                        }
                    }
                });
            }
        }, "OpenPhoneApprovalExecutor").start();
    }

    private void showConfirmationIfNeeded(String agentResultJson) {
        try {
            JSONObject agentResult = new JSONObject(agentResultJson);
            String status = agentResult.optString("status", "");
            if (!"confirmation_required".equals(status)
                    && !"action_denied".equals(status)
                    && !"agent.blocked".equals(status)) {
                hidePendingConfirmation();
                return;
            }
            JSONObject confirmation = findLastConfirmation(agentResult);
            String pendingActionId = findStringRecursive(agentResult, "pending_action_id");
            if (pendingActionId != null && !pendingActionId.isEmpty()
                    && !"null".equals(pendingActionId)) {
                mPendingActionId = pendingActionId;
            }
            capturePendingToolAction(confirmation);
            showPendingConfirmation(confirmationBodyFromAgentResult(status, confirmation));
        } catch (JSONException e) {
            hidePendingConfirmation();
        }
    }

    private void showRealtimeConfirmationIfNeeded(String toolName, String toolResultJson) {
        try {
            JSONObject result = new JSONObject(toolResultJson);
            String status = result.optString("status", result.optString("state", ""));
            if (!"confirmation_requested".equals(status)
                    && !"confirmation_required".equals(status)
                    && !"action.confirmation_required".equals(status)
                    && !"action_denied".equals(status)) {
                return;
            }
            String pendingActionId = findStringRecursive(result, "pending_action_id");
            if (pendingActionId != null && !pendingActionId.isEmpty()
                    && !"null".equals(pendingActionId)) {
                mPendingActionId = pendingActionId;
            }
            capturePendingToolAction(result);
            String body = confirmationBodyFromAgentResult(status, result);
            showPendingConfirmation(body);
            setTaskText(body);
            updateComposerActionButton();
            refreshAudit();
            Log.i(TAG, "live realtime confirmation shown tool="
                    + (toolName == null ? "" : toolName)
                    + " status=" + status);
        } catch (JSONException e) {
            Log.w(TAG, "bad realtime confirmation result", e);
        }
    }

    private String executeApprovedPendingTool(String toolName, JSONObject arguments) {
        if (mActiveTaskId == null || toolName == null) {
            return "{\"status\":\"error\",\"reason\":\"no_pending_tool_action\"}";
        }
        FrameworkToolExecutor toolExecutor = new FrameworkToolExecutor(this, mAgentManager);
        JSONObject safeArguments = arguments == null ? new JSONObject() : arguments;
        try {
            movePointerFromTool(toolName, safeArguments);
            return toolExecutor.execute(mActiveTaskId, toolName, safeArguments);
        } catch (RuntimeException e) {
            return "{\"status\":\"error\",\"reason\":\"approved_tool_failed\"}";
        }
    }

    private static JSONObject copyJsonObject(JSONObject object) {
        if (object == null) {
            return null;
        }
        try {
            return new JSONObject(object.toString());
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private void capturePendingToolAction(JSONObject confirmation) {
        JSONObject action = confirmation.optJSONObject("action");
        if (action == null) {
            action = confirmation.optJSONObject("action_json");
        }
        if (action == null) {
            action = parseObjectOrEmpty(confirmation.optString("input", ""));
        }
        String toolName = action.optString("tool", action.optString("type", ""));
        JSONObject arguments = action.optJSONObject("arguments");
        if (arguments == null) {
            arguments = parseObjectOrEmpty(action.toString());
            arguments.remove("tool");
            arguments.remove("type");
        }
        if (toolName == null || toolName.isEmpty()) {
            clearPendingToolAction();
            return;
        }
        mPendingToolName = toolName;
        mPendingToolArguments = arguments;
    }

    private void clearPendingToolAction() {
        mPendingToolName = null;
        mPendingToolArguments = null;
    }

    private void showPendingConfirmation(String body) {
        String confirmationText = body == null || body.isEmpty()
                ? "Review the requested action before continuing." : body;
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.setPendingConfirmation(
                    mPendingActionId == null ? "" : mPendingActionId,
                    mPendingToolName == null ? "" : mPendingToolName,
                    confirmationText);
        }
        // Pass the actual confirmation text so the inline Approve/Deny island
        // shows what's being approved instead of generic "Approval needed".
        if (mPointerOverlayController != null) {
            mPointerOverlayController.setIslandState("needs_review", confirmationText);
        }
        updateIsland("Approval needed");
    }

    private void hidePendingConfirmation() {
        if (mComposeStateCallbacks != null) {
            mComposeStateCallbacks.clearPendingConfirmation();
        }
    }

    private void refreshAudit() {
        final OpenPhoneAgentManager agentManager = mAgentManager;
        if (agentManager == null) {
            return;
        }
        final int refreshGeneration = ++mAuditRefreshGeneration;
        new Thread(new Runnable() {
            @Override
            public void run() {
                String auditText;
                try {
                    auditText = prettyForDisplay(agentManager.getAuditLog(25));
                } catch (RuntimeException e) {
                    auditText = "Audit unavailable: " + e.getClass().getSimpleName();
                }
                final String finalAuditText = auditText;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (refreshGeneration == mAuditRefreshGeneration) {
                            setAuditText(finalAuditText);
                        }
                    }
                });
            }
        }, "OpenPhoneAuditRefresh").start();
    }

    private void exportLatestTrajectory() {
        try {
            setTaskText(TrajectoryRecorder.exportLatestToDownloads(this));
            updateIsland("Trace exported");
        } catch (IOException e) {
            setTaskText("Could not export the latest trace.\n\n" + e.getMessage());
            updateIsland("Export failed");
        }
    }

    private void exportAuditEvidence() {
        try {
            setTaskText(AuditEvidenceExporter.exportToDownloads(this, mAgentManager, 200));
            updateIsland("Audit exported");
        } catch (IOException e) {
            setTaskText("Could not export audit evidence.\n\n" + e.getMessage());
            updateIsland("Export failed");
        }
    }

    private void checkOtaFeed() {
        final String feedUrl = mComposeOtaFeedUrl.trim();
        if (feedUrl.isEmpty()) {
            setOtaStatus("Paste an OTA feed URL first.");
            return;
        }
        setOtaStatus("Checking OTA feed for " + Build.DEVICE + "...");
        new Thread(new Runnable() {
            @Override
            public void run() {
                String status;
                OtaUpdateClient.Update update = null;
                try {
                    update = OtaUpdateClient.fetchLatest(feedUrl, Build.DEVICE);
                    status = "Update available.\n\n" + update.summary();
                } catch (IOException | JSONException e) {
                    status = "OTA check failed.\n\n" + e.getMessage();
                }
                final String finalStatus = status;
                final OtaUpdateClient.Update finalUpdate = update;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        mLatestOtaUpdate = finalUpdate;
                        setOtaStatus(finalStatus);
                    }
                });
            }
        }, "OpenPhoneOtaCheck").start();
    }

    private void downloadLatestOta() {
        final OtaUpdateClient.Update update = mLatestOtaUpdate;
        if (update == null) {
            setOtaStatus("Check an OTA feed before downloading.");
            return;
        }
        setOtaStatus("Starting OTA download...");
        new Thread(new Runnable() {
            @Override
            public void run() {
                String status;
                try {
                    status = OtaUpdateClient.downloadToDownloads(AssistantActivityBackend.this, update,
                            new OtaUpdateClient.ProgressCallback() {
                                @Override
                                public void onProgress(final String progress) {
                                    runOnUiThread(new Runnable() {
                                        @Override
                                        public void run() {
                                            setOtaStatus(progress);
                                        }
                                    });
                                }
                            });
                } catch (IOException e) {
                    status = "OTA download failed.\n\n" + e.getMessage();
                }
                final String finalStatus = status;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        setOtaStatus(finalStatus);
                    }
                });
            }
        }, "OpenPhoneOtaDownload").start();
    }

    private void setOtaStatus(String status) {
        setOtaStatusText(status == null ? "" : status);
        setTaskText(status == null ? "" : status);
    }

    private String preflightDenial(String toolName, JSONObject arguments) {
        String missingCapability = "yolo".equals(mAutonomyMode)
                ? null : missingTaskGrant(toolName, arguments);
        if (missingCapability == null) {
            String appPolicy = appPolicyDenial(toolName, arguments);
            if (appPolicy != null) {
                return appPolicy;
            }
            return actionPolicyDenial(toolName, arguments);
        }
        try {
            return new JSONObject()
                    .put("status", "confirmation_required")
                    .put("reason", "task_grant_required")
                    .put("capability", missingCapability)
                    .put("summary", "This task does not currently allow "
                            + capabilityLabel(missingCapability) + ".")
                    .put("risk", riskForCapability(missingCapability, toolName))
                    .put("action_json", new JSONObject()
                            .put("tool", toolName)
                            .put("arguments", arguments))
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"confirmation_required\","
                    + "\"reason\":\"task_grant_required\"}";
        }
    }

    private String yoloConfirmationBypass(String taskId, FrameworkToolExecutor toolExecutor,
            String toolName, JSONObject arguments) {
        if (!"yolo".equals(mAutonomyMode) || !"ask_user_confirmation".equals(toolName)) {
            return null;
        }
        JSONObject action = confirmationActionFromArguments(arguments);
        String nestedTool = action.optString("tool", action.optString("type", "")).trim();
        if (nestedTool.isEmpty() || "ask_user_confirmation".equals(nestedTool)) {
            try {
                return new JSONObject()
                        .put("status", "confirmation_skipped")
                        .put("reason", "full_yolo")
                        .put("summary", "Full YOLO is enabled; continue with the next "
                                + "concrete tool call without asking for approval.")
                        .toString();
            } catch (JSONException e) {
                return "{\"status\":\"confirmation_skipped\",\"reason\":\"full_yolo\"}";
            }
        }
        JSONObject nestedArguments = action.optJSONObject("arguments");
        if (nestedArguments == null) {
            nestedArguments = new JSONObject();
        }
        String dryRunPreview = dryRunPreview(nestedTool, nestedArguments);
        if (dryRunPreview != null) {
            return dryRunPreview;
        }
        String grantDenied = preflightDenial(nestedTool, nestedArguments);
        if (grantDenied != null) {
            return grantDenied;
        }
        try {
            movePointerFromTool(nestedTool, nestedArguments);
            if (toolExecutor == null || taskId == null || taskId.isEmpty()) {
                return "{\"status\":\"error\",\"reason\":\"missing_task_for_yolo_bypass\"}";
            }
            return toolExecutor.execute(taskId, nestedTool, nestedArguments);
        } catch (RuntimeException e) {
            return "{\"status\":\"error\",\"reason\":\"yolo_confirmation_bypass_failed\"}";
        }
    }

    private static JSONObject confirmationActionFromArguments(JSONObject arguments) {
        if (arguments == null) {
            return new JSONObject();
        }
        JSONObject action = arguments.optJSONObject("action_json");
        if (action != null) {
            return action;
        }
        action = arguments.optJSONObject("action");
        if (action != null) {
            return action;
        }
        return parseObjectOrEmpty(arguments.optString("input", ""));
    }

    private String actionPolicyDenial(String toolName, JSONObject arguments) {
        if (mActionRegistry == null || !mActionRegistry.isLoaded()) {
            return null;
        }
        ActionRegistry.ActionMetadata action = mActionRegistry.forTool(toolName);
        if (action == null || "control".equals(action.kind)) {
            return null;
        }
        if ("task_grant".equals(action.authorizationPolicy)) {
            return null;
        }
        String capability = capabilityForTool(toolName, arguments);
        if (yoloAllows(action, capability)) {
            return null;
        }
        try {
            return new JSONObject()
                    .put("status", "confirmation_required")
                    .put("reason", "action_policy_" + action.authorizationPolicy)
                    .put("action_name", action.name)
                    .put("capability", capability == null ? "" : capability)
                    .put("summary", actionConfirmationSummary(action, toolName, arguments))
                    .put("risk", riskLabel(action.riskClass))
                    .put("autonomy_mode", mAutonomyMode)
                    .put("action_json", new JSONObject()
                            .put("tool", toolName)
                            .put("arguments", arguments == null ? new JSONObject() : arguments))
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"confirmation_required\","
                    + "\"reason\":\"action_policy_required\"}";
        }
    }

    private String dryRunPreview(String toolName, JSONObject arguments) {
        if (!"dry_run".equals(mAutonomyMode) || !isDryRunPreviewTool(toolName)) {
            return null;
        }
        String capability = capabilityForTool(toolName, arguments);
        ActionRegistry.ActionMetadata action = mActionRegistry == null
                ? null : mActionRegistry.forTool(toolName);
        try {
            JSONObject result = new JSONObject()
                    .put("status", "dry_run.preview")
                    .put("reason", "dry_run_mode")
                    .put("tool", toolName == null ? "" : toolName)
                    .put("capability", capability == null ? "" : capability)
                    .put("risk", action == null ? riskForCapability(
                            capability == null ? "" : capability, toolName)
                            : riskLabel(action.riskClass))
                    .put("summary", "Dry run previewed this action without executing it.")
                    .put("arguments", arguments == null ? new JSONObject() : arguments);
            if (action != null) {
                result.put("action_name", action.name)
                        .put("authorization_policy", action.authorizationPolicy);
            }
            return result.toString();
        } catch (JSONException e) {
            return "{\"status\":\"dry_run.preview\",\"reason\":\"dry_run_mode\"}";
        }
    }

    private boolean isDryRunPreviewTool(String toolName) {
        if (toolName == null || toolName.isEmpty()) {
            return false;
        }
        if ("finish_task".equals(toolName) || "fail_task".equals(toolName)
                || "get_screen".equals(toolName) || "watch_screen".equals(toolName)
                || "context_search".equals(toolName)
                || "notifications_list".equals(toolName)
                || "notifications_search".equals(toolName)
                || "notifications_summary".equals(toolName)
                || "calendar_search".equals(toolName)
                || "calendar_check_availability".equals(toolName)
                || "contacts_search".equals(toolName)
                || "messages_search".equals(toolName)
                || "messages_summary".equals(toolName)
                || "calls_search".equals(toolName)
                || "phone_context".equals(toolName)
                || "memory_search".equals(toolName)
                || "commitment_search".equals(toolName)
                || "watcher_list".equals(toolName)
                || "browser_fetch_page".equals(toolName)
                || "wait".equals(toolName)
                || "ask_user_confirmation".equals(toolName)) {
            return false;
        }
        ActionRegistry.ActionMetadata action = mActionRegistry == null
                ? null : mActionRegistry.forTool(toolName);
        if (action != null) {
            return "action".equals(action.kind) || "control".equals(action.kind);
        }
        return "open_app".equals(toolName)
                || "open_url".equals(toolName)
                || "tap".equals(toolName)
                || "tap_element".equals(toolName)
                || "long_press".equals(toolName)
                || "long_press_element".equals(toolName)
                || "swipe".equals(toolName)
                || "type_text".equals(toolName)
                || "press_key".equals(toolName)
                || "set_clipboard".equals(toolName)
                || "paste".equals(toolName)
                || "share_text".equals(toolName)
                || "notifications_open".equals(toolName)
                || "calendar_create_event".equals(toolName)
                || "message_calendar_event_create".equals(toolName)
                || "calendar_update_event".equals(toolName)
                || "calendar_delete_event".equals(toolName)
                || "messages_draft".equals(toolName)
                || "messages_send".equals(toolName)
                || "calls_place".equals(toolName)
                || "memory_save".equals(toolName)
                || "commitment_create".equals(toolName)
                || "notification_commitment_create".equals(toolName)
                || "message_commitment_create".equals(toolName)
                || "commitment_update_status".equals(toolName)
                || "watcher_create".equals(toolName)
                || "watcher_stop".equals(toolName);
    }

    private boolean yoloAllows(ActionRegistry.ActionMetadata action, String capability) {
        if (!"yolo".equals(mAutonomyMode)) {
            return false;
        }
        if (!"confirm".equals(action.authorizationPolicy)
                && !"explicit_confirm".equals(action.authorizationPolicy)) {
            return false;
        }
        return capability != null && !capability.trim().isEmpty();
    }

    private static String actionConfirmationSummary(ActionRegistry.ActionMetadata action,
            String toolName, JSONObject arguments) {
        String actionName = action.name == null || action.name.isEmpty()
                ? toolName : action.name;
        return "Approve " + actionName + ".";
    }

    private static String riskLabel(String riskClass) {
        if ("high".equals(riskClass)) {
            return "High";
        }
        if ("medium".equals(riskClass)) {
            return "Medium";
        }
        if ("low".equals(riskClass)) {
            return "Low";
        }
        return "Review";
    }

    private String appPolicyDenial(String toolName, JSONObject arguments) {
        String capability = capabilityForTool(toolName, arguments);
        if (capability == null) {
            return null;
        }
        String foregroundPackage = currentForegroundPackage();
        AppCapabilityPolicy.Decision decision =
                AppCapabilityPolicy.evaluate(this, foregroundPackage, capability);
        if (!decision.requiresIntervention()) {
            return null;
        }
        if (appPolicyYoloAllows(decision, capability)) {
            return null;
        }
        try {
            String status = "deny".equals(decision.action)
                    ? "action_denied" : "confirmation_required";
            return new JSONObject()
                    .put("status", status)
                    .put("reason", "app_policy_" + decision.action)
                    .put("foreground_package", foregroundPackage)
                    .put("capability", capability)
                    .put("summary", "This app has a stricter OpenPhone policy for "
                            + capabilityLabel(capability) + ".")
                    .put("risk", "explicit_confirm".equals(decision.action)
                            || "deny".equals(decision.action) ? "High" : "Medium")
                    .put("policy_reason", decision.reason)
                    .put("action_json", new JSONObject()
                            .put("tool", toolName)
                            .put("arguments", arguments))
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"confirmation_required\","
                    + "\"reason\":\"app_policy_required\"}";
        }
    }

    private boolean appPolicyYoloAllows(AppCapabilityPolicy.Decision decision, String capability) {
        if (!"yolo".equals(mAutonomyMode) || decision == null || capability == null
                || capability.trim().isEmpty()) {
            return false;
        }
        return "confirm".equals(decision.action)
                || "explicit_confirm".equals(decision.action);
    }

    private String missingTaskGrant(String toolName, JSONObject arguments) {
        if (("tap".equals(toolName) || "tap_element".equals(toolName)
                || "long_press".equals(toolName) || "long_press_element".equals(toolName)
                || "swipe".equals(toolName) || "type_text".equals(toolName)
                || "press_key".equals(toolName))
                && !inputGrantEnabled()) {
            return "input.perform";
        }
        if (("get_screen".equals(toolName) || "watch_screen".equals(toolName))
                && arguments.optBoolean("include_screenshot", false)
                && !screenCaptureGrantEnabled()) {
            return "screen.capture";
        }
        if (("set_clipboard".equals(toolName) || "paste".equals(toolName))
                && !clipboardGrantEnabled()) {
            return "clipboard.write";
        }
        if ("share_text".equals(toolName) && !shareGrantEnabled()) {
            return "share.content";
        }
        if (("open_url".equals(toolName) || "browser_search".equals(toolName))
                && !networkGrantEnabled()) {
            return "network.use";
        }
        return null;
    }

    private static String capabilityForTool(String toolName, JSONObject arguments) {
        if ("tap".equals(toolName) || "tap_element".equals(toolName)
                || "long_press".equals(toolName) || "long_press_element".equals(toolName)
                || "swipe".equals(toolName) || "type_text".equals(toolName)
                || "press_key".equals(toolName)) {
            return "input.perform";
        }
        if (("get_screen".equals(toolName) || "watch_screen".equals(toolName))
                && arguments.optBoolean("include_screenshot", false)) {
            return "screen.capture";
        }
        if ("get_screen".equals(toolName) || "watch_screen".equals(toolName)) {
            return "screen.read.visible";
        }
        if ("context_search".equals(toolName) || "wait".equals(toolName)
                || "ask_user_confirmation".equals(toolName)
                || "finish_task".equals(toolName) || "fail_task".equals(toolName)) {
            return "tasks.observe";
        }
        if ("notifications_list".equals(toolName)
                || "notifications_search".equals(toolName)
                || "notifications_summary".equals(toolName)) {
            return "notifications.read";
        }
        if ("notifications_open".equals(toolName)) {
            return "notifications.act";
        }
        if ("calendar_search".equals(toolName)
                || "calendar_check_availability".equals(toolName)) {
            return "calendar.read";
        }
        if ("calendar_create_event".equals(toolName)
                || "message_calendar_event_create".equals(toolName)
                || "calendar_update_event".equals(toolName)) {
            return "calendar.write";
        }
        if ("calendar_delete_event".equals(toolName)) {
            return "calendar.delete";
        }
        if ("contacts_search".equals(toolName)) {
            return "contacts.read";
        }
        if ("messages_search".equals(toolName) || "messages_summary".equals(toolName)) {
            return "messages.read";
        }
        if ("messages_draft".equals(toolName)) {
            return "messages.draft";
        }
        if ("messages_send".equals(toolName)) {
            return "messages.send";
        }
        if ("calls_search".equals(toolName) || "phone_context".equals(toolName)) {
            return "calls.read";
        }
        if ("calls_place".equals(toolName)) {
            return "calls.place";
        }
        if ("memory_search".equals(toolName)) {
            return "memory.read";
        }
        if ("memory_save".equals(toolName)) {
            return "memory.write";
        }
        if ("commitment_search".equals(toolName)) {
            return "commitments.read";
        }
        if ("commitment_create".equals(toolName)
                || "notification_commitment_create".equals(toolName)
                || "message_commitment_create".equals(toolName)
                || "commitment_update_status".equals(toolName)) {
            return "commitments.write";
        }
        if ("watcher_list".equals(toolName)) {
            return "watchers.read";
        }
        if ("watcher_create".equals(toolName) || "watcher_stop".equals(toolName)) {
            return "watchers.write";
        }
        if ("set_clipboard".equals(toolName)) {
            return "clipboard.write";
        }
        if ("paste".equals(toolName)) {
            return "clipboard.read";
        }
        if ("share_text".equals(toolName)) {
            return "share.content";
        }
        if ("open_url".equals(toolName) || "browser_search".equals(toolName)) {
            return "network.use";
        }
        if ("browser_fetch_page".equals(toolName)) {
            return "network.use";
        }
        if ("open_app".equals(toolName)) {
            return "apps.launch";
        }
        return null;
    }

    private static String currentForegroundPackage() {
        try {
            JSONObject snapshot = new JSONObject(OpenPhoneAccessibilityService.snapshotJson());
            String foregroundPackage = snapshot.optString("foreground_package", "");
            if (!foregroundPackage.isEmpty()) {
                return foregroundPackage;
            }
            JSONArray packages = snapshot.optJSONArray("root_packages");
            if (packages != null && packages.length() > 0) {
                return packages.optString(0, "");
            }
        } catch (JSONException ignored) {
        }
        return "";
    }

    private static String capabilityLabel(String capability) {
        if ("input.perform".equals(capability)) {
            return "tapping, typing, or navigation";
        }
        if ("screen.capture".equals(capability)) {
            return "screenshot capture";
        }
        if ("clipboard.write".equals(capability) || "clipboard.read".equals(capability)) {
            return "clipboard access";
        }
        if ("share.content".equals(capability)) {
            return "sharing content";
        }
        if ("network.use".equals(capability)) {
            return "opening web links";
        }
        return capability;
    }

    private void movePointerFromAction() {
        try {
            JSONObject action = new JSONObject(currentActionJson());
            movePointerForActionJson(action);
        } catch (JSONException ignored) {
        }
    }

    private void movePointerForActionJson(JSONObject action) {
        String type = action.optString("type", "");
        if ("tap".equals(type) || "long_press".equals(type)) {
            JSONObject target = action.optJSONObject("target");
            if (target != null) {
                mPointerOverlayController.pointerTap(
                        (float) target.optDouble("x", 0),
                        (float) target.optDouble("y", 0),
                        "long_press".equals(type));
            }
        } else if ("scroll".equals(type) || "swipe".equals(type)) {
            JSONObject target = action.optJSONObject("target");
            if (target == null) {
                target = action;
            }
            mPointerOverlayController.pointerSwipe(
                    (float) target.optDouble("start_x", 0),
                    (float) target.optDouble("start_y", 0),
                    (float) target.optDouble("end_x", 0),
                    (float) target.optDouble("end_y", 0));
        } else if ("type_text".equals(type) || "paste".equals(type)) {
            mPointerOverlayController.typingIndicator();
        }
    }

    private void movePointerFromTool(String toolName, JSONObject arguments) {
        if ("tap".equals(toolName) || "long_press".equals(toolName)) {
            final float x = (float) arguments.optDouble("x", 0);
            final float y = (float) arguments.optDouble("y", 0);
            final boolean longPress = "long_press".equals(toolName);
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    mPointerOverlayController.pointerTap(x, y, longPress);
                }
            });
            return;
        }
        if ("tap_element".equals(toolName) || "long_press_element".equals(toolName)) {
            final JSONObject center = elementCenterFromCurrentSnapshot(arguments.optString(
                    "element_id", ""));
            if (center != null) {
                final float x = (float) center.optDouble("x", 0);
                final float y = (float) center.optDouble("y", 0);
                final boolean longPress = "long_press_element".equals(toolName);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        mPointerOverlayController.pointerTap(x, y, longPress);
                    }
                });
            }
            return;
        }
        if ("swipe".equals(toolName)) {
            final float startX = (float) arguments.optDouble("start_x", 0);
            final float startY = (float) arguments.optDouble("start_y", 0);
            final float endX = (float) arguments.optDouble("end_x", 0);
            final float endY = (float) arguments.optDouble("end_y", 0);
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    mPointerOverlayController.pointerSwipe(startX, startY, endX, endY);
                }
            });
            return;
        }
        if ("type_text".equals(toolName) || "paste".equals(toolName)) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    mPointerOverlayController.typingIndicator();
                }
            });
        }
    }

    private static String parseString(String json, String key) {
        try {
            return new JSONObject(json).optString(key, null);
        } catch (JSONException e) {
            return null;
        }
    }

    private static String statusSummary(String json) {
        if (json == null || json.isEmpty()) {
            return "Service status unavailable";
        }
        try {
            JSONObject status = new JSONObject(json);
            String state = status.optString("state", "unknown");
            int pendingActions = status.optInt("pending_actions", 0);
            return "OpenPhone " + state + "  |  " + pendingActions + " pending";
        } catch (JSONException e) {
            return json;
        }
    }

    private static boolean isActionResultFailure(String json) {
        JSONObject result = parseObjectOrEmpty(json);
        String status = result.optString("status", result.optString("state", ""));
        return status.contains("error")
                || status.contains("failed")
                || status.contains("denied")
                || status.contains("blocked");
    }

    private static String confirmationBodyFromActionResult(String json) {
        try {
            JSONObject result = new JSONObject(json);
            String capability = result.optString("capability", "unknown");
            String input = result.optString("input", "");
            JSONObject action = parseObjectOrEmpty(input);
            String type = action.optString("type", "unknown");
            return "Risk: " + riskForCapability(capability, type) + "\n"
                    + "Capability: " + capability + "\n"
                    + "Requested action: " + actionSummary(action) + "\n\n"
                    + "Approve only if this matches your current task. Deny if it would "
                    + "send, post, buy, install, delete, share private data, or change "
                    + "security settings unexpectedly.";
        } catch (JSONException e) {
            return "Review the requested action before continuing.";
        }
    }

    private static String confirmationBodyFromAgentResult(String status,
            JSONObject confirmation) {
        String summary = confirmation.optString("summary",
                confirmation.optString("detail", "The agent needs your review."));
        String risk = confirmation.optString("risk", "");
        JSONObject action = confirmation.optJSONObject("action");
        if (action == null) {
            action = confirmation.optJSONObject("action_json");
        }
        if (action == null) {
            action = parseObjectOrEmpty(confirmation.optString("input", ""));
        }

        StringBuilder builder = new StringBuilder();
        builder.append("Risk: ").append(risk.isEmpty()
                ? riskForCapability(confirmation.optString("capability", ""), action.optString("type", ""))
                : risk).append('\n');
        builder.append("Request: ").append(summary).append('\n');
        if (action.length() > 0) {
            builder.append("Requested action: ").append(actionSummary(action)).append('\n');
        }
        builder.append('\n');
        if ("action_denied".equals(status)) {
            builder.append("OpenPhone stopped because policy denied the action.");
        } else {
            builder.append("OpenPhone stopped before this action. Approve only after "
                    + "checking that it is expected for the active task.");
        }
        return builder.toString();
    }

    private static JSONObject findLastConfirmation(JSONObject agentResult) {
        JSONObject found = new JSONObject();
        JSONArray steps = agentResult.optJSONArray("steps");
        if (steps == null) {
            return found;
        }
        for (int i = 0; i < steps.length(); i++) {
            JSONObject step = steps.optJSONObject(i);
            if (step == null) {
                continue;
            }
            JSONObject toolResult = objectFromValue(step.opt("tool_result"));
            String status = toolResult.optString("status", toolResult.optString("state", ""));
            if ("confirmation_requested".equals(status)
                    || "confirmation_required".equals(status)
                    || "action.confirmation_required".equals(status)) {
                found = toolResult;
            }
        }
        return found;
    }

    private static String findStringRecursive(Object value, String key) {
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            String direct = object.optString(key, "");
            if (!direct.isEmpty() && !"null".equals(direct)) {
                return direct;
            }
            JSONArray names = object.names();
            if (names == null) {
                return "";
            }
            for (int i = 0; i < names.length(); i++) {
                String nested = findStringRecursive(object.opt(names.optString(i)), key);
                if (nested != null && !nested.isEmpty()) {
                    return nested;
                }
            }
        } else if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            for (int i = 0; i < array.length(); i++) {
                String nested = findStringRecursive(array.opt(i), key);
                if (nested != null && !nested.isEmpty()) {
                    return nested;
                }
            }
        } else if (value instanceof String) {
            JSONObject object = parseObjectOrEmpty((String) value);
            if (object.length() > 0) {
                return findStringRecursive(object, key);
            }
        }
        return "";
    }

    private static JSONObject parseObjectOrEmpty(String json) {
        if (json == null || json.trim().isEmpty()) {
            return new JSONObject();
        }
        try {
            return new JSONObject(json);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static JSONObject objectFromValue(Object value) {
        if (value instanceof JSONObject) {
            return (JSONObject) value;
        }
        if (value instanceof String) {
            return parseObjectOrEmpty((String) value);
        }
        return new JSONObject();
    }

    private static String actionSummary(JSONObject action) {
        String type = action.optString("type", action.optString("tool", "unknown"));
        if ("open_app".equals(type)) {
            return "Open app " + action.optString("package",
                    action.optString("package_or_label", ""));
        }
        if ("share".equals(type) || "share_text".equals(type)) {
            return "Share text";
        }
        if ("copy".equals(type) || "set_clipboard".equals(type)) {
            return "Copy text to clipboard";
        }
        if ("paste".equals(type)) {
            return "Paste clipboard text";
        }
        if ("type_text".equals(type)) {
            return "Type text";
        }
        if ("tap".equals(type) || "tap_element".equals(type)
                || "long_press".equals(type) || "long_press_element".equals(type)
                || "scroll".equals(type) || "swipe".equals(type)) {
            return type.replace('_', ' ') + " on the screen";
        }
        return type.replace('_', ' ');
    }

    private static JSONObject elementCenterFromCurrentSnapshot(String elementId) {
        if (elementId == null || elementId.trim().isEmpty()) {
            return null;
        }
        try {
            JSONObject snapshot = new JSONObject(OpenPhoneAccessibilityService.snapshotJson());
            JSONArray elements = snapshot.optJSONArray("interactive_elements");
            if (elements == null) {
                return null;
            }
            for (int i = 0; i < elements.length(); i++) {
                JSONObject element = elements.optJSONObject(i);
                if (element == null || !elementId.equals(element.optString("id"))) {
                    continue;
                }
                JSONArray bounds = element.optJSONArray("bounds");
                if (bounds == null || bounds.length() < 4) {
                    return null;
                }
                double left = bounds.optDouble(0);
                double top = bounds.optDouble(1);
                double right = bounds.optDouble(2);
                double bottom = bounds.optDouble(3);
                if (right <= left || bottom <= top) {
                    return null;
                }
                return new JSONObject()
                        .put("x", (left + right) / 2.0)
                        .put("y", (top + bottom) / 2.0);
            }
        } catch (JSONException ignored) {
        }
        return null;
    }

    private static String riskForCapability(String capability, String actionType) {
        String combined = (capability + " " + actionType).toLowerCase();
        if (combined.contains("share") || combined.contains("payment")
                || combined.contains("purchase") || combined.contains("install")
                || combined.contains("delete") || combined.contains("security")
                || combined.contains("account") || combined.contains("message")
                || combined.contains("call")) {
            return "High";
        }
        if (combined.contains("clipboard") || combined.contains("paste")
                || combined.contains("type")) {
            return "Medium";
        }
        return "Review";
    }

    private static String prettyForDisplay(String json) {
        if (json == null || json.isEmpty()) {
            return "";
        }
        try {
            Object parsed = json.trim().startsWith("[") ? new JSONArray(json) : new JSONObject(json);
            redactForDisplay(parsed);
            if (parsed instanceof JSONArray) {
                return ((JSONArray) parsed).toString(2);
            }
            return ((JSONObject) parsed).toString(2);
        } catch (JSONException e) {
            return json;
        }
    }

    private static void redactForDisplay(Object value) throws JSONException {
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            JSONArray names = object.names();
            if (names == null) {
                return;
            }
            for (int i = 0; i < names.length(); i++) {
                String name = names.getString(i);
                Object child = object.opt(name);
                if (isSecretField(name)) {
                    object.put(name, "<redacted>");
                } else if ("data".equals(name) && isScreenshotObject(object) && child instanceof String) {
                    object.put(name, "<base64 chars=" + ((String) child).length() + ">");
                } else {
                    redactForDisplay(child);
                }
            }
        } else if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            for (int i = 0; i < array.length(); i++) {
                redactForDisplay(array.opt(i));
            }
        }
    }

    private static boolean isScreenshotObject(JSONObject object) {
        return object.has("mime_type") && "base64".equals(object.optString("encoding"));
    }

    private static boolean isSecretField(String name) {
        String lower = name.toLowerCase();
        return lower.contains("api_key") || lower.contains("authorization")
                || lower.contains("token") || lower.contains("secret");
    }

    private static String agentResultForDisplay(String json) {
        if (json == null || json.isEmpty()) {
            return "I stopped before returning a result.";
        }
        try {
            JSONObject result = new JSONObject(json);
            String status = result.optString("status", "");
            if ("task.finished".equals(status)) {
                String answer = result.optString("answer", "").trim();
                return answer.isEmpty() ? "Done." : "Done.\n\n" + answer;
            }
            if ("dry_run.preview".equals(status)) {
                return "Dry run previewed the next action without executing it.";
            }
            if ("confirmation_required".equals(status) || "action_denied".equals(status)) {
                String reason = result.optString("reason", "").replace('_', ' ').trim();
                return reason.isEmpty()
                        ? "I need your approval before continuing."
                        : "I need your approval before continuing.\n\n" + reason;
            }
            if ("realtime_error".equals(status)) {
                String message = result.optString("message", "").trim();
                return message.isEmpty()
                        ? "Realtime request failed."
                        : "Realtime request failed.\n\n" + message;
            }
            if ("provider_unavailable".equals(status) || "unavailable".equals(status)) {
                String reason = result.optString("reason", result.optString("message", ""))
                        .replace('_', ' ').trim();
                return reason.isEmpty()
                        ? "Model provider is not configured."
                        : "Model provider is not configured.\n\n" + reason;
            }
            if ("agent.blocked".equals(status) || "task.failed".equals(status)
                    || "screen_capture_failed".equals(status)
                    || "step_limit_reached".equals(status)
                    || "duration_limit_reached".equals(status)) {
                String reason = result.optString("reason", result.optString("model_text",
                        result.optString("message", ""))).replace('_', ' ').trim();
                return reason.isEmpty()
                        ? "The agent stopped before finishing. Status: " + status
                        : "The agent stopped before finishing.\n\n" + reason;
            }
            String reason = result.optString("reason", "").replace('_', ' ').trim();
            if (!reason.isEmpty()) {
                return "The agent stopped before finishing.\n\n" + reason;
            }
            if (!status.isEmpty()) {
                return "The agent stopped before finishing. Status: " + status;
            }
        } catch (JSONException ignored) {
        }
        return "The agent stopped before finishing.";
    }

    private static String taskFinishedMessage(String json) {
        if (json == null || json.isEmpty()) {
            return "Done.";
        }
        try {
            JSONObject result = new JSONObject(json);
            String answer = result.optString("answer", "").trim();
            return answer.isEmpty() ? "Done." : answer;
        } catch (JSONException ignored) {
        }
        return "Done.";
    }

    private static boolean isCancelledResult(String json) {
        if (json == null || json.isEmpty()) {
            return false;
        }
        try {
            return "cancelled".equals(new JSONObject(json).optString("status"));
        } catch (JSONException e) {
            return json.contains("\"status\":\"cancelled\"")
                    || json.contains("\"status\": \"cancelled\"");
        }
    }
}
