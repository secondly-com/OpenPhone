package org.openphone.assistant.model;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AutomaticGainControl;
import android.media.audiofx.NoiseSuppressor;
import android.os.SystemClock;
import android.util.Base64;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.actions.ToolCatalog;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.locks.ReentrantLock;

import javax.net.ssl.SSLSocketFactory;

public final class OpenAiRealtimeVoiceSession implements MultimodalSession {
    private static final String TAG = "OpenPhoneRealtimeVoice";

    public static final String MODEL = "gpt-realtime-2";

    private static final int OPENAI_SAMPLE_RATE = 24000;
    private static final String OPENAI_PROVIDER_LABEL = "OpenAI Live Realtime 2";
    private static final String OPENAI_STATUS_LABEL = "Live Realtime 2";
    private static final long CONNECT_TIMEOUT_MS = 20000;
    private static final long EVENT_TIMEOUT_MS = 2000;
    private static final long SELF_ECHO_GUARD_MS = 900;
    private static final long PLAYBACK_DRAIN_GRACE_MS = 350;
    private static final long MAX_PLAYBACK_DRAIN_MS = 6000;
    private static final long BARGE_IN_COOLDOWN_MS = 900;
    private static final long LOCAL_BARGE_IN_GUARD_MS = 240;
    private static final long SIMPLE_TURN_END_SILENCE_MS = 900;
    private static final long INTERRUPTED_FUNCTION_CALL_GRACE_MS = 2500;
    private static final long INTERRUPTED_AUDIO_DROP_GRACE_MS = 2500;
    private static final double LOCAL_BARGE_IN_RMS = 1700.0;
    private static final double SERVER_BARGE_IN_RMS = 900.0;
    private static final double SIMPLE_SPEECH_RMS = 900.0;
    private static final int AUTO_SCREEN_MAX_TEXT_CHARS = 8000;
    private static final int AUTO_SCREEN_MAX_ARRAY_ITEMS = 40;
    private static final long SCREEN_CACHE_INTERVAL_MS = 850;
    private static final long SCREEN_CACHE_MAX_AGE_MS = 2200;
    private static final long ACTION_RESPONSE_STALL_MS = 9000;
    private static final long STALL_CANCEL_GRACE_MS = 1800;
    private static final int ACTION_RESPONSE_STALL_MAX_RECOVERIES = 2;
    private static final String OPENAI_REALTIME_URL =
            "wss://api.openai.com/v1/realtime?model=" + MODEL;

    private final ModelEndpointConfig mEndpointConfig;
    private final String mProviderLabel;
    private final String mStatusLabel;
    private final String mModelName;
    private final String mRealtimeUrl;
    private final int mInputSampleRate;
    private final int mOutputSampleRate;
    private final boolean mSimpleRealtimeProtocol;
    private final ReentrantLock mToolExecutorLock = new ReentrantLock();
    private final Set<String> mCompletedCallIds = new HashSet<>();
    private final Set<String> mTruncatedAssistantItemIds = new HashSet<>();
    private final Set<String> mMutedResponseIds = new HashSet<>();
    private final Set<String> mMutedAssistantItemIds = new HashSet<>();
    private final OutcomeTracker mOutcomeTracker = new OutcomeTracker();
    private volatile boolean mCancelled;
    private volatile RealtimeWebSocket mSocket;
    private volatile AudioRecord mRecorder;
    private volatile AudioTrack mPlayer;
    private volatile Thread mAudioThread;
    private volatile Thread mScreenCacheThread;
    private volatile AcousticEchoCanceler mEchoCanceler;
    private volatile NoiseSuppressor mNoiseSuppressor;
    private volatile AutomaticGainControl mAutomaticGainControl;
    private volatile double mRecentMicRms;
    private String mPendingAssistantTranscript;
    private volatile boolean mAssistantAudioActive;
    private boolean mPendingToolResponseCreate;
    private boolean mPendingTerminalToolResponseCreate;
    private volatile long mPlaybackFramesWritten;
    private long mLastAudioWriteUptimeMillis;
    private volatile long mLastBargeInUptimeMillis;
    private volatile long mDropAssistantAudioUntilUptimeMillis;
    private volatile long mIgnorePartialFunctionCallsUntilUptimeMillis;
    private volatile boolean mSimpleSpeechStarted;
    private volatile boolean mSimpleInputFinalCommitted;
    private volatile long mSimpleLastSpeechUptimeMillis;
    private volatile String mCurrentResponseId;
    private volatile String mCurrentAssistantItemId;
    private volatile int mCurrentAssistantContentIndex;
    private volatile long mCurrentAssistantItemStartFrame;
    private volatile CachedScreenContext mCachedScreenContext;
    private String mLastMessageSendResult = "";
    private boolean mActionResponseOutstanding;
    private boolean mRetryActionAfterStallCancel;
    private long mActionResponseCreatedUptimeMillis;
    private long mLastActionResponseActivityUptimeMillis;
    private long mStallCancelRequestedUptimeMillis;
    private int mActionResponseStallRecoveries;
    private final String mContinuityContextJson;
    private final boolean mFullYolo;

    public OpenAiRealtimeVoiceSession(ModelEndpointConfig endpointConfig) {
        this(endpointConfig, "", false);
    }

    public OpenAiRealtimeVoiceSession(ModelEndpointConfig endpointConfig,
            String continuityContextJson) {
        this(endpointConfig, continuityContextJson, false);
    }

    public OpenAiRealtimeVoiceSession(ModelEndpointConfig endpointConfig,
            String continuityContextJson, boolean fullYolo) {
        this(endpointConfig, OPENAI_PROVIDER_LABEL, OPENAI_STATUS_LABEL,
                endpointConfig == null ? MODEL : endpointConfig.modelNameOrDefault(MODEL),
                endpointConfig == null
                        ? OPENAI_REALTIME_URL
                        : endpointConfig.realtimeWebSocketUrl(MODEL),
                OPENAI_SAMPLE_RATE, OPENAI_SAMPLE_RATE, false, continuityContextJson, fullYolo);
    }

    OpenAiRealtimeVoiceSession(ModelEndpointConfig endpointConfig, String providerLabel,
            String statusLabel, String modelName, String realtimeUrl, int inputSampleRate,
            int outputSampleRate, boolean simpleRealtimeProtocol, String continuityContextJson,
            boolean fullYolo) {
        mEndpointConfig = endpointConfig == null
                ? ModelEndpointConfig.directOpenAi("") : endpointConfig;
        mProviderLabel = emptyToDefault(providerLabel, OPENAI_PROVIDER_LABEL);
        mStatusLabel = emptyToDefault(statusLabel, OPENAI_STATUS_LABEL);
        mModelName = emptyToDefault(modelName, MODEL);
        mRealtimeUrl = realtimeUrl == null ? "" : realtimeUrl.trim();
        mInputSampleRate = inputSampleRate > 0 ? inputSampleRate : OPENAI_SAMPLE_RATE;
        mOutputSampleRate = outputSampleRate > 0 ? outputSampleRate : OPENAI_SAMPLE_RATE;
        mSimpleRealtimeProtocol = simpleRealtimeProtocol;
        mContinuityContextJson = continuityContextJson == null
                ? "" : continuityContextJson.trim();
        mFullYolo = fullYolo;
    }

    @Override
    public String providerDisplayName() {
        return mProviderLabel;
    }

    @Override
    public String modelName() {
        return mModelName;
    }

    @Override
    public String privacyDisclosure() {
        return mProviderLabel + " streams mic audio, screen context, tool calls, and tool "
                + "results to the configured realtime model endpoint while the session is "
                + "active. Model audio is played back on the phone.";
    }

    private static String emptyToDefault(String value, String fallback) {
        String clean = value == null ? "" : value.trim();
        return clean.isEmpty() ? fallback : clean;
    }

    @Override
    public void cancel() {
        mCancelled = true;
        AudioRecord recorder = mRecorder;
        if (recorder != null) {
            try {
                recorder.stop();
            } catch (IllegalStateException ignored) {
            }
            try {
                recorder.release();
            } catch (RuntimeException ignored) {
            }
        }
        releaseAudioEffects();
        AudioTrack player = mPlayer;
        if (player != null) {
            try {
                player.pause();
                player.flush();
                player.release();
            } catch (RuntimeException ignored) {
            }
        }
        RealtimeWebSocket socket = mSocket;
        if (socket != null) {
            socket.closeQuietly();
        }
        Thread audioThread = mAudioThread;
        if (audioThread != null) {
            audioThread.interrupt();
        }
        Thread screenCacheThread = mScreenCacheThread;
        if (screenCacheThread != null) {
            screenCacheThread.interrupt();
        }
    }

