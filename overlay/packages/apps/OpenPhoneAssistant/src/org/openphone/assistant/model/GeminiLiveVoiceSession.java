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

import java.io.IOException;
import java.io.UnsupportedEncodingException;
import java.net.SocketTimeoutException;
import java.net.URLEncoder;

public final class GeminiLiveVoiceSession implements MultimodalSession {
    private static final String TAG = "OpenPhoneGeminiLive";

    public static final String MODEL = "gemini-3.1-flash-live-preview";

    private static final String GEMINI_LIVE_URL =
            "wss://generativelanguage.googleapis.com/ws/"
                    + "google.ai.generativelanguage.v1beta.GenerativeService."
                    + "BidiGenerateContent?key=";
    private static final int INPUT_SAMPLE_RATE = 16000;
    private static final int OUTPUT_SAMPLE_RATE = 24000;
    private static final long EVENT_TIMEOUT_MS = 120000;
    private static final long SETUP_TIMEOUT_MS = 15000;
    private static final long SCREEN_FRAME_INTERVAL_MS = 1000;
    private static final long PLAYBACK_DRAIN_GRACE_MS = 300;
    private static final long MAX_PLAYBACK_DRAIN_MS = 5000;
    private static final long LOCAL_BARGE_IN_GUARD_MS = 240;
    private static final long BARGE_IN_COOLDOWN_MS = 800;
    private static final long DROP_AUDIO_AFTER_INTERRUPT_MS = 1800;
    private static final double LOCAL_BARGE_IN_RMS = 1700.0;
    private static final int MAX_CONTINUITY_CHARS = 4000;

    private final String mApiKey;
    private final String mContinuityContextJson;
    private final boolean mFullYolo;
    private final Object mToolLock = new Object();

    private volatile boolean mCancelled;
    private volatile OpenAiRealtimeVoiceSession.RealtimeWebSocket mSocket;
    private volatile AudioRecord mRecorder;
    private volatile AudioTrack mPlayer;
    private volatile Thread mAudioThread;
    private volatile Thread mScreenThread;
    private volatile AcousticEchoCanceler mEchoCanceler;
    private volatile NoiseSuppressor mNoiseSuppressor;
    private volatile AutomaticGainControl mAutomaticGainControl;
    private volatile long mPlaybackFramesWritten;
    private volatile boolean mAssistantAudioActive;
    private volatile long mLastAudioWriteUptimeMillis;
    private volatile long mLastBargeInUptimeMillis;
    private volatile long mDropAssistantAudioUntilUptimeMillis;
    private volatile double mRecentMicRms;
    private String mPendingUserTranscript;
    private String mPendingAssistantTranscript;

    public GeminiLiveVoiceSession(String apiKey, String continuityContextJson, boolean fullYolo) {
        mApiKey = apiKey == null ? "" : apiKey.trim();
        mContinuityContextJson = continuityContextJson == null
                ? "" : continuityContextJson.trim();
        mFullYolo = fullYolo;
    }

    @Override
    public String providerDisplayName() {
        return "Gemini Live";
    }

    @Override
    public String modelName() {
        return MODEL;
    }

    @Override
    public String privacyDisclosure() {
        return "Gemini Live streams mic audio, screen frames, tool calls, and tool results "
                + "to Gemini while the session is active. Model audio is played back on "
                + "the phone.";
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
        OpenAiRealtimeVoiceSession.RealtimeWebSocket socket = mSocket;
        if (socket != null) {
            socket.closeQuietly();
        }
        Thread audioThread = mAudioThread;
        if (audioThread != null) {
            audioThread.interrupt();
        }
        Thread screenThread = mScreenThread;
        if (screenThread != null) {
            screenThread.interrupt();
        }
    }

