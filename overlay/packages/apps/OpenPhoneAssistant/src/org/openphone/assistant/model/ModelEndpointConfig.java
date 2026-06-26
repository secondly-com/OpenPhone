package org.openphone.assistant.model;

import android.content.Context;
import android.content.SharedPreferences;
import android.provider.Settings;

public final class ModelEndpointConfig {
    public static final String PROVIDER_LOCAL_HEURISTIC = "local_heuristic";
    public static final String PROVIDER_OPENAI_RESPONSES = "openai_responses";
    public static final String PROVIDER_OPENAI_COMPATIBLE_CHAT = "openai_compatible_chat";
    public static final String PROVIDER_OLLAMA_CHAT = "ollama_chat";
    public static final String PROVIDER_QWEN_OMNI_REALTIME = "qwen_omni_realtime";
    public static final String PROVIDER_REMOTE_BROKER = "remote_broker";

    private static final String PREFS = "openphone_assistant";
    private static final String PREF_MODEL_PROVIDER = "model_provider";
    private static final String PREF_OPENAI_API_KEY = "model_openai_api_key";
    private static final String PREF_PROVIDER_BASE_URL = "model_provider_base_url";
    private static final String PREF_PROVIDER_MODEL_ID = "model_provider_model_id";
    private static final String PREF_PROVIDER_API_KEY = "model_provider_api_key";
    private static final String PREF_BROKER_URL = "model_broker_url";
    private static final String PREF_BROKER_TOKEN = "model_broker_token";
    private static final String SECURE_DEV_OPENAI_API_KEY = "openphone_dev_openai_api_key";

    private static final String OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
    private static final String OPENAI_TRANSCRIPTIONS_URL =
            "https://api.openai.com/v1/audio/transcriptions";

    private final String mProviderMode;
    private final String mBaseUrl;
    private final String mResponsesUrl;
    private final String mTranscriptionsUrl;
    private final String mBearerToken;
    private final String mModelName;

    private ModelEndpointConfig(String providerMode, String baseUrl, String responsesUrl,
            String transcriptionsUrl, String bearerToken, String modelName) {
        mProviderMode = cleanProviderMode(providerMode);
        mBaseUrl = baseUrl == null ? "" : baseUrl.trim();
        mResponsesUrl = responsesUrl == null ? "" : responsesUrl.trim();
        mTranscriptionsUrl = transcriptionsUrl == null ? "" : transcriptionsUrl.trim();
        mBearerToken = bearerToken == null ? "" : bearerToken.trim();
        mModelName = modelName == null ? "" : modelName.trim();
    }

    public static ModelEndpointConfig localHeuristic() {
        return new ModelEndpointConfig(PROVIDER_LOCAL_HEURISTIC, "", "", "", "", "");
    }

    public static ModelEndpointConfig directOpenAi(String apiKey) {
        return directOpenAi(apiKey, "");
    }

    public static ModelEndpointConfig directOpenAi(String apiKey, String modelName) {
        return new ModelEndpointConfig(PROVIDER_OPENAI_RESPONSES, "https://api.openai.com",
                OPENAI_RESPONSES_URL, OPENAI_TRANSCRIPTIONS_URL, apiKey, modelName);
    }

    public static ModelEndpointConfig broker(String baseUrl, String token) {
        return broker(baseUrl, token, "");
    }

    public static ModelEndpointConfig broker(String baseUrl, String token, String modelName) {
        String normalized = normalizeBaseUrl(baseUrl);
        if (normalized.isEmpty()) {
            return new ModelEndpointConfig(PROVIDER_REMOTE_BROKER, "", "", "", token,
                    modelName);
        }
        return new ModelEndpointConfig(PROVIDER_REMOTE_BROKER, normalized,
                normalized + "/v1/responses", normalized + "/v1/audio/transcriptions",
                token, modelName);
    }