    @Override
    public void run(String taskId, ModelAdapter.ToolExecutor executor,
            MultimodalSession.Callback callback) {
        if (!mEndpointConfig.isConfigured()) {
            callback.onError(mEndpointConfig.missingCredentialReason());
            return;
        }
        if (mRealtimeUrl.isEmpty()) {
            callback.onError("missing_realtime_endpoint");
            return;
        }
        if (!ToolCatalog.get().isLoaded()) {
            callback.onError("Action registry is not installed; no model tools available.");
            return;
        }

        RealtimeWebSocket socket = null;
        try {
            Log.i(TAG, "connect provider=" + mProviderLabel + " model=" + mModelName);
            socket = RealtimeWebSocket.connect(mRealtimeUrl, mEndpointConfig.bearerToken());
            mSocket = socket;
            callback.onStatus("Starting " + mStatusLabel);
            socket.send(sessionUpdateEvent());
            if (mSimpleRealtimeProtocol) {
                sendSimpleInputCommit(socket, false);
            }
            startScreenCache(executor);
            startAudioInput(socket, callback);
            Log.i(TAG, "audio streaming started");
            callback.onStatus(mStatusLabel);
            while (!mCancelled && !executor.isCancelled()) {
                try {
                    JSONObject event = socket.readJson(EVENT_TIMEOUT_MS);
                    handleEvent(socket, taskId, executor, callback, event);
                } catch (SocketTimeoutException ignored) {
                    boolean recovered = maybeRecoverStalledActionResponse(socket, executor,
                            callback);
                    if (!recovered) {
                        callback.onStatus(mActionResponseOutstanding
                                || mRetryActionAfterStallCancel
                                        ? "Thinking" : mStatusLabel);
                    }
                }
            }
        } catch (IOException | JSONException | RuntimeException e) {
            if (!mCancelled && !executor.isCancelled()) {
                Log.w(TAG, "session failed", e);
                callback.onError(e.getMessage() == null
                        ? e.getClass().getSimpleName() : e.getMessage());
            }
        } finally {
            cancel();
            if (mSocket == socket) {
                mSocket = null;
            }
            callback.onStopped();
        }
    }

    private JSONObject sessionUpdateEvent() throws JSONException {
        if (mSimpleRealtimeProtocol) {
            return new JSONObject()
                    .put("type", "session.update")
                    .put("model", mModelName);
        }
        JSONObject turnDetection = new JSONObject()
                .put("type", "semantic_vad")
                .put("eagerness", "high")
                .put("create_response", false)
                .put("interrupt_response", true);
        JSONObject input = new JSONObject()
                .put("format", new JSONObject()
                        .put("type", "audio/pcm")
                        .put("rate", mInputSampleRate))
                .put("transcription", new JSONObject()
                        .put("model", OpenAiSpeechTranscriber.modelName()))
                .put("turn_detection", turnDetection);
        JSONObject output = new JSONObject()
                .put("format", new JSONObject()
                        .put("type", "audio/pcm")
                        .put("rate", mOutputSampleRate))
                .put("voice", "marin");
        JSONObject session = new JSONObject()
                .put("type", "realtime")
                .put("model", mModelName)
                .put("instructions", liveVoiceInstructions(mContinuityContextJson, mFullYolo))
                .put("output_modalities", new JSONArray().put("audio"))
                .put("audio", new JSONObject()
                        .put("input", input)
                        .put("output", output.put("speed", 1.18)))
                .put("reasoning", new JSONObject().put("effort", "low"))
                .put("tool_choice", "auto")
                .put("tools", realtimeToolDefinitionsForMode(mFullYolo));
        return new JSONObject()
                .put("type", "session.update")
                .put("session", session);
    }

    private static JSONArray realtimeToolDefinitionsForMode(boolean fullYolo)
            throws JSONException {
        JSONArray allTools = ToolCatalog.get().realtimeToolDefinitions();
        if (!fullYolo) {
            return allTools;
        }
        JSONArray tools = new JSONArray();
        for (int i = 0; i < allTools.length(); i++) {
            JSONObject tool = allTools.optJSONObject(i);
            if (tool == null || "ask_user_confirmation".equals(tool.optString("name", ""))) {
                continue;
            }
            tools.put(tool);
        }
        return tools;
    }

    private static String liveVoiceInstructions(String continuityContextJson, boolean fullYolo) {
        String continuity = continuityContextJson == null
                || continuityContextJson.trim().isEmpty()
                || "{}".equals(continuityContextJson.trim())
                        ? ""
                        : "Recent continuity context from prior OpenPhone sessions. Use this "
                                + "when the user refers to previous conversation, previous work, "
                                + "or asks what you were doing; otherwise do not overfit to it:\n"
                                + continuityContextJson.trim() + "\n\n";
        return "You are OpenPhone, a capable live OS voice agent running on the user's phone. "
                + "The user is speaking to you through a low-latency voice session. "
                + continuity
                + yoloModeInstruction(fullYolo)
                + initiativeInstruction()
                + "Act first. Use the phone tools whenever they help. A fresh screen snapshot "
                + "is automatically added after each user turn and after visible UI actions; "
                + "use it instead of first calling get_screen. Call get_screen only when that "
                + "automatic snapshot is missing, stale, or you need to verify a new screen. "
                + "Treat the screenshot as the rendered full-screen view and the accessibility "
                + "tree as supplemental metadata. "
                + "When the UI tree is sparse, custom-rendered, or missing labels, do not claim "
                + "you can only see a limited accessibility view; use the screenshot and raw "
                + "coordinates when needed. If the user asks you to control an app, keep observing and "
                + "acting until the requested result is done or the tools report a real "
                + "block. Do not ask clarification questions unless every concrete next "
                + "step is impossible without the answer. For vague requests, make a "
                + "reasonable choice and continue. Never claim you cannot use the phone "
                + "when a relevant tool exists. Do not ask for approval for ordinary app "
                + "navigation, typing fields, searching, choosing visible options, or "
                + "preparing a workflow. Never tell the user to open an app manually. "
                + "When the user explicitly asks you to send a text/SMS/message, use "
                + "messages_send directly after resolving the recipient; do not draft and "
                + "ask for approval in full YOLO. Never say a message was sent unless "
                + "messages_send returned status=messages.sent. "
                + "If an app is missing, closed, backgrounded, or uncertain, call open_app "
                + "or get_screen and keep acting. When the user names a specific app or "
                + "service, pass that exact app/service name to open_app rather than a "
                + "generic category label. For media requests like playing an artist, "
                + "song, playlist, or album, "
                + "opening the app is only setup: search, select/play, and verify playback "
                + "before finish_task. For custom-rendered workflows, do not fail just "
                + "because the accessibility tree is sparse or a screen looks visually "
                + "similar after a tap; use the screenshot, visible text, and raw "
                + "coordinates. If a visible control advances the user's requested "
                + "workflow, use it. "
                + approvalResultInstruction(fullYolo)
                + "Default to silence while taking tool actions. Do not narrate plans, tool "
                + "names, uncertainty, or obvious UI state. If you must speak mid-task, use "
                + "at most five words. Final outcomes should be one short sentence.";
    }

    private static String initiativeInstruction() {
        return "Be direct and action-heavy. The user wants the phone operated, not a "
                + "careful monologue. Make reasonable assumptions, choose default/top/"
                + "visible options, keep moving through reversible UI, and verify progress "
                + "from the screen yourself. Do not ask the user to confirm every step or "
                + "repeat back obvious plans. Do not explain what you are about to do; just "
                + "do it. ";
    }

    private static String yoloModeInstruction(boolean fullYolo) {
        if (!fullYolo) {
            return "";
        }
        return "Autonomy mode is full YOLO: execute requested high-risk actions directly, "
                + "including payment, purchase, booking, sending, calling, posting, "
                + "installation, and account surfaces. Do not call ask_user_confirmation "
                + "unless a tool result explicitly requires it. ";
    }

    private static String approvalResultInstruction(boolean fullYolo) {
        if (fullYolo) {
            return "If an OS/tool result asks for approval, do not call "
                    + "ask_user_confirmation; continue through visible UI when possible, "
                    + "otherwise report the block briefly. ";
        }
        return "If an OS/tool result requires approval, show it with "
                + "ask_user_confirmation and include action_json with the exact next "
                + "tool and arguments. ";
    }