    @Override
    public void run(String taskId, ModelAdapter.ToolExecutor executor,
            MultimodalSession.Callback callback) {
        if (mApiKey.isEmpty()) {
            callback.onError("Gemini Live needs a Gemini API key.");
            return;
        }
        if (!ToolCatalog.get().isLoaded()) {
            callback.onError("Action registry is not installed; no model tools available.");
            return;
        }

        OpenAiRealtimeVoiceSession.RealtimeWebSocket socket = null;
        try {
            Log.i(TAG, "connect model=" + MODEL);
            socket = OpenAiRealtimeVoiceSession.RealtimeWebSocket.connect(
                    endpointUrl(mApiKey), "");
            mSocket = socket;
            callback.onStatus("Starting Gemini Live");
            JSONObject setup = setupMessage();
            Log.i(TAG, "setup bytes=" + setup.toString().length());
            socket.send(setup);
            waitForSetupComplete(socket);
            startScreenInput(socket, executor, callback);
            startAudioInput(socket, callback);
            Log.i(TAG, "audio and screen streaming started");
            callback.onStatus("Gemini Live");
            while (!mCancelled && !executor.isCancelled()) {
                try {
                    JSONObject event = socket.readJson(EVENT_TIMEOUT_MS);
                    handleEvent(socket, taskId, executor, callback, event);
                } catch (SocketTimeoutException ignored) {
                    callback.onStatus("Gemini Live");
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

    private static String endpointUrl(String apiKey) {
        try {
            return GEMINI_LIVE_URL + URLEncoder.encode(apiKey, "UTF-8");
        } catch (UnsupportedEncodingException e) {
            return GEMINI_LIVE_URL + apiKey;
        }
    }

    private void waitForSetupComplete(OpenAiRealtimeVoiceSession.RealtimeWebSocket socket)
            throws IOException, JSONException {
        long deadline = SystemClock.uptimeMillis() + SETUP_TIMEOUT_MS;
        while (!mCancelled && SystemClock.uptimeMillis() < deadline) {
            JSONObject event = socket.readJson(Math.max(1L,
                    deadline - SystemClock.uptimeMillis()));
            if (event.has("setupComplete")) {
                Log.i(TAG, "setup complete");
                return;
            }
            JSONObject error = event.optJSONObject("error");
            if (error != null) {
                throw new IOException(error.toString());
            }
        }
        throw new SocketTimeoutException("Gemini Live setup timed out.");
    }

    private JSONObject setupMessage() throws JSONException {
        JSONObject automaticActivityDetection = new JSONObject()
                .put("disabled", false)
                .put("startOfSpeechSensitivity", "START_SENSITIVITY_LOW")
                .put("endOfSpeechSensitivity", "END_SENSITIVITY_LOW")
                .put("prefixPaddingMs", 20)
                .put("silenceDurationMs", 500);
        JSONObject generationConfig = new JSONObject()
                .put("responseModalities", new JSONArray().put("AUDIO"))
                .put("thinkingConfig", new JSONObject()
                        .put("thinkingLevel", "minimal"))
                .put("mediaResolution", "MEDIA_RESOLUTION_LOW");
        JSONObject setup = new JSONObject()
                .put("model", "models/" + MODEL)
                .put("generationConfig", generationConfig)
                .put("systemInstruction", new JSONObject()
                        .put("parts", new JSONArray()
                                .put(new JSONObject()
                                        .put("text", liveVoiceInstructions()))))
                .put("tools", new JSONArray()
                        .put(new JSONObject()
                                .put("functionDeclarations",
                                        ToolCatalog.get().geminiFunctionDeclarations())))
                .put("inputAudioTranscription", new JSONObject())
                .put("outputAudioTranscription", new JSONObject())
                .put("realtimeInputConfig", new JSONObject()
                        .put("automaticActivityDetection", automaticActivityDetection));
        return new JSONObject().put("setup", setup);
    }

    private String liveVoiceInstructions() {
        String continuityContext = boundedContinuityContext();
        String continuity = continuityContext.isEmpty()
                        ? ""
                        : "Recent continuity context from prior OpenPhone sessions. Use this "
                                + "when the user refers to previous conversation, previous work, "
                                + "or asks what you were doing; otherwise do not overfit to it:\n"
                                + continuityContext + "\n\n";
        return "You are OpenPhone, a capable live OS voice agent running on the user's phone. "
                + "The user is speaking to you through a low-latency Gemini Live voice and "
                + "screen session. " + continuity
                + yoloModeInstruction()
                + "Continuous rendered screen frames are streamed into this session. Treat "
                + "them as the full phone UI the user sees. Do not claim you can only see an "
                + "accessibility view. Use the screenshot/video frames and raw coordinates "
                + "when labels are missing. "
                + "Act first. Use the phone tools whenever they help. If the user asks you "
                + "to control an app, keep observing and acting until the requested result "
                + "is done or the tools report a real block. Do not ask clarification "
                + "questions unless every concrete next step is impossible without the "
                + "answer. For vague requests, make a reasonable choice and continue. "
                + "Do not ask for approval for ordinary app navigation, typing fields, "
                + "searching, choosing visible options, or preparing a workflow. "
                + approvalResultInstruction()
                + "Default to silence while taking tool actions. Do not narrate plans, tool "
                + "names, uncertainty, or obvious UI state. If you must speak mid-task, use "
                + "at most five words. Final outcomes should be one short sentence.";
    }

    private String boundedContinuityContext() {
        if (mContinuityContextJson == null) {
            return "";
        }
        String clean = mContinuityContextJson.trim();
        if (clean.isEmpty() || "{}".equals(clean)) {
            return "";
        }
        if (clean.length() <= MAX_CONTINUITY_CHARS) {
            return clean;
        }
        return clean.substring(0, MAX_CONTINUITY_CHARS) + "...<truncated>";
    }

    private String yoloModeInstruction() {
        if (!mFullYolo) {
            return "";
        }
        return "Autonomy mode is full YOLO: execute requested high-risk actions directly, "
                + "including payment, purchase, booking, sending, calling, posting, "
                + "installation, and account surfaces. Do not call ask_user_confirmation "
                + "unless a tool result explicitly requires it. ";
    }

    private String approvalResultInstruction() {
        if (mFullYolo) {
            return "If an OS/tool result asks for approval, do not call "
                    + "ask_user_confirmation; continue through visible UI when possible, "
                    + "otherwise report the block briefly. ";
        }
        return "If an OS/tool result requires approval, show it with "
                + "ask_user_confirmation and include action_json with the exact next "
                + "tool and arguments. ";
    }

    private void startAudioInput(final OpenAiRealtimeVoiceSession.RealtimeWebSocket socket,
            final MultimodalSession.Callback callback) throws IOException {
        int minBuffer = AudioRecord.getMinBufferSize(INPUT_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        int bufferSize = Math.max(minBuffer, INPUT_SAMPLE_RATE / 5);
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
                        maybeStopPlaybackForLocalBargeIn(callback, rms);
                    } catch (IOException | JSONException e) {
                        if (!mCancelled) {
                            callback.onError(e.getMessage() == null
                                    ? "audio_stream_failed" : e.getMessage());
                        }
                        return;
                    }
                }
            }
        }, "OpenPhoneGeminiMic");
        mAudioThread = audioThread;
        audioThread.start();
    }

