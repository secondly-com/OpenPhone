package org.openphone.assistant.runtime;

import org.json.JSONObject;
import org.openphone.assistant.surface.AssistantOutput;

public interface RuntimeCallback {
    void onRuntimeMessage(String runtime, String sessionKey, String message, boolean terminal);

    default void onRuntimeOutput(String runtime, String sessionKey,
            AssistantOutput output, boolean terminal) {
        if (output != null && !output.displayText().isEmpty()) {
            onRuntimeMessage(runtime, sessionKey, output.displayText(), terminal);
        }
    }

    default void onRuntimeSurfaceEvent(String runtime, String sessionKey,
            String event, JSONObject payload) {
    }
}
