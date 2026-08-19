package org.openphone.assistant.platform;

import android.content.Context;
import android.openphone.OpenPhoneAgentManager;

import org.json.JSONObject;
import org.openphone.assistant.agent.FrameworkToolExecutor;

/** OpenPhone OS implementation of the portable phone-tool boundary. */
public final class OpenPhoneOsToolGateway implements PhoneToolGateway {
    public static final String PROFILE = "openphone_os";

    private final OpenPhoneAgentManager mAgentManager;
    private final FrameworkToolExecutor mToolExecutor;

    public OpenPhoneOsToolGateway(Context context, OpenPhoneAgentManager agentManager) {
        Context app = context.getApplicationContext();
        mAgentManager = agentManager;
        mToolExecutor = new FrameworkToolExecutor(app, agentManager);
    }

    @Override
    public String profile() {
        return PROFILE;
    }

    @Override
    public boolean isAvailable() {
        return mAgentManager != null;
    }

    @Override
    public boolean supportsTool(String toolName) {
        return isAvailable() && toolName != null && !toolName.trim().isEmpty();
    }

    @Override
    public String startTask(String taskJson) {
        if (!isAvailable()) {
            return unavailable();
        }
        return mAgentManager.startTask(taskJson);
    }

    @Override
    public String executeTool(String taskId, String toolName, JSONObject arguments) {
        if (!isAvailable()) {
            return unavailable();
        }
        return mToolExecutor.execute(taskId, toolName, arguments);
    }

    @Override
    public String confirmAction(String pendingActionId, boolean approved) {
        if (!isAvailable()) {
            return unavailable();
        }
        return mAgentManager.confirmAction(pendingActionId, approved);
    }

    private static String unavailable() {
        return "{\"error\":\"phone_platform_unavailable\"}";
    }
}