    private static AudioRecord createAudioRecord(int bufferSize) throws IOException {
        int[] sources = new int[] {
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                MediaRecorder.AudioSource.MIC
        };
        for (int source : sources) {
            AudioRecord recorder = new AudioRecord(source, INPUT_SAMPLE_RATE,
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

    private static void sendAudioChunk(OpenAiRealtimeVoiceSession.RealtimeWebSocket socket,
            byte[] chunk) throws IOException, JSONException {
        if (chunk == null || chunk.length == 0) {
            return;
        }
        socket.send(new JSONObject()
                .put("realtimeInput", new JSONObject()
                        .put("audio", new JSONObject()
                                .put("data", Base64.encodeToString(chunk, Base64.NO_WRAP))
                                .put("mimeType", "audio/pcm;rate=" + INPUT_SAMPLE_RATE))));
    }

    private void startScreenInput(final OpenAiRealtimeVoiceSession.RealtimeWebSocket socket,
            final ModelAdapter.ToolExecutor executor, final MultimodalSession.Callback callback) {
        Thread screenThread = new Thread(new Runnable() {
            @Override
            public void run() {
                while (!mCancelled && !Thread.currentThread().isInterrupted()
                        && !executor.isCancelled()) {
                    sendScreenFrame(socket, executor);
                    try {
                        Thread.sleep(SCREEN_FRAME_INTERVAL_MS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                }
            }
        }, "OpenPhoneGeminiScreen");
        mScreenThread = screenThread;
        screenThread.start();
    }

    private void sendScreenFrame(OpenAiRealtimeVoiceSession.RealtimeWebSocket socket,
            ModelAdapter.ToolExecutor executor) {
        if (socket == null || executor == null || executor.isCancelled()) {
            return;
        }
        try {
            JSONObject arguments = new JSONObject()
                    .put("include_screenshot", true)
                    .put("include_activity", false)
                    .put("include_ui_tree", false)
                    .put("max_dimension", 512)
                    .put("quality", 45)
                    .put("reason", "stream current phone screen frame to Gemini Live");
            String screen;
            synchronized (mToolLock) {
                screen = executor.callTool("get_screen", arguments.toString());
            }
            JSONObject screenJson = new JSONObject(screen == null ? "{}" : screen);
            JSONObject screenshot = screenJson.optJSONObject("screenshot");
            if (screenshot == null) {
                return;
            }
            String data = screenshot.optString("data", "");
            if (data.isEmpty()) {
                return;
            }
            socket.send(new JSONObject()
                    .put("realtimeInput", new JSONObject()
                            .put("video", new JSONObject()
                                    .put("data", data)
                                    .put("mimeType", screenshot.optString("mime_type",
                                            "image/jpeg")))));
        } catch (JSONException | IOException | RuntimeException e) {
            if (!mCancelled) {
                Log.w(TAG, "screen frame failed", e);
            }
        }
    }

    private void handleEvent(OpenAiRealtimeVoiceSession.RealtimeWebSocket socket,
            String taskId, ModelAdapter.ToolExecutor executor, MultimodalSession.Callback callback,
            JSONObject event) throws IOException, JSONException {
        JSONObject error = event.optJSONObject("error");
        if (error != null) {
            throw new IOException(error.toString());
        }
        JSONObject serverContent = event.optJSONObject("serverContent");
        if (serverContent != null) {
            handleServerContent(callback, serverContent);
        }
        JSONObject toolCall = event.optJSONObject("toolCall");
        if (toolCall != null) {
            executeToolCall(socket, taskId, executor, callback, toolCall);
        }
    }

    private void handleServerContent(MultimodalSession.Callback callback, JSONObject serverContent)
            throws IOException, JSONException {
        if (serverContent.optBoolean("interrupted", false)) {
            Log.i(TAG, "server interrupted current generation micRms="
                    + Math.round(mRecentMicRms));
            mPendingAssistantTranscript = null;
            mDropAssistantAudioUntilUptimeMillis =
                    SystemClock.uptimeMillis() + DROP_AUDIO_AFTER_INTERRUPT_MS;
            stopPlayback();
            callback.onStatus("Listening");
            return;
        }
        JSONObject inputTranscription = serverContent.optJSONObject("inputTranscription");
        if (inputTranscription != null) {
            appendUserTranscript(inputTranscription.optString("text", ""));
        }
        JSONObject outputTranscription = serverContent.optJSONObject("outputTranscription");
        if (outputTranscription != null) {
            appendAssistantTranscript(outputTranscription.optString("text", ""));
        }
        JSONObject modelTurn = serverContent.optJSONObject("modelTurn");
        if (modelTurn != null) {
            JSONArray parts = modelTurn.optJSONArray("parts");
            if (parts != null) {
                for (int i = 0; i < parts.length(); i++) {
                    JSONObject part = parts.optJSONObject(i);
                    if (part == null) {
                        continue;
                    }
                    JSONObject inlineData = part.optJSONObject("inlineData");
                    if (inlineData != null) {
                        playAudioDelta(inlineData.optString("data", ""));
                    }
                }
            }
        }
        if (serverContent.optBoolean("turnComplete", false)) {
            drainPlayback("turn_complete");
            flushTranscripts(callback);
        }
    }

    private void executeToolCall(OpenAiRealtimeVoiceSession.RealtimeWebSocket socket,
            String taskId, ModelAdapter.ToolExecutor executor, MultimodalSession.Callback callback,
            JSONObject toolCall) throws IOException, JSONException {
        JSONArray calls = toolCall.optJSONArray("functionCalls");
        if (calls == null || calls.length() == 0) {
            return;
        }
        JSONArray responses = new JSONArray();
        for (int i = 0; i < calls.length(); i++) {
            JSONObject call = calls.optJSONObject(i);
            if (call == null) {
                continue;
            }
            String name = call.optString("name", "");
            String id = call.optString("id", "");
            JSONObject arguments = call.optJSONObject("args");
            if (arguments == null) {
                arguments = parseArguments(call.optString("args", ""));
            }
            callback.onToolCall(name);
            ensureToolReason(name, arguments);
            String output;
            if (!ToolCatalog.get().isAllowedTool(name)) {
                output = errorJson("unknown_model_tool:" + name);
            } else if (executor.isCancelled()) {
                output = "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
            } else {
                synchronized (mToolLock) {
                    output = executor.callTool(name, arguments.toString());
                }
            }
            callback.onToolResult(name, output == null ? "" : output);
            responses.put(new JSONObject()
                    .put("name", name)
                    .put("id", id)
                    .put("response", new JSONObject()
                            .put("result", jsonCompatibleOutput(output))));
        }
        socket.send(new JSONObject()
                .put("toolResponse", new JSONObject()
                        .put("functionResponses", responses)));
    }

    private synchronized void playAudioDelta(String base64Audio) throws IOException {
        if (base64Audio == null || base64Audio.isEmpty()) {
            return;
        }
        if (SystemClock.uptimeMillis() < mDropAssistantAudioUntilUptimeMillis) {
            return;
        }
        AudioTrack player = ensurePlayer();
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
        int minBuffer = AudioTrack.getMinBufferSize(OUTPUT_SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
        int bufferSize = Math.max(minBuffer, OUTPUT_SAMPLE_RATE * 2);
        player = new AudioTrack(AudioManager.STREAM_MUSIC, OUTPUT_SAMPLE_RATE,
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

    private synchronized void drainPlayback(String reason) {
        AudioTrack player = mPlayer;
        if (player == null || !mAssistantAudioActive) {
            return;
        }
        long start = SystemClock.uptimeMillis();
        long remainingFrames = Math.max(0, mPlaybackFramesWritten - playbackHeadPosition(player));
        long drainBudgetMs = Math.min(MAX_PLAYBACK_DRAIN_MS,
                Math.max(PLAYBACK_DRAIN_GRACE_MS,
                        (remainingFrames * 1000L / OUTPUT_SAMPLE_RATE)
                                + PLAYBACK_DRAIN_GRACE_MS));
        long deadline = start + drainBudgetMs;
        while (!mCancelled && SystemClock.uptimeMillis() < deadline) {
            remainingFrames = Math.max(0, mPlaybackFramesWritten - playbackHeadPosition(player));
            if (remainingFrames <= OUTPUT_SAMPLE_RATE / 20) {
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

    private void maybeStopPlaybackForLocalBargeIn(MultimodalSession.Callback callback, double rms) {
        if (mCancelled || !mAssistantAudioActive) {
            return;
        }
        long now = SystemClock.uptimeMillis();
        if (now - mLastAudioWriteUptimeMillis < LOCAL_BARGE_IN_GUARD_MS
                || now - mLastBargeInUptimeMillis < BARGE_IN_COOLDOWN_MS
                || rms < LOCAL_BARGE_IN_RMS) {
            return;
        }
        mLastBargeInUptimeMillis = now;
        mPendingAssistantTranscript = null;
        mDropAssistantAudioUntilUptimeMillis = now + DROP_AUDIO_AFTER_INTERRUPT_MS;
        stopPlayback();
        callback.onStatus("Listening");
    }

    private void appendUserTranscript(String text) {
        String clean = text == null ? "" : text.trim();
        if (clean.isEmpty()) {
            return;
        }
        mPendingUserTranscript = appendTranscript(mPendingUserTranscript, clean);
    }

    private void appendAssistantTranscript(String text) {
        String clean = text == null ? "" : text.trim();
        if (clean.isEmpty()) {
            return;
        }
        mPendingAssistantTranscript = appendTranscript(mPendingAssistantTranscript, clean);
    }

    private static String appendTranscript(String current, String chunk) {
        if (current == null || current.trim().isEmpty()) {
            return chunk;
        }
        if (current.endsWith(chunk)) {
            return current;
        }
        return current + " " + chunk;
    }

    private void flushTranscripts(MultimodalSession.Callback callback) {
        String userTranscript = mPendingUserTranscript;
        if (userTranscript != null && !userTranscript.trim().isEmpty()) {
            mPendingUserTranscript = null;
            callback.onUserTranscript(userTranscript.trim());
        }
        String assistantTranscript = mPendingAssistantTranscript;
        if (assistantTranscript != null && !assistantTranscript.trim().isEmpty()) {
            mPendingAssistantTranscript = null;
            callback.onAssistantTranscript(assistantTranscript.trim());
        }
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

    private static JSONObject parseArguments(String arguments) {
        if (arguments == null || arguments.trim().isEmpty()) {
            return new JSONObject();
        }
        try {
            return new JSONObject(arguments);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static void ensureToolReason(String toolName, JSONObject arguments)
            throws JSONException {
        if (arguments == null || !ToolCatalog.get().requiresReason(toolName)
                || arguments.optString("reason", "").trim().length() > 0) {
            return;
        }
        arguments.put("reason", "Gemini Live voice task step requested by the user.");
    }

    private static Object jsonCompatibleOutput(String output) {
        if (output == null || output.trim().isEmpty()) {
            return "";
        }
        String clean = output.trim();
        try {
            if (clean.startsWith("{")) {
                return new JSONObject(clean);
            }
            if (clean.startsWith("[")) {
                return new JSONArray(clean);
            }
        } catch (JSONException ignored) {
        }
        return output;
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
}