    public static ModelEndpointConfig openAiCompatibleChat(String baseUrl, String apiKey,
            String modelName) {
        String raw = trimTrailingSlashes(baseUrl);
        if (raw.endsWith("/chat/completions")) {
            return new ModelEndpointConfig(PROVIDER_OPENAI_COMPATIBLE_CHAT,
                    raw.substring(0, raw.length() - "/chat/completions".length()),
                    raw, "", apiKey, modelName);
        }
        String normalized = normalizeBaseUrl(raw);
        if (normalized.isEmpty()) {
            return new ModelEndpointConfig(PROVIDER_OPENAI_COMPATIBLE_CHAT, "", "", "",
                    apiKey, modelName);
        }
        String v1 = normalized.endsWith("/v1") ? normalized : normalized + "/v1";
        return new ModelEndpointConfig(PROVIDER_OPENAI_COMPATIBLE_CHAT, normalized,
                v1 + "/chat/completions", "", apiKey, modelName);
    }

    public static ModelEndpointConfig qwenOmniRealtime(String baseUrl, String apiKey,
            String modelName) {
        String raw = trimTrailingSlashes(baseUrl);
        String httpBase = qwenOmniHttpBase(raw);
        if (httpBase.isEmpty()) {
            return new ModelEndpointConfig(PROVIDER_QWEN_OMNI_REALTIME, raw, "", "",
                    apiKey, modelName);
        }
        String v1 = httpBase.endsWith("/v1") ? httpBase : httpBase + "/v1";
        return new ModelEndpointConfig(PROVIDER_QWEN_OMNI_REALTIME, raw,
                v1 + "/chat/completions", "", apiKey, modelName);
    }

    public static ModelEndpointConfig ollamaChat(String baseUrl, String modelName) {
        String raw = trimTrailingSlashes(baseUrl);
        if (raw.endsWith("/api/chat")) {
            return new ModelEndpointConfig(PROVIDER_OLLAMA_CHAT,
                    raw.substring(0, raw.length() - "/api/chat".length()),
                    raw, "", "", modelName);
        }
        String normalized = normalizeBaseUrl(raw);
        if (normalized.isEmpty()) {
            return new ModelEndpointConfig(PROVIDER_OLLAMA_CHAT, "", "", "", "",
                    modelName);
        }
        String endpointBase = normalized.endsWith("/api")
                ? normalized.substring(0, normalized.length() - 4) : normalized;
        return new ModelEndpointConfig(PROVIDER_OLLAMA_CHAT, endpointBase,
                endpointBase + "/api/chat", "", "", modelName);
    }

    public static ModelEndpointConfig fromUiConfig(String providerMode, String openAiApiKey,
            String providerBaseUrl, String modelName, String providerApiKey,
            String brokerUrl, String brokerToken) {
        String clean = cleanProviderMode(providerMode);
        if (PROVIDER_OPENAI_RESPONSES.equals(clean)) {
            return directOpenAi(openAiApiKey, modelName);
        }
        if (PROVIDER_OPENAI_COMPATIBLE_CHAT.equals(clean)) {
            return openAiCompatibleChat(providerBaseUrl, providerApiKey, modelName);
        }
        if (PROVIDER_OLLAMA_CHAT.equals(clean)) {
            return ollamaChat(providerBaseUrl, modelName);
        }
        if (PROVIDER_QWEN_OMNI_REALTIME.equals(clean)) {
            return qwenOmniRealtime(providerBaseUrl, providerApiKey, modelName);
        }
        if (PROVIDER_REMOTE_BROKER.equals(clean)) {
            return broker(brokerUrl, brokerToken, modelName);
        }
        return localHeuristic();
    }

