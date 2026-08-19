package org.openphone.assistant.platform;

import org.json.JSONObject;

/**
 * Capability boundary between portable OpenPhone product logic and the phone
 * implementation that executes tools.
 *
 * <p>The runtime and adaptive-surface layers depend only on this contract.
 * OpenPhone OS supplies a framework-backed implementation; a Play-distributed
 * build can supply a public-API implementation with a smaller capability set.
 */
public interface PhoneToolGateway {
    /** Stable implementation profile exposed for diagnostics. */
    String profile();

    /** Whether this implementation can currently accept phone work. */
    boolean isAvailable();

    /** Whether this implementation supports the registered tool. */
    boolean supportsTool(String toolName);

    /** Starts a policy-scoped phone task and returns its JSON result. */
    String startTask(String taskJson);

    /** Executes one registered phone tool and returns its JSON result. */
    String executeTool(String taskId, String toolName, JSONObject arguments);

    /** Resolves an OS-owned pending action and returns its JSON result. */
    String confirmAction(String pendingActionId, boolean approved);
}
