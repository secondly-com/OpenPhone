package org.openphone.assistant.model;

public interface MultimodalSession {
    String providerDisplayName();
    String modelName();
    String privacyDisclosure();
    void run(String taskId, ModelAdapter.ToolExecutor executor, Callback callback);
    void cancel();

    interface Callback {
        void onStatus(String status);
        void onUserTranscript(String transcript);
        void onAssistantTranscript(String transcript);
        void onToolCall(String toolName);
        void onToolResult(String toolName, String resultJson);
        void onError(String message);
        void onStopped();
    }
}