    private void startAudioInput(final RealtimeWebSocket socket,
            final MultimodalSession.Callback callback)
            throws IOException {
        int minBuffer = AudioRecord.getMinBufferSize(mInputSampleRate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        int bufferSize = Math.max(minBuffer, mInputSampleRate / 5);
        AudioRecord recorder = createAudioRecord(bufferSize);
        configureAudioEffects(recorder.getAudioSessionId());
        mRecorder = recorder;
        recorder.startRecording();
        Thread audioThread = new Thread(new Runnable() {
            @Override
            public void run() {
                byte[] buffer = new byte[bufferSize];
                while (!mCancelled && !Thread.currentThread().isInterrupted()) {
                    int read;
                    try {
                        read = recorder.read(buffer, 0, buffer.length);
                    } catch (IllegalStateException e) {
                        callback.onError("microphone_read_failed");
                        return;
                    }
                    if (read <= 0) {
                        continue;
                    }
                    double rms = pcm16Rms(buffer, read);
                    mRecentMicRms = rms;
                    try {
                        byte[] chunk = new byte[read];
                        System.arraycopy(buffer, 0, chunk, 0, read);
                        sendAudioChunk(socket, chunk);
                        if (maybeCommitSimpleAudioTurn(socket, callback, rms)) {
                            return;
                        }
                        maybeStopPlaybackForLocalBargeIn(socket, callback, rms);
                    } catch (IOException | JSONException e) {
                        if (!mCancelled) {
                            callback.onError(e.getMessage() == null
                                    ? "audio_stream_failed" : e.getMessage());
                        }
                        return;
                    }
                }
            }
        }, "OpenPhoneRealtimeMic");
        mAudioThread = audioThread;
        audioThread.start();
    }

    private boolean maybeCommitSimpleAudioTurn(RealtimeWebSocket socket,
            MultimodalSession.Callback callback, double rms) throws IOException, JSONException {
        if (!mSimpleRealtimeProtocol || mSimpleInputFinalCommitted) {
            return false;
        }
        long now = SystemClock.uptimeMillis();
        if (rms >= SIMPLE_SPEECH_RMS) {
            mSimpleSpeechStarted = true;
            mSimpleLastSpeechUptimeMillis = now;
            return false;
        }
        if (!mSimpleSpeechStarted || mSimpleLastSpeechUptimeMillis <= 0L) {
            return false;
        }
        if (now - mSimpleLastSpeechUptimeMillis < SIMPLE_TURN_END_SILENCE_MS) {
            return false;
        }
        sendSimpleInputCommit(socket, true);
        mSimpleInputFinalCommitted = true;
        callback.onStatus("Thinking");
        Log.i(TAG, "simple realtime audio turn committed");
        return true;
    }

    private AudioRecord createAudioRecord(int bufferSize) throws IOException {
        int[] sources = new int[] {
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                MediaRecorder.AudioSource.MIC
        };
        for (int source : sources) {
            AudioRecord recorder = new AudioRecord(source, mInputSampleRate,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    bufferSize);
            if (recorder.getState() == AudioRecord.STATE_INITIALIZED) {
                Log.i(TAG, "audio record source=" + source);
                return recorder;
            }
            recorder.release();
        }
        throw new IOException("microphone_unavailable");
    }

    private static void sendAudioChunk(RealtimeWebSocket socket, byte[] chunk)
            throws IOException, JSONException {
        if (chunk == null || chunk.length == 0) {
            return;
        }
        socket.send(new JSONObject()
                .put("type", "input_audio_buffer.append")
                .put("audio", Base64.encodeToString(chunk, Base64.NO_WRAP)));
    }

    private static void sendSimpleInputCommit(RealtimeWebSocket socket, boolean terminal)
            throws IOException, JSONException {
        socket.send(new JSONObject()
                .put("type", "input_audio_buffer.commit")
                .put("final", terminal));
    }

    private void startScreenCache(final ModelAdapter.ToolExecutor executor) {
        if (executor == null) {
            return;
        }
        Thread screenThread = new Thread(new Runnable() {
            @Override
            public void run() {
                while (!mCancelled && !Thread.currentThread().isInterrupted()
                        && !executor.isCancelled()) {
                    refreshScreenCache(executor, "background live voice screen cache", false);
                    try {
                        Thread.sleep(SCREEN_CACHE_INTERVAL_MS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                }
            }
        }, "OpenPhoneRealtimeScreenCache");
        mScreenCacheThread = screenThread;
        screenThread.start();
    }

    private void handleEvent(RealtimeWebSocket socket, String taskId,
            ModelAdapter.ToolExecutor executor, MultimodalSession.Callback callback, JSONObject event)
            throws IOException, JSONException {
        String type = event.optString("type");
        markActionResponseActivity(type);
        if ("error".equals(type)) {
            JSONObject error = event.optJSONObject("error");
            if (error != null && "conversation_already_has_active_response".equals(
                    error.optString("code"))) {
                Log.w(TAG, "ignoring redundant response.create while response is active");
                return;
            }
            if (isCancelRaceError(error)) {
                Log.i(TAG, "ignoring harmless response.cancel race: "
                        + error.optString("message", error.toString()));
                return;
            }
            throw new IOException(error == null ? event.toString() : error.toString());
        }
        if ("input_audio_buffer.speech_started".equals(type)) {
            if (isPlaybackActiveOrRecentlyActive()) {
                if (mRecentMicRms >= SERVER_BARGE_IN_RMS) {
                    handleServerSpeechStartedDuringPlayback(socket, callback);
                } else {
                    Log.i(TAG, "server speech_started ignored during playback micRms="
                            + Math.round(mRecentMicRms));
                }
                return;
            }
            callback.onStatus("Listening");
            return;
        }
        if ("input_audio_buffer.speech_stopped".equals(type)) {
            callback.onStatus("Observing");
            return;
        }
        if (mSimpleRealtimeProtocol && "transcription.delta".equals(type)) {
            String delta = event.optString("delta", "");
            if (!delta.isEmpty()) {
                mPendingAssistantTranscript =
                        (mPendingAssistantTranscript == null ? "" : mPendingAssistantTranscript)
                                + delta;
            }
            return;
        }
        if (mSimpleRealtimeProtocol && "transcription.done".equals(type)) {
            String text = event.optString("text", "").trim();
            if (text.isEmpty()) {
                text = mPendingAssistantTranscript == null
                        ? "" : mPendingAssistantTranscript.trim();
            }
            mPendingAssistantTranscript = null;
            if (!text.isEmpty()) {
                callback.onAssistantTranscript(text);
            }
            return;
        }
        if (mSimpleRealtimeProtocol && "input_audio_buffer.committed".equals(type)) {
            callback.onStatus("Thinking");
            return;
        }
        if ("input_audio_buffer.committed".equals(type)) {
            callback.onStatus("Observing");
            resetTurnToolState();
            appendAutoScreenContext(socket, executor,
                    "fresh screen after the user's latest voice turn", false);
            sendActionResponseCreate(socket, "act on the user's latest voice request");
            callback.onStatus("Thinking");
            Log.i(TAG, "required action response.create sent after cached screen context");
            return;
        }
        if ("conversation.item.input_audio_transcription.done".equals(type)) {
            String transcript = event.optString("transcript", "").trim();
            if (!transcript.isEmpty()) {
                Log.i(TAG, "user transcript=" + preview(transcript));
                mOutcomeTracker.observeUserTranscript(transcript);
                callback.onUserTranscript(transcript);
            }
            return;
        }
        if ("response.output_audio.delta".equals(type)
                || "response.audio.delta".equals(type)) {
            playAudioDelta(event);
            return;
        }
        if ("response.output_audio_transcript.done".equals(type)
                || "response.audio_transcript.done".equals(type)) {
            String transcript = event.optString("transcript", "").trim();
            if (!transcript.isEmpty()) {
                mPendingAssistantTranscript = transcript;
            }
            return;
        }
        if ("response.output_audio.done".equals(type) || "response.audio.done".equals(type)) {
            drainPlayback("audio_done");
            flushAssistantTranscript(callback);
            return;
        }
        if ("response.cancelled".equals(type) || "response.canceled".equals(type)) {
            markResponseInterrupted(SystemClock.uptimeMillis());
            muteCurrentAssistantAudio("response_cancelled");
            mPendingToolResponseCreate = false;
            mPendingAssistantTranscript = null;
            stopPlayback();
            if (mRetryActionAfterStallCancel) {
                sendRecoveryAfterStallCancel(socket, executor, callback,
                        "response_cancelled after stalled action response");
            }
            return;
        }
        RealtimeFunctionCall call = functionCallFromEvent(event);
        if (call != null) {
            if (executeFunctionCall(socket, taskId, executor, callback, call)) {
                mPendingToolResponseCreate = true;
            }
            return;
        }
        if ("response.done".equals(type)) {
            boolean sentToolOutput = false;
            JSONObject response = event.optJSONObject("response");
            if (response != null && "cancelled".equals(response.optString("status"))) {
                markResponseInterrupted(SystemClock.uptimeMillis());
                muteCurrentAssistantAudio("response_done_cancelled");
                mPendingToolResponseCreate = false;
                mPendingAssistantTranscript = null;
                stopPlayback();
                if (mRetryActionAfterStallCancel) {
                    sendRecoveryAfterStallCancel(socket, executor, callback,
                            "response_done_cancelled after stalled action response");
                }
                return;
            }
            if (response != null) {
                List<RealtimeFunctionCall> calls = functionCallsFromResponse(response);
                for (RealtimeFunctionCall responseCall : calls) {
                    sentToolOutput |= executeFunctionCall(socket, taskId, executor,
                            callback, responseCall);
                }
            }
            if (mPendingTerminalToolResponseCreate) {
                mActionResponseOutstanding = false;
                mPendingToolResponseCreate = false;
                mPendingTerminalToolResponseCreate = false;
                sendFinalResponseCreate(socket);
                Log.i(TAG, "final response.create sent after terminal tool");
                return;
            }
            if (sentToolOutput || mPendingToolResponseCreate) {
                mPendingToolResponseCreate = false;
                sendActionResponseCreate(socket, "continue acting after the latest tool result");
                Log.i(TAG, "required action response.create sent after tool output");
                return;
            }
            drainPlayback("response_done");
            flushAssistantTranscript(callback);
            mActionResponseOutstanding = false;
        }
    }

    private void flushAssistantTranscript(MultimodalSession.Callback callback) {
        String transcript = mPendingAssistantTranscript;
        if (transcript == null || transcript.trim().isEmpty()) {
            return;
        }
        mPendingAssistantTranscript = null;
        callback.onAssistantTranscript(transcript.trim());
    }

    private boolean executeFunctionCall(RealtimeWebSocket socket, String taskId,
            ModelAdapter.ToolExecutor executor, MultimodalSession.Callback callback, RealtimeFunctionCall call)
            throws IOException, JSONException {
        if (call.callId.isEmpty() || mCompletedCallIds.contains(call.callId)) {
            return false;
        }
        mCompletedCallIds.add(call.callId);
        ParseResult parsedArguments = parseArguments(call.arguments);
        JSONObject arguments = parsedArguments.arguments;
        if (parsedArguments.recoveredFromError) {
            if (mFullYolo && "ask_user_confirmation".equals(call.name)) {
                Log.w(TAG, "malformed approval call rejected in full yolo args="
                        + preview(call.arguments));
                socket.send(new JSONObject()
                        .put("type", "conversation.item.create")
                        .put("item", new JSONObject()
                                .put("type", "function_call_output")
                                .put("call_id", call.callId)
                                .put("output", yoloApprovalRejectedJson())));
                return true;
            }
            if (isIgnoringPartialFunctionCalls()) {
                Log.i(TAG, "ignoring partial function call after interruption name="
                        + call.name + " args=" + preview(call.arguments));
                return false;
            }
            Log.w(TAG, "bad function arguments for " + call.name
                    + ": " + preview(call.arguments) + "; reporting bad_tool_json");
            socket.send(new JSONObject()
                    .put("type", "conversation.item.create")
                    .put("item", new JSONObject()
                            .put("type", "function_call_output")
                            .put("call_id", call.callId)
                            .put("output", errorJson("bad_tool_json"))));
            return true;
        }
        Log.i(TAG, "tool call name=" + call.name + " args=" + preview(arguments.toString()));
        callback.onToolCall(call.name);
        ensureToolReason(call.name, arguments);
        mOutcomeTracker.observeToolCall(call.name, arguments, mFullYolo,
                cachedForegroundPackage());
        String output;
        boolean yoloApprovalRejected = false;
        boolean pendingOutcomeRejected = false;
        if (mFullYolo && "ask_user_confirmation".equals(call.name)) {
            yoloApprovalRejected = true;
            output = yoloApprovalRejectedJson();
            Log.w(TAG, "approval tool rejected in full yolo args="
                    + preview(arguments.toString()));
        } else if (ToolCatalog.get().isTerminalTool(call.name)
                && mOutcomeTracker.shouldBlockTerminalTool(call.name)) {
            pendingOutcomeRejected = true;
            output = mOutcomeTracker.pendingOutcomeBlockedJson(call.name);
            Log.w(TAG, "terminal rejected by pending outcomes tool=" + call.name
                    + " pending=" + mOutcomeTracker.pendingSummary()
                    + " lastMessageSendResult=" + preview(mLastMessageSendResult)
                    + " args=" + preview(arguments.toString()));
        } else if (!ToolCatalog.get().isAllowedTool(call.name)) {
            output = errorJson("unknown_model_tool:" + call.name);
        } else if (executor.isCancelled()) {
            output = "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
        } else {
            mToolExecutorLock.lock();
            try {
                output = executor.callTool(call.name, arguments.toString());
            } finally {
                mToolExecutorLock.unlock();
            }
        }
        callback.onToolResult(call.name, output == null ? "" : output);
        rememberToolOutcome(call.name, output);
        socket.send(new JSONObject()
                .put("type", "conversation.item.create")
                .put("item", new JSONObject()
                        .put("type", "function_call_output")
                        .put("call_id", call.callId)
                        .put("output", output == null ? "" : output)));
        mLastActionResponseActivityUptimeMillis = SystemClock.uptimeMillis();
        if (yoloApprovalRejected || pendingOutcomeRejected) {
            return true;
        }
        if (ToolCatalog.get().isTerminalTool(call.name)) {
            mPendingTerminalToolResponseCreate = true;
            return true;
        }
        if (ToolCatalog.get().drivesVisibleUi(call.name) && !executor.isCancelled()) {
            appendAutoScreenContext(socket, executor,
                    "fresh screen after " + call.name, true);
            mOutcomeTracker.observeScreen(mCachedScreenContext);
        }
        return true;
    }

    private void sendActionResponseCreate(RealtimeWebSocket socket, String purpose)
            throws IOException, JSONException {
        sendActionResponseCreate(socket, purpose, false);
    }

    private void sendActionResponseCreate(RealtimeWebSocket socket, String purpose,
            boolean recovery)
            throws IOException, JSONException {
        long now = SystemClock.uptimeMillis();
        if (recovery) {
            mActionResponseStallRecoveries++;
        } else {
            mActionResponseStallRecoveries = 0;
        }
        mActionResponseOutstanding = true;
        mRetryActionAfterStallCancel = false;
        mActionResponseCreatedUptimeMillis = now;
        mLastActionResponseActivityUptimeMillis = now;
        socket.send(new JSONObject()
                .put("type", "response.create")
                .put("response", new JSONObject()
                        .put("tool_choice", "required")
                        .put("output_modalities", new JSONArray().put("audio"))
                        .put("max_output_tokens", 500)
                        .put("instructions", "This is a phone-control turn: call exactly one "
                                + "tool now. Do not speak, narrate, or explain before the tool. "
                                + "Use the automatic screen context if it was provided; call "
                                + "get_screen only when that context is missing or stale. "
                                + "Never ask the user to open an app manually; use open_app "
                                + "or continue with visible UI controls yourself. "
                                + (mFullYolo ? "Full YOLO is enabled and approval is not "
                                        + "available; if the user asked to send a message, "
                                        + "call messages_send directly. Never report that "
                                        + "a message was sent unless messages_send returned "
                                        + "status=messages.sent. " : "")
                                + "Do not finish after merely opening an app when the user "
                                + "asked to play, search, select, order, book, post, or send. "
                                + "For custom-rendered app flows, do not fail because the "
                                + "screen looks similar after a tap; use screenshot coordinates "
                                + "and continue through visible controls that advance the "
                                + "requested workflow until a real visible blocker appears. "
                                + (recovery ? "Previous response stalled without a tool; "
                                        + "recover by calling one concrete phone tool now. " : "")
                                + (purpose == null ? "" : purpose))));
    }

    private void resetTurnToolState() {
        mLastMessageSendResult = "";
        mActionResponseOutstanding = false;
        mRetryActionAfterStallCancel = false;
        mActionResponseStallRecoveries = 0;
    }

    private void rememberToolOutcome(String toolName, String output) {
        mOutcomeTracker.observeToolResult(toolName, output, mCachedScreenContext);
        if (!"messages_send".equals(toolName)) {
            return;
        }
        mLastMessageSendResult = output == null ? "" : output;
    }

    private void sendFinalResponseCreate(RealtimeWebSocket socket)
            throws IOException, JSONException {
        mActionResponseOutstanding = false;
        mRetryActionAfterStallCancel = false;
        socket.send(new JSONObject()
                .put("type", "response.create")
                .put("response", new JSONObject()
                        .put("tool_choice", "none")
                        .put("output_modalities", new JSONArray().put("audio"))
                        .put("max_output_tokens", 40)
                        .put("instructions", "Say the final result in one short sentence. "
                                + "No explanation, no recap, no tool names.")));
    }

    private void markActionResponseActivity(String eventType) {
        if (eventType != null && eventType.startsWith("response.")) {
            mLastActionResponseActivityUptimeMillis = SystemClock.uptimeMillis();
        }
    }

    private boolean maybeRecoverStalledActionResponse(RealtimeWebSocket socket,
            ModelAdapter.ToolExecutor executor, MultimodalSession.Callback callback)
            throws IOException, JSONException {
        if (socket == null || executor == null || executor.isCancelled() || mCancelled) {
            return false;
        }
        long now = SystemClock.uptimeMillis();
        if (mRetryActionAfterStallCancel) {
            if (now - mStallCancelRequestedUptimeMillis >= STALL_CANCEL_GRACE_MS) {
                Log.w(TAG, "stalled action response cancel timed out; retrying response.create");
                sendRecoveryAfterStallCancel(socket, executor, callback,
                        "stalled action response cancel timed out");
                return true;
            }
            return false;
        }
        if (!mActionResponseOutstanding) {
            return false;
        }
        long lastActivity = Math.max(mActionResponseCreatedUptimeMillis,
                mLastActionResponseActivityUptimeMillis);
        long idleMs = now - lastActivity;
        if (idleMs < ACTION_RESPONSE_STALL_MS) {
            return false;
        }
        if (mActionResponseStallRecoveries >= ACTION_RESPONSE_STALL_MAX_RECOVERIES) {
            Log.w(TAG, "stalled action response exceeded recovery limit idleMs=" + idleMs);
            mActionResponseOutstanding = false;
            callback.onStatus("Listening");
            return true;
        }
        Log.w(TAG, "stalled action response detected idleMs=" + idleMs
                + " recovery=" + (mActionResponseStallRecoveries + 1));
        callback.onStatus("Recovering");
        JSONObject cancel = new JSONObject().put("type", "response.cancel");
        if (mCurrentResponseId != null && !mCurrentResponseId.isEmpty()) {
            cancel.put("response_id", mCurrentResponseId);
        }
        socket.send(cancel);
        mRetryActionAfterStallCancel = true;
        mStallCancelRequestedUptimeMillis = now;
        mActionResponseOutstanding = false;
        return true;
    }

    private void sendRecoveryAfterStallCancel(RealtimeWebSocket socket,
            ModelAdapter.ToolExecutor executor, MultimodalSession.Callback callback, String reason)
            throws IOException, JSONException {
        mRetryActionAfterStallCancel = false;
        if (mPendingTerminalToolResponseCreate) {
            mPendingToolResponseCreate = false;
            mPendingTerminalToolResponseCreate = false;
            sendFinalResponseCreate(socket);
            Log.i(TAG, "final response.create sent after stalled terminal response recovery");
            return;
        }
        appendAutoScreenContext(socket, executor,
                "fresh screen after stalled response recovery", false);
        sendActionResponseCreate(socket, reason == null || reason.trim().isEmpty()
                ? "recover from stalled response; call a concrete phone tool now"
                : reason, true);
        callback.onStatus("Thinking");
        Log.i(TAG, "required action response.create sent after stalled response recovery");
    }

    private void appendAutoScreenContext(RealtimeWebSocket socket,
            ModelAdapter.ToolExecutor executor, String reason, boolean forceRefresh) {
        if (socket == null || executor == null || executor.isCancelled()) {
            return;
        }
        try {
            CachedScreenContext screenContext = forceRefresh
                    ? refreshScreenCache(executor, reason, true) : mCachedScreenContext;
            long ageMs = screenContext == null ? Long.MAX_VALUE
                    : SystemClock.uptimeMillis() - screenContext.uptimeMillis;
            if (screenContext == null || ageMs > SCREEN_CACHE_MAX_AGE_MS) {
                Log.i(TAG, "auto screen context skipped stale ageMs="
                        + (ageMs == Long.MAX_VALUE ? -1 : ageMs)
                        + " reason=" + preview(reason));
                return;
            }
            socket.send(autoScreenConversationItem(screenContext.screenJson, reason));
            Log.i(TAG, "auto screen context appended cached ageMs=" + ageMs
                    + " reason=" + preview(reason)
                    + " chars=" + screenContext.rawLength);
        } catch (JSONException | IOException | RuntimeException e) {
            Log.w(TAG, "auto screen context failed", e);
        }
    }

    private CachedScreenContext refreshScreenCache(ModelAdapter.ToolExecutor executor,
            String reason, boolean waitForToolLock) {
        if (executor == null || executor.isCancelled() || mCancelled) {
            return null;
        }
        boolean locked = false;
        try {
            if (waitForToolLock) {
                mToolExecutorLock.lock();
                locked = true;
            } else {
                locked = mToolExecutorLock.tryLock();
                if (!locked) {
                    return null;
                }
            }
            long start = SystemClock.uptimeMillis();
            JSONObject arguments = new JSONObject()
                    .put("include_screenshot", true)
                    .put("include_activity", true)
                    .put("include_ui_tree", false)
                    .put("max_dimension", 384)
                    .put("quality", 45)
                    .put("reason", reason == null || reason.trim().isEmpty()
                            ? "refresh current visible phone screen for realtime context"
                            : reason);
            String screen = executor.callTool("get_screen", arguments.toString());
            JSONObject screenJson = new JSONObject(screen == null ? "{}" : screen);
            CachedScreenContext screenContext = new CachedScreenContext(screenJson,
                    screen == null ? 0 : screen.length(), SystemClock.uptimeMillis());
            mCachedScreenContext = screenContext;
            mOutcomeTracker.observeScreen(screenContext);
            Log.i(TAG, "screen cache refreshed ms="
                    + (SystemClock.uptimeMillis() - start)
                    + " chars=" + screenContext.rawLength
                    + " reason=" + preview(reason));
            return screenContext;
        } catch (JSONException | RuntimeException e) {
            Log.w(TAG, "screen cache refresh failed", e);
            return null;
        } finally {
            if (locked) {
                mToolExecutorLock.unlock();
            }
        }
    }

    private static JSONObject autoScreenConversationItem(JSONObject screenJson, String reason)
            throws JSONException {
        JSONArray content = new JSONArray()
                .put(new JSONObject()
                        .put("type", "input_text")
                        .put("text", autoScreenText(screenJson, reason)));
        JSONObject screenshot = screenJson == null ? null : screenJson.optJSONObject("screenshot");
        if (screenshot != null) {
            String data = screenshot.optString("data", "");
            if (!data.isEmpty()) {
                String mimeType = screenshot.optString("mime_type", "image/jpeg");
                content.put(new JSONObject()
                        .put("type", "input_image")
                        .put("image_url", "data:" + mimeType + ";base64," + data)
                        .put("detail", "low"));
            }
        }
        return new JSONObject()
                .put("type", "conversation.item.create")
                .put("item", new JSONObject()
                        .put("type", "message")
                        .put("role", "user")
                        .put("content", content));
    }

    private static String autoScreenText(JSONObject screenJson, String reason)
            throws JSONException {
        JSONObject compact = compactScreenJson(screenJson);
        String text = "Automatic current phone screen context"
                + (reason == null || reason.trim().isEmpty() ? "" : " (" + reason.trim() + ")")
                + ". Use this before deciding the next phone action. "
                + "Do not describe this context to the user unless they asked what is visible.\n"
                + compact.toString();
        if (text.length() <= AUTO_SCREEN_MAX_TEXT_CHARS) {
            return text;
        }
        return text.substring(0, AUTO_SCREEN_MAX_TEXT_CHARS)
                + "...<truncated>";
    }

    private static JSONObject compactScreenJson(JSONObject screenJson) throws JSONException {
        JSONObject compact = new JSONObject();
        if (screenJson == null) {
            return compact.put("status", "screen_unavailable");
        }
        compact.put("status", screenJson.optString("status", ""));
        compact.put("source", screenJson.optString("source", ""));
        compact.put("foreground_package", screenJson.optString("foreground_package", ""));
        JSONObject context = screenJson.optJSONObject("context");
        if (context != null) {
            JSONObject contextCopy = new JSONObject();
            contextCopy.put("foreground_package", context.optString("foreground_package", ""));
            contextCopy.put("foreground_activity", context.optString("foreground_activity", ""));
            contextCopy.put("screen_width", context.optInt("screen_width", 0));
            contextCopy.put("screen_height", context.optInt("screen_height", 0));
            compact.put("context", contextCopy);
        }
        JSONArray riskFlags = screenJson.optJSONArray("risk_flags");
        if (riskFlags != null) {
            compact.put("risk_flags", limitArray(riskFlags, AUTO_SCREEN_MAX_ARRAY_ITEMS));
        }
        JSONArray visibleText = screenJson.optJSONArray("visible_text");
        if (visibleText != null) {
            compact.put("visible_text", limitArray(visibleText, AUTO_SCREEN_MAX_ARRAY_ITEMS));
        }
        JSONArray elements = screenJson.optJSONArray("interactive_elements");
        if (elements != null) {
            compact.put("interactive_elements", limitArray(elements, AUTO_SCREEN_MAX_ARRAY_ITEMS));
        }
        JSONObject screenshot = screenJson.optJSONObject("screenshot");
        if (screenshot != null) {
            compact.put("screenshot", new JSONObject()
                    .put("included", !screenshot.optString("data", "").isEmpty())
                    .put("mime_type", screenshot.optString("mime_type", ""))
                    .put("width", screenshot.optInt("width", 0))
                    .put("height", screenshot.optInt("height", 0)));
        }
        JSONObject uiTree = screenJson.optJSONObject("ui_tree");
        if (uiTree != null && compact.optJSONArray("visible_text") == null) {
            JSONArray treeText = uiTree.optJSONArray("visible_text");
            if (treeText != null) {
                compact.put("visible_text", limitArray(treeText, AUTO_SCREEN_MAX_ARRAY_ITEMS));
            }
        }
        if (uiTree != null && compact.optJSONArray("interactive_elements") == null) {
            JSONArray treeElements = uiTree.optJSONArray("interactive_elements");
            if (treeElements != null) {
                compact.put("interactive_elements",
                        limitArray(treeElements, AUTO_SCREEN_MAX_ARRAY_ITEMS));
            }
        }
        return compact;
    }

    private static JSONArray limitArray(JSONArray input, int limit) throws JSONException {
        JSONArray out = new JSONArray();
        if (input == null) {
            return out;
        }
        int count = Math.min(Math.max(limit, 0), input.length());
        for (int i = 0; i < count; i++) {
            Object value = input.get(i);
            out.put(value);
        }
        if (input.length() > count) {
            out.put("... " + (input.length() - count) + " more");
        }
        return out;
    }

    private synchronized void playAudioDelta(JSONObject event) throws IOException {
        String base64Audio = event.optString("delta", "");
        if ((base64Audio == null || base64Audio.isEmpty()) && mSimpleRealtimeProtocol) {
            base64Audio = event.optString("audio", "");
        }
        if (base64Audio == null || base64Audio.isEmpty()) {
            return;
        }
        String responseId = event.optString("response_id", "");
        String itemId = event.optString("item_id", "");
        if (shouldDropAssistantAudio(responseId, itemId)) {
            Log.i(TAG, "dropping muted assistant audio response=" + preview(responseId)
                    + " item=" + preview(itemId));
            return;
        }
        AudioTrack player = ensurePlayer();
        if (!responseId.isEmpty()) {
            mCurrentResponseId = responseId;
        }
        if (!itemId.isEmpty() && !itemId.equals(mCurrentAssistantItemId)) {
            mCurrentAssistantItemId = itemId;
            mCurrentAssistantContentIndex = event.optInt("content_index", 0);
            mCurrentAssistantItemStartFrame = playbackHeadPosition(player);
        }
        byte[] bytes = Base64.decode(base64Audio, Base64.DEFAULT);
        if (bytes.length > 0) {
            int written = player.write(bytes, 0, bytes.length);
            if (written < 0) {
                throw new IOException("speaker_write_failed:" + written);
            }
            mAssistantAudioActive = true;
            mLastAudioWriteUptimeMillis = SystemClock.uptimeMillis();
            mPlaybackFramesWritten += written / 2;
        }
    }

    private AudioTrack ensurePlayer() throws IOException {
        AudioTrack player = mPlayer;
        if (player != null) {
            return player;
        }
        int minBuffer = AudioTrack.getMinBufferSize(mOutputSampleRate,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
        int bufferSize = Math.max(minBuffer, mOutputSampleRate * 2);
        player = new AudioTrack(AudioManager.STREAM_MUSIC, mOutputSampleRate,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
                bufferSize, AudioTrack.MODE_STREAM);
        if (player.getState() != AudioTrack.STATE_INITIALIZED) {
            player.release();
            throw new IOException("speaker_unavailable");
        }
        player.play();
        mPlayer = player;
        return player;
    }

    private synchronized void stopPlayback() {
        AudioTrack player = mPlayer;
        if (player == null) {
            return;
        }
        try {
            player.pause();
            player.flush();
        } catch (RuntimeException ignored) {
        } finally {
            try {
                player.stop();
            } catch (RuntimeException ignored) {
            }
            try {
                player.release();
            } catch (RuntimeException ignored) {
            }
            if (mPlayer == player) {
                mPlayer = null;
            }
            mPlaybackFramesWritten = 0;
            mAssistantAudioActive = false;
            mLastAudioWriteUptimeMillis = 0L;
        }
    }

    private boolean isPlaybackActiveOrRecentlyActive() {
        if (mAssistantAudioActive) {
            return true;
        }
        long lastWrite = mLastAudioWriteUptimeMillis;
        return lastWrite > 0
                && SystemClock.uptimeMillis() - lastWrite < SELF_ECHO_GUARD_MS;
    }

    private synchronized void drainPlayback(String reason) {
        AudioTrack player = mPlayer;
        if (player == null || !mAssistantAudioActive) {
            return;
        }
        long start = SystemClock.uptimeMillis();
        long remainingFrames = Math.max(0, mPlaybackFramesWritten - playbackHeadPosition(player));
        long drainBudgetMs = Math.min(MAX_PLAYBACK_DRAIN_MS,
                Math.max(PLAYBACK_DRAIN_GRACE_MS,
                        (remainingFrames * 1000L / mOutputSampleRate)
                                + PLAYBACK_DRAIN_GRACE_MS));
        long deadline = start + drainBudgetMs;
        while (!mCancelled && SystemClock.uptimeMillis() < deadline) {
            remainingFrames = Math.max(0, mPlaybackFramesWritten - playbackHeadPosition(player));
            if (remainingFrames <= mOutputSampleRate / 20) {
                break;
            }
            try {
                Thread.sleep(20);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        mAssistantAudioActive = false;
        Log.i(TAG, "playback drain reason=" + reason
                + " remainingFrames=" + Math.max(0,
                        mPlaybackFramesWritten - playbackHeadPosition(player))
                + " waitedMs=" + (SystemClock.uptimeMillis() - start));
    }

    private static long playbackHeadPosition(AudioTrack player) {
        if (player == null) {
            return 0L;
        }
        try {
            return player.getPlaybackHeadPosition() & 0xffffffffL;
        } catch (IllegalStateException e) {
            return 0L;
        }
    }

    private void maybeStopPlaybackForLocalBargeIn(RealtimeWebSocket socket,
            MultimodalSession.Callback callback, double rms) throws IOException, JSONException {
        if (mCancelled || !mAssistantAudioActive) {
            return;
        }
        long now = SystemClock.uptimeMillis();
        if (now - mLastAudioWriteUptimeMillis < LOCAL_BARGE_IN_GUARD_MS
                || now - mLastBargeInUptimeMillis < BARGE_IN_COOLDOWN_MS
                || rms < LOCAL_BARGE_IN_RMS) {
            return;
        }
        requestBargeIn(socket, callback, "local_mic");
    }

    private void requestBargeIn(RealtimeWebSocket socket, MultimodalSession.Callback callback, String reason)
            throws IOException, JSONException {
        long now = SystemClock.uptimeMillis();
        if (now - mLastBargeInUptimeMillis < BARGE_IN_COOLDOWN_MS) {
            return;
        }
        markResponseInterrupted(now);
        Log.i(TAG, "barge-in accepted reason=" + reason
                + " micRms=" + Math.round(mRecentMicRms));
        mPendingAssistantTranscript = null;
        muteCurrentAssistantAudio(reason);
        JSONObject truncate = conversationTruncateEvent();
        stopPlayback();
        JSONObject cancel = new JSONObject().put("type", "response.cancel");
        if (mCurrentResponseId != null && !mCurrentResponseId.isEmpty()) {
            cancel.put("response_id", mCurrentResponseId);
        }
        socket.send(cancel);
        if (truncate != null) {
            socket.send(truncate);
        }
        callback.onStatus("Listening");
    }

    private void handleServerSpeechStartedDuringPlayback(RealtimeWebSocket socket,
            MultimodalSession.Callback callback) throws IOException, JSONException {
        markResponseInterrupted(SystemClock.uptimeMillis());
        Log.i(TAG, "server speech_started interrupted playback micRms="
                + Math.round(mRecentMicRms));
        mPendingAssistantTranscript = null;
        muteCurrentAssistantAudio("server_vad");
        JSONObject truncate = conversationTruncateEvent();
        stopPlayback();
        if (truncate != null) {
            socket.send(truncate);
        }
        callback.onStatus("Listening");
    }

    private synchronized JSONObject conversationTruncateEvent() throws JSONException {
        AudioTrack player = mPlayer;
        String itemId = mCurrentAssistantItemId;
        if (player == null || itemId == null || itemId.isEmpty()) {
            return null;
        }
        if (mTruncatedAssistantItemIds.contains(itemId)) {
            Log.i(TAG, "conversation truncate skipped already-truncated item=" + itemId);
            return null;
        }
        long playedFrames = Math.max(0,
                playbackHeadPosition(player) - mCurrentAssistantItemStartFrame);
        int audioEndMs = (int) Math.max(0, playedFrames * 1000L / mOutputSampleRate);
        mTruncatedAssistantItemIds.add(itemId);
        Log.i(TAG, "conversation truncate prepared for barge-in item=" + itemId
                + " audioEndMs=" + audioEndMs);
        return new JSONObject()
                .put("type", "conversation.item.truncate")
                .put("item_id", itemId)
                .put("content_index", mCurrentAssistantContentIndex)
                .put("audio_end_ms", audioEndMs);
    }

    private static boolean isCancelRaceError(JSONObject error) {
        if (error == null) {
            return false;
        }
        String message = error.optString("message", "").toLowerCase(Locale.US);
        String code = error.optString("code", "").toLowerCase(Locale.US);
        return code.contains("response_not_found")
                || code.contains("no_active_response")
                || code.contains("response_cancel_not_active")
                || (message.contains("response.cancel")
                        && (message.contains("no response")
                                || message.contains("not found")
                                || message.contains("already")))
                || (message.contains("cancellation failed")
                        && message.contains("no active response"));
    }

    private void markResponseInterrupted(long now) {
        mLastBargeInUptimeMillis = now;
        mDropAssistantAudioUntilUptimeMillis = now + INTERRUPTED_AUDIO_DROP_GRACE_MS;
        mIgnorePartialFunctionCallsUntilUptimeMillis =
                now + INTERRUPTED_FUNCTION_CALL_GRACE_MS;
    }

    private boolean isIgnoringPartialFunctionCalls() {
        return SystemClock.uptimeMillis() < mIgnorePartialFunctionCallsUntilUptimeMillis;
    }

    private synchronized void muteCurrentAssistantAudio(String reason) {
        String responseId = mCurrentResponseId;
        String itemId = mCurrentAssistantItemId;
        if (responseId != null && !responseId.isEmpty()) {
            mMutedResponseIds.add(responseId);
        }
        if (itemId != null && !itemId.isEmpty()) {
            mMutedAssistantItemIds.add(itemId);
        }
        Log.i(TAG, "assistant audio muted reason=" + reason
                + " response=" + preview(responseId)
                + " item=" + preview(itemId));
    }

    private synchronized boolean shouldDropAssistantAudio(String responseId, String itemId) {
        if (responseId != null && !responseId.isEmpty()
                && mMutedResponseIds.contains(responseId)) {
            return true;
        }
        if (itemId != null && !itemId.isEmpty()
                && mMutedAssistantItemIds.contains(itemId)) {
            return true;
        }
        return (responseId == null || responseId.isEmpty())
                && (itemId == null || itemId.isEmpty())
                && SystemClock.uptimeMillis() < mDropAssistantAudioUntilUptimeMillis;
    }

    private void configureAudioEffects(int sessionId) {
        try {
            if (AcousticEchoCanceler.isAvailable()) {
                mEchoCanceler = AcousticEchoCanceler.create(sessionId);
                if (mEchoCanceler != null) {
                    mEchoCanceler.setEnabled(true);
                    Log.i(TAG, "acoustic echo canceller enabled");
                }
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "acoustic echo canceller unavailable", e);
        }
        try {
            if (NoiseSuppressor.isAvailable()) {
                mNoiseSuppressor = NoiseSuppressor.create(sessionId);
                if (mNoiseSuppressor != null) {
                    mNoiseSuppressor.setEnabled(true);
                    Log.i(TAG, "noise suppressor enabled");
                }
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "noise suppressor unavailable", e);
        }
        try {
            if (AutomaticGainControl.isAvailable()) {
                mAutomaticGainControl = AutomaticGainControl.create(sessionId);
                if (mAutomaticGainControl != null) {
                    mAutomaticGainControl.setEnabled(true);
                    Log.i(TAG, "automatic gain control enabled");
                }
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "automatic gain control unavailable", e);
        }
    }

    private void releaseAudioEffects() {
        AcousticEchoCanceler echoCanceler = mEchoCanceler;
        mEchoCanceler = null;
        if (echoCanceler != null) {
            try {
                echoCanceler.release();
            } catch (RuntimeException ignored) {
            }
        }
        NoiseSuppressor noiseSuppressor = mNoiseSuppressor;
        mNoiseSuppressor = null;
        if (noiseSuppressor != null) {
            try {
                noiseSuppressor.release();
            } catch (RuntimeException ignored) {
            }
        }
        AutomaticGainControl automaticGainControl = mAutomaticGainControl;
        mAutomaticGainControl = null;
        if (automaticGainControl != null) {
            try {
                automaticGainControl.release();
            } catch (RuntimeException ignored) {
            }
        }
    }

    private static double pcm16Rms(byte[] buffer, int byteCount) {
        int samples = byteCount / 2;
        if (samples <= 0) {
            return 0.0;
        }
        double sumSquares = 0.0;
        for (int i = 0; i + 1 < byteCount; i += 2) {
            int sample = (buffer[i] & 0xff) | (buffer[i + 1] << 8);
            sumSquares += (double) sample * (double) sample;
        }
        return Math.sqrt(sumSquares / samples);
    }

    private static RealtimeFunctionCall functionCallFromEvent(JSONObject event) {
        String type = event.optString("type");
        if ("response.function_call_arguments.done".equals(type)) {
            JSONObject item = event.optJSONObject("item");
            if (item != null) {
                return new RealtimeFunctionCall(
                        item.optString("call_id", event.optString("call_id")),
                        item.optString("name", event.optString("name")),
                        item.optString("arguments", event.optString("arguments")));
            }
            return new RealtimeFunctionCall(
                    event.optString("call_id"),
                    event.optString("name"),
                    event.optString("arguments"));
        }
        return null;
    }

    private static List<RealtimeFunctionCall> functionCallsFromResponse(JSONObject response) {
        List<RealtimeFunctionCall> calls = new ArrayList<>();
        JSONArray output = response.optJSONArray("output");
        if (output == null) {
            return calls;
        }
        for (int i = 0; i < output.length(); i++) {
            JSONObject item = output.optJSONObject(i);
            if (item == null || !"function_call".equals(item.optString("type"))) {
                continue;
            }
            calls.add(new RealtimeFunctionCall(
                    item.optString("call_id"),
                    item.optString("name"),
                    item.optString("arguments")));
        }
        return calls;
    }

    private static ParseResult parseArguments(String arguments) {
        if (arguments == null || arguments.trim().isEmpty()) {
            return new ParseResult(new JSONObject(), false);
        }
        try {
            return new ParseResult(new JSONObject(arguments), false);
        } catch (JSONException e) {
            return new ParseResult(new JSONObject(), true);
        }
    }

    private static void ensureToolReason(String toolName, JSONObject arguments)
            throws JSONException {
        if (arguments == null || !ToolCatalog.get().requiresReason(toolName)
                || arguments.optString("reason", "").trim().length() > 0) {
            return;
        }
        arguments.put("reason", "Live voice task step requested by the user.");
    }

    private String cachedForegroundPackage() {
        CachedScreenContext screenContext = mCachedScreenContext;
        JSONObject screenJson = screenContext == null ? null : screenContext.screenJson;
        if (screenJson == null) {
            return "";
        }
        String foreground = screenJson.optString("foreground_package", "");
        JSONObject context = screenJson.optJSONObject("context");
        if (foreground.isEmpty() && context != null) {
            foreground = context.optString("foreground_package", "");
        }
        return foreground.toLowerCase(Locale.US);
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

    private static String yoloApprovalRejectedJson() {
        try {
            return new JSONObject()
                    .put("status", "error")
                    .put("reason", "approval_unavailable_in_full_yolo")
                    .put("instruction", "Full YOLO is enabled. Do not ask for approval "
                            + "and do not fail because approval is unavailable. Continue "
                            + "with the concrete tool that performs the requested action. "
                            + "For an explicit SMS/text request, use messages_send with "
                            + "the resolved recipient phone number and body.")
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"error\","
                    + "\"reason\":\"approval_unavailable_in_full_yolo\"}";
        }
    }

    private static String errorJson(String reason) {
        try {
            return new JSONObject()
                    .put("status", "error")
                    .put("reason", reason == null ? "" : reason)
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"error\"}";
        }
    }

    private static String preview(String value) {
        if (value == null) {
            return "";
        }
        String cleaned = value.replace('\n', ' ').replace('\r', ' ').trim();
        return cleaned.length() <= 120 ? cleaned : cleaned.substring(0, 120) + "...";
    }

    private static final class OutcomeTracker {
        private boolean mPendingMessageSend;
        private boolean mMessageSendAttempted;
        private boolean mMessageSendBlocked;
        private String mLastMessageSendResult = "";

        void observeUserTranscript(String transcript) {
            String text = normalize(transcript);
            if (text.isEmpty()) {
                return;
            }
            if (containsAny(text, "cancel that", "stop that", "never mind", "nevermind",
                    "forget it")) {
                reset();
                return;
            }
            if (isMessageSendRequest(text)) {
                mPendingMessageSend = true;
                mMessageSendAttempted = false;
                mMessageSendBlocked = false;
            }
        }

        void observeToolCall(String toolName, JSONObject arguments, boolean fullYolo,
                String foregroundPackage) {
            if ("messages_send".equals(toolName)) {
                mPendingMessageSend = true;
                mMessageSendAttempted = true;
                mMessageSendBlocked = false;
                return;
            }
            if ("messages_draft".equals(toolName) && (fullYolo || mPendingMessageSend)) {
                mPendingMessageSend = true;
                return;
            }
        }

        void observeToolResult(String toolName, String output,
                CachedScreenContext screenContext) {
            if ("messages_send".equals(toolName)) {
                mLastMessageSendResult = output == null ? "" : output;
                JSONObject result = parseObjectOrEmpty(output);
                if ("messages.sent".equals(result.optString("status", ""))) {
                    mPendingMessageSend = false;
                    mMessageSendBlocked = false;
                } else {
                    mPendingMessageSend = true;
                    mMessageSendBlocked = true;
                }
            }
        }

        void observeScreen(CachedScreenContext screenContext) {
        }

        boolean shouldBlockTerminalTool(String toolName) {
            return !pendingForTerminalTool(toolName).isEmpty();
        }

        String pendingOutcomeBlockedJson(String toolName) {
            List<String> pending = pendingForTerminalTool(toolName);
            try {
                JSONArray pendingJson = new JSONArray();
                for (String item : pending) {
                    pendingJson.put(item);
                }
                JSONObject result = new JSONObject()
                        .put("status", "error")
                        .put("reason", "terminal_blocked_by_pending_outcomes")
                        .put("pending_outcomes", pendingJson)
                        .put("instruction", instructionForPending(pending));
                if (!mLastMessageSendResult.trim().isEmpty()) {
                    result.put("last_messages_send_result", mLastMessageSendResult);
                }
                return result.toString();
            } catch (JSONException e) {
                return "{\"status\":\"error\","
                        + "\"reason\":\"terminal_blocked_by_pending_outcomes\"}";
            }
        }

        String pendingSummary() {
            return pendingForTerminalTool("finish_task").toString();
        }

        private List<String> pendingForTerminalTool(String toolName) {
            ArrayList<String> pending = new ArrayList<>();
            if ("finish_task".equals(toolName) && mPendingMessageSend) {
                pending.add("message_send");
            } else if ("fail_task".equals(toolName) && mPendingMessageSend
                    && !mMessageSendBlocked && !mMessageSendAttempted) {
                pending.add("message_send");
            }
            return pending;
        }

        private String instructionForPending(List<String> pending) {
            StringBuilder instruction = new StringBuilder();
            if (pending.contains("message_send")) {
                instruction.append("The message is not complete until messages_send ")
                        .append("returns status=messages.sent. Resolve the recipient if ")
                        .append("needed, then call messages_send with the requested body. ");
            }
            if (instruction.length() == 0) {
                instruction.append("Continue with the next concrete phone tool.");
            }
            return instruction.toString().trim();
        }

        private void reset() {
            mPendingMessageSend = false;
            mMessageSendAttempted = false;
            mMessageSendBlocked = false;
            mLastMessageSendResult = "";
        }

        private static boolean isMessageSendRequest(String text) {
            boolean hasMessageNoun = containsAny(text, "sms", "text", "message",
                    "messages", "imessage");
            boolean hasSendVerb = containsAny(text, "send", "text ", "tell ",
                    "message ");
            return hasMessageNoun && hasSendVerb;
        }

        private static boolean containsAny(String text, String... needles) {
            String normalized = normalize(text);
            for (String needle : needles) {
                if (!needle.isEmpty() && normalized.contains(needle)) {
                    return true;
                }
            }
            return false;
        }

        private static String normalize(String value) {
            return value == null ? "" : value.toLowerCase(Locale.US);
        }
    }

    private static final class RealtimeFunctionCall {
        final String callId;
        final String name;
        final String arguments;

        RealtimeFunctionCall(String callId, String name, String arguments) {
            this.callId = callId == null ? "" : callId;
            this.name = name == null ? "" : name;
            this.arguments = arguments == null ? "" : arguments;
        }
    }

    private static final class ParseResult {
        final JSONObject arguments;
        final boolean recoveredFromError;

        ParseResult(JSONObject arguments, boolean recoveredFromError) {
            this.arguments = arguments == null ? new JSONObject() : arguments;
            this.recoveredFromError = recoveredFromError;
        }
    }

    private static final class CachedScreenContext {
        final JSONObject screenJson;
        final int rawLength;
        final long uptimeMillis;

        CachedScreenContext(JSONObject screenJson, int rawLength, long uptimeMillis) {
            this.screenJson = screenJson == null ? new JSONObject() : screenJson;
            this.rawLength = Math.max(0, rawLength);
            this.uptimeMillis = uptimeMillis;
        }
    }

    static final class RealtimeWebSocket {
        private static final String WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        private final Socket mSocket;
        private final InputStream mInput;
        private final OutputStream mOutput;
        private final SecureRandom mRandom = new SecureRandom();

        private RealtimeWebSocket(Socket socket) throws IOException {
            mSocket = socket;
            mInput = socket.getInputStream();
            mOutput = socket.getOutputStream();
        }

        static RealtimeWebSocket connect(String url, String bearerToken) throws IOException {
            URI uri = URI.create(url);
            String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.US);
            boolean secure = "wss".equals(scheme);
            if (!secure && !"ws".equals(scheme)) {
                throw new IOException("Unsupported realtime WebSocket scheme: " + scheme);
            }
            String host = uri.getHost();
            int port = uri.getPort() > 0 ? uri.getPort() : secure ? 443 : 80;
            String path = uri.getRawPath();
            if (path == null || path.isEmpty()) {
                path = "/";
            }
            if (uri.getRawQuery() != null && !uri.getRawQuery().isEmpty()) {
                path += "?" + uri.getRawQuery();
            }
            Socket socket = secure
                    ? SSLSocketFactory.getDefault().createSocket(host, port)
                    : new Socket(host, port);
            socket.setSoTimeout((int) CONNECT_TIMEOUT_MS);

            byte[] nonce = new byte[16];
            new SecureRandom().nextBytes(nonce);
            String key = Base64.encodeToString(nonce, Base64.NO_WRAP);
            StringBuilder request = new StringBuilder()
                    .append("GET ").append(path).append(" HTTP/1.1\r\n")
                    .append("Host: ").append(hostHeader(host, port, secure)).append("\r\n")
                    .append("Upgrade: websocket\r\n")
                    .append("Connection: Upgrade\r\n")
                    .append("Sec-WebSocket-Key: ").append(key).append("\r\n")
                    .append("Sec-WebSocket-Version: 13\r\n");
            if (bearerToken != null && !bearerToken.trim().isEmpty()) {
                request.append("Authorization: Bearer ").append(bearerToken).append("\r\n")
                        .append("OpenAI-Safety-Identifier: openphone-local-device\r\n");
            }
            request.append("\r\n");
            OutputStream output = socket.getOutputStream();
            output.write(request.toString().getBytes(StandardCharsets.US_ASCII));
            output.flush();

            InputStream input = socket.getInputStream();
            String header = readHttpHeader(input);
            String[] lines = header.split("\\r?\\n");
            String status = lines.length == 0 ? "" : lines[0];
            String accept = "";
            for (int i = 1; i < lines.length; i++) {
                String line = lines[i];
                int colon = line.indexOf(':');
                if (colon > 0 && "sec-websocket-accept".equals(
                        line.substring(0, colon).trim().toLowerCase(Locale.US))) {
                    accept = line.substring(colon + 1).trim();
                }
            }
            if (status == null || !status.contains(" 101 ")) {
                throw new IOException("Realtime WebSocket upgrade failed: " + status);
            }
            String expected = websocketAccept(key);
            if (!expected.equals(accept)) {
                throw new IOException("Realtime WebSocket accept mismatch.");
            }
            socket.setSoTimeout((int) EVENT_TIMEOUT_MS);
            return new RealtimeWebSocket(socket);
        }

        private static String hostHeader(String host, int port, boolean secure) {
            if ((secure && port == 443) || (!secure && port == 80)) {
                return host;
            }
            return host + ":" + port;
        }

        synchronized void send(JSONObject event) throws IOException {
            sendText(event.toString());
        }

        JSONObject readJson(long timeoutMs) throws IOException, JSONException {
            mSocket.setSoTimeout((int) Math.max(1, Math.min(timeoutMs, EVENT_TIMEOUT_MS)));
            String text = readText();
            return new JSONObject(text);
        }

        void closeQuietly() {
            try {
                sendFrame(0x8, new byte[0]);
            } catch (IOException | RuntimeException ignored) {
            }
            try {
                mSocket.close();
            } catch (IOException | RuntimeException ignored) {
            }
        }

        private void sendText(String text) throws IOException {
            sendFrame(0x1, text.getBytes(StandardCharsets.UTF_8));
        }

        private synchronized void sendFrame(int opcode, byte[] payload) throws IOException {
            ByteArrayOutputStream frame = new ByteArrayOutputStream();
            frame.write(0x80 | (opcode & 0x0f));
            int length = payload.length;
            if (length <= 125) {
                frame.write(0x80 | length);
            } else if (length <= 65535) {
                frame.write(0x80 | 126);
                frame.write((length >>> 8) & 0xff);
                frame.write(length & 0xff);
            } else {
                frame.write(0x80 | 127);
                for (int i = 7; i >= 0; i--) {
                    frame.write((int) ((long) length >>> (8 * i)) & 0xff);
                }
            }
            byte[] mask = new byte[4];
            mRandom.nextBytes(mask);
            frame.write(mask);
            for (int i = 0; i < payload.length; i++) {
                frame.write(payload[i] ^ mask[i % 4]);
            }
            mOutput.write(frame.toByteArray());
            mOutput.flush();
        }

        private String readText() throws IOException {
            ByteArrayOutputStream message = new ByteArrayOutputStream();
            while (true) {
                int b0 = readByte();
                int b1 = readByte();
                boolean fin = (b0 & 0x80) != 0;
                int opcode = b0 & 0x0f;
                boolean masked = (b1 & 0x80) != 0;
                long length = b1 & 0x7f;
                if (length == 126) {
                    length = ((long) readByte() << 8) | readByte();
                } else if (length == 127) {
                    length = 0;
                    for (int i = 0; i < 8; i++) {
                        length = (length << 8) | readByte();
                    }
                }
                byte[] mask = null;
                if (masked) {
                    mask = new byte[] {
                            (byte) readByte(), (byte) readByte(),
                            (byte) readByte(), (byte) readByte()
                    };
                }
                if (length > 16L * 1024L * 1024L) {
                    throw new IOException("Realtime frame too large: " + length);
                }
                byte[] payload = readBytes((int) length);
                if (masked && mask != null) {
                    for (int i = 0; i < payload.length; i++) {
                        payload[i] = (byte) (payload[i] ^ mask[i % 4]);
                    }
                }
                if (opcode == 0x8) {
                    throw new IOException("Realtime WebSocket closed.");
                }
                if (opcode == 0x9) {
                    sendFrame(0xA, payload);
                    continue;
                }
                if (opcode == 0xA) {
                    continue;
                }
                if (opcode == 0x1 || opcode == 0x2 || opcode == 0x0) {
                    message.write(payload);
                    if (fin) {
                        return message.toString(StandardCharsets.UTF_8.name());
                    }
                }
            }
        }

        private int readByte() throws IOException {
            int value = mInput.read();
            if (value < 0) {
                throw new IOException("Realtime WebSocket EOF.");
            }
            return value;
        }

        private byte[] readBytes(int length) throws IOException {
            ByteBuffer buffer = ByteBuffer.allocate(length);
            byte[] chunk = new byte[Math.min(8192, Math.max(1, length))];
            while (buffer.position() < length) {
                int count = mInput.read(chunk, 0, Math.min(chunk.length,
                        length - buffer.position()));
                if (count < 0) {
                    throw new IOException("Realtime WebSocket EOF.");
                }
                buffer.put(chunk, 0, count);
            }
            return buffer.array();
        }

        private static String readHttpHeader(InputStream input) throws IOException {
            ByteArrayOutputStream header = new ByteArrayOutputStream();
            int matched = 0;
            byte[] marker = new byte[] {'\r', '\n', '\r', '\n'};
            while (true) {
                int value = input.read();
                if (value < 0) {
                    throw new IOException("Realtime WebSocket EOF during handshake.");
                }
                header.write(value);
                if ((byte) value == marker[matched]) {
                    matched++;
                    if (matched == marker.length) {
                        break;
                    }
                } else {
                    matched = (byte) value == marker[0] ? 1 : 0;
                }
                if (header.size() > 64 * 1024) {
                    throw new IOException("Realtime WebSocket header too large.");
                }
            }
            return header.toString(StandardCharsets.US_ASCII.name());
        }

        private static String websocketAccept(String key) throws IOException {
            try {
                MessageDigest sha1 = MessageDigest.getInstance("SHA-1");
                byte[] digest = sha1.digest((key + WS_GUID).getBytes(StandardCharsets.US_ASCII));
                return Base64.encodeToString(digest, Base64.NO_WRAP);
            } catch (java.security.NoSuchAlgorithmException e) {
                throw new IOException(e);
            }
        }
    }
}