    public static StoredSettings readStoredSettings(Context context) {
        if (context == null) {
            return new StoredSettings("", "", "", "", "", "", "");
        }
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String providerMode = prefs.getString(PREF_MODEL_PROVIDER, "");
        String openAiApiKey = prefs.getString(PREF_OPENAI_API_KEY, "");
        if ((openAiApiKey == null || openAiApiKey.isEmpty())) {
            try {
                openAiApiKey = Settings.Secure.getString(context.getContentResolver(),
                        SECURE_DEV_OPENAI_API_KEY);
            } catch (SecurityException ignored) {
            }
        }
        return new StoredSettings(
                providerMode,
                openAiApiKey == null ? "" : openAiApiKey,
                prefs.getString(PREF_PROVIDER_BASE_URL, ""),
                prefs.getString(PREF_PROVIDER_MODEL_ID, ""),
                prefs.getString(PREF_PROVIDER_API_KEY, ""),
                prefs.getString(PREF_BROKER_URL, ""),
                prefs.getString(PREF_BROKER_TOKEN, ""));
    }

    public static void writeStoredSettings(Context context, String providerMode,
            String openAiApiKey, String providerBaseUrl, String modelName,
            String providerApiKey, String brokerUrl, String brokerToken) {
        if (context == null) {
            return;
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(PREF_MODEL_PROVIDER, cleanProviderMode(providerMode))
                .putString(PREF_OPENAI_API_KEY, openAiApiKey == null ? "" : openAiApiKey)
                .putString(PREF_PROVIDER_BASE_URL,
                        providerBaseUrl == null ? "" : providerBaseUrl)
                .putString(PREF_PROVIDER_MODEL_ID, modelName == null ? "" : modelName)
                .putString(PREF_PROVIDER_API_KEY,
                        providerApiKey == null ? "" : providerApiKey)
                .putString(PREF_BROKER_URL, brokerUrl == null ? "" : brokerUrl)
                .putString(PREF_BROKER_TOKEN, brokerToken == null ? "" : brokerToken)
                .apply();
    }

    public static ModelEndpointConfig fromStoredSettings(Context context) {
        StoredSettings settings = readStoredSettings(context);
        String providerMode = settings.providerMode;
        if ((providerMode == null || providerMode.isEmpty())
                && settings.openAiApiKey != null && !settings.openAiApiKey.isEmpty()) {
            providerMode = PROVIDER_OPENAI_RESPONSES;
        }
        return fromUiConfig(providerMode, settings.openAiApiKey, settings.providerBaseUrl,
                settings.modelName, settings.providerApiKey, settings.brokerUrl,
                settings.brokerToken);
    }

    public static String cleanProviderMode(String providerMode) {
        String value = providerMode == null ? "" : providerMode.trim();
        if (PROVIDER_OPENAI_RESPONSES.equals(value)
                || PROVIDER_OPENAI_COMPATIBLE_CHAT.equals(value)
                || PROVIDER_OLLAMA_CHAT.equals(value)
                || PROVIDER_QWEN_OMNI_REALTIME.equals(value)
                || PROVIDER_REMOTE_BROKER.equals(value)
                || PROVIDER_LOCAL_HEURISTIC.equals(value)) {
            return value;
        }
        return PROVIDER_LOCAL_HEURISTIC;
    }

    public boolean isBrokerMode() {
        return PROVIDER_REMOTE_BROKER.equals(mProviderMode);
    }

    public boolean isDirectOpenAiResponses() {
        return PROVIDER_OPENAI_RESPONSES.equals(mProviderMode);
    }

    public boolean isOpenAiCompatibleChat() {
        return PROVIDER_OPENAI_COMPATIBLE_CHAT.equals(mProviderMode)
                || PROVIDER_QWEN_OMNI_REALTIME.equals(mProviderMode);
    }

    public boolean isOllamaChat() {
        return PROVIDER_OLLAMA_CHAT.equals(mProviderMode);
    }

    public boolean isQwenOmniRealtime() {
        return PROVIDER_QWEN_OMNI_REALTIME.equals(mProviderMode);
    }

    public boolean isLocalHeuristic() {
        return PROVIDER_LOCAL_HEURISTIC.equals(mProviderMode);
    }

    public boolean supportsTranscription() {
        return isDirectOpenAiResponses() || isBrokerMode();
    }

    public boolean isConfigured() {
        if (isLocalHeuristic()) {
            return false;
        }
        if (isDirectOpenAiResponses() || isBrokerMode()) {
            return !mResponsesUrl.isEmpty() && !mBearerToken.isEmpty();
        }
        if (isOpenAiCompatibleChat()) {
            return !mResponsesUrl.isEmpty() && !mModelName.isEmpty();
        }
        if (isOllamaChat()) {
            return !mResponsesUrl.isEmpty() && !mModelName.isEmpty();
        }
        if (isQwenOmniRealtime()) {
            return !realtimeWebSocketUrl("").isEmpty() && !mModelName.isEmpty();
        }
        return false;
    }

    public String providerMode() {
        return mProviderMode;
    }

    public String baseUrl() {
        return mBaseUrl;
    }

    public String responsesUrl() {
        return mResponsesUrl;
    }

    public String transcriptionsUrl() {
        return mTranscriptionsUrl;
    }

    public String bearerToken() {
        return mBearerToken;
    }

    public String configuredModelName() {
        return mModelName;
    }

    public String modelNameOrDefault(String defaultModel) {
        return mModelName.isEmpty() ? (defaultModel == null ? "" : defaultModel) : mModelName;
    }

    public String realtimeWebSocketUrl(String defaultModel) {
        if (isDirectOpenAiResponses()) {
            return "wss://api.openai.com/v1/realtime?model="
                    + modelNameOrDefault(defaultModel);
        }
        if (isQwenOmniRealtime()) {
            return qwenOmniRealtimeUrl(mBaseUrl);
        }
        return "";
    }

    public String providerName() {
        if (isBrokerMode()) {
            return "openphone-remote-model-broker";
        }
        if (isOpenAiCompatibleChat()) {
            if (isQwenOmniRealtime()) {
                return "qwen-omni-realtime";
            }
            return "openai-compatible-chat";
        }
        if (isOllamaChat()) {
            return "ollama-chat";
        }
        if (isLocalHeuristic()) {
            return "local-heuristic-dev";
        }
        return "openai-responses-vision-dev";
    }

    public String providerDisplayName() {
        if (isBrokerMode()) {
            return "Remote OpenPhone model broker";
        }
        if (isOpenAiCompatibleChat()) {
            if (isQwenOmniRealtime()) {
                return "Qwen Omni realtime endpoint";
            }
            return "OpenAI-compatible endpoint";
        }
        if (isOllamaChat()) {
            return "Ollama endpoint";
        }
        if (isLocalHeuristic()) {
            return "Local heuristic";
        }
        return "OpenAI Responses vision";
    }

    public String privacyDisclosure() {
        if (isBrokerMode()) {
            return "Cloud task mode sends the goal, task-scoped screenshots, and UI metadata "
                    + "to the configured remote OpenPhone model broker while the task is active. "
                    + "Provider API keys stay server-side; the phone only holds a broker token "
                    + "for this session.";
        }
        if (isQwenOmniRealtime()) {
            return "Realtime omni mode streams mic audio, screen context, tool calls, and "
                    + "tool results directly from this phone to the configured Qwen Omni "
                    + "endpoint while the session is active. Provider credentials stay "
                    + "on-device and are not written to trajectories.";
        }
        if (isOpenAiCompatibleChat() || isOllamaChat()) {
            return "Network task mode sends the goal, task-scoped screenshots, and UI metadata "
                    + "directly from this phone to the configured model endpoint. Provider "
                    + "credentials stay on-device and are not written to trajectories.";
        }
        if (isLocalHeuristic()) {
            return "Runs on device without a network model request.";
        }
        return "Network task mode sends the goal, task-scoped screenshots, and UI metadata "
                + "directly from this phone to OpenAI while the task is active. The API key "
                + "stays on-device and is not written to trajectories.";
    }

    public String missingCredentialReason() {
        if (isBrokerMode()) {
            return mResponsesUrl.isEmpty() ? "missing_broker_url" : "missing_broker_token";
        }
        if (isOpenAiCompatibleChat() || isOllamaChat()) {
            if (mResponsesUrl.isEmpty()) {
                return "missing_model_endpoint";
            }
            return mModelName.isEmpty() ? "missing_model_id" : "model_unconfigured";
        }
        if (isLocalHeuristic()) {
            return "local_heuristic_selected";
        }
        return "missing_dev_api_key";
    }

    private static String normalizeBaseUrl(String baseUrl) {
        String value = trimTrailingSlashes(baseUrl);
        if (value.endsWith("/v1")) {
            value = value.substring(0, value.length() - 3);
        }
        return value;
    }

    private static String qwenOmniRealtimeUrl(String baseUrl) {
        String value = trimTrailingSlashes(baseUrl);
        if (value.isEmpty()) {
            return "";
        }
        String lower = value.toLowerCase();
        if (lower.startsWith("ws://") || lower.startsWith("wss://")) {
            if (lower.endsWith("/v1/realtime") || lower.endsWith("/realtime")) {
                return value;
            }
            if (lower.endsWith("/v1")) {
                return value + "/realtime";
            }
            return value + "/v1/realtime";
        }
        String httpBase = qwenOmniHttpBase(value);
        if (httpBase.isEmpty()) {
            return "";
        }
        String websocketBase;
        if (httpBase.toLowerCase().startsWith("https://")) {
            websocketBase = "wss://" + httpBase.substring("https://".length());
        } else if (httpBase.toLowerCase().startsWith("http://")) {
            websocketBase = "ws://" + httpBase.substring("http://".length());
        } else {
            websocketBase = "ws://" + httpBase;
        }
        return trimTrailingSlashes(websocketBase) + "/v1/realtime";
    }

    private static String qwenOmniHttpBase(String baseUrl) {
        String value = trimTrailingSlashes(baseUrl);
        String lower = value.toLowerCase();
        if (lower.endsWith("/v1/realtime")) {
            value = value.substring(0, value.length() - "/v1/realtime".length());
        } else if (lower.endsWith("/realtime")) {
            value = value.substring(0, value.length() - "/realtime".length());
        }
        lower = value.toLowerCase();
        if (lower.startsWith("wss://")) {
            value = "https://" + value.substring("wss://".length());
        } else if (lower.startsWith("ws://")) {
            value = "http://" + value.substring("ws://".length());
        }
        return normalizeBaseUrl(value);
    }

    private static String trimTrailingSlashes(String value) {
        String clean = value == null ? "" : value.trim();
        while (clean.endsWith("/")) {
            clean = clean.substring(0, clean.length() - 1);
        }
        return clean;
    }

    public static final class StoredSettings {
        public final String providerMode;
        public final String openAiApiKey;
        public final String providerBaseUrl;
        public final String modelName;
        public final String providerApiKey;
        public final String brokerUrl;
        public final String brokerToken;

        private StoredSettings(String providerMode, String openAiApiKey, String providerBaseUrl,
                String modelName, String providerApiKey, String brokerUrl,
                String brokerToken) {
            this.providerMode = providerMode == null ? "" : providerMode.trim();
            this.openAiApiKey = openAiApiKey == null ? "" : openAiApiKey;
            this.providerBaseUrl = providerBaseUrl == null ? "" : providerBaseUrl;
            this.modelName = modelName == null ? "" : modelName;
            this.providerApiKey = providerApiKey == null ? "" : providerApiKey;
            this.brokerUrl = brokerUrl == null ? "" : brokerUrl;
            this.brokerToken = brokerToken == null ? "" : brokerToken;
        }
    }
}
