package org.openphone.assistant.model;

public final class QwenOmniRealtimeSession implements MultimodalSession {
    public static final String DEFAULT_MODEL = "Qwen/Qwen3-Omni-30B-A3B-Instruct";

    private static final String PROVIDER_LABEL = "Qwen Omni realtime";
    private static final String STATUS_LABEL = "Qwen Omni";
    private static final int INPUT_SAMPLE_RATE = 16000;
    private static final int OUTPUT_SAMPLE_RATE = 24000;

    private final OpenAiRealtimeVoiceSession mDelegate;

    public QwenOmniRealtimeSession(ModelEndpointConfig endpointConfig,
            String continuityContextJson, boolean fullYolo) {
        ModelEndpointConfig config = endpointConfig == null
                ? ModelEndpointConfig.qwenOmniRealtime("", "", "") : endpointConfig;
        mDelegate = new OpenAiRealtimeVoiceSession(config, PROVIDER_LABEL, STATUS_LABEL,
                config.modelNameOrDefault(DEFAULT_MODEL),
                config.realtimeWebSocketUrl(DEFAULT_MODEL),
                INPUT_SAMPLE_RATE, OUTPUT_SAMPLE_RATE, true, continuityContextJson, fullYolo);
    }

    @Override
    public String providerDisplayName() {
        return mDelegate.providerDisplayName();
    }

    @Override
    public String modelName() {
        return mDelegate.modelName();
    }

    @Override
    public String privacyDisclosure() {
        return mDelegate.privacyDisclosure();
    }

    @Override
    public void run(String taskId, ModelAdapter.ToolExecutor executor, Callback callback) {
        mDelegate.run(taskId, executor, callback);
    }

    @Override
    public void cancel() {
        mDelegate.cancel();
    }
}
