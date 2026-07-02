package org.openphone.assistant.agent;

import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.policy.AuditLog;
import org.openphone.assistant.policy.PolicyDecision;
import org.openphone.assistant.policy.PolicyEngine;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

public final class ActionExecution {
    private static final String TAG = "OpenPhoneAction";

    /**
     * Sentinel capability id returned when we cannot confidently determine the
     * capability for an action. {@link PolicyEngine} treats unknown ids as
     * DENY, so this fails closed instead of silently downgrading to
     * {@code input.perform} (which is only MEDIUM risk).
     */
    private static final String CAPABILITY_UNKNOWN = "unknown";

    /**
     * Authoritative mapping from action-request {@code type} to the capability
     * id that gates it. Keep this consistent with
     * {@code schemas/action-request.schema.json} and the framework patch
     * stack. Any new action type MUST be added here (and to the PolicyEngine
     * registry); otherwise it fails closed.
     */
    private static final Map<String, String> TYPE_TO_CAPABILITY = buildTypeToCapability();

    private final PolicyEngine mPolicyEngine;
    private final AuditLog mAuditLog;

    public ActionExecution(PolicyEngine policyEngine, AuditLog auditLog) {
        mPolicyEngine = policyEngine;
        mAuditLog = auditLog;
    }

    public String execute(String taskId, String actionRequestJson) {
        String capabilityId = capabilityFromAction(actionRequestJson);
        PolicyDecision decision = mPolicyEngine.evaluate(capabilityId);
        mAuditLog.recordPolicyDecision(capabilityId, decision);

        switch (decision.action()) {
            case ALLOW_TASK_SCOPED:
                mAuditLog.recordAction(taskId, "action_executed", capabilityId);
                return "{\"status\":\"executed\",\"capability\":\"" + capabilityId + "\"}";
            case REQUIRE_CONFIRMATION:
            case REQUIRE_EXPLICIT_CONFIRMATION:
                mAuditLog.recordAction(taskId, "action_blocked", capabilityId);
                return "{\"status\":\"confirmation_required\",\"decision\":\""
                        + decision.toWireString() + "\"}";
            case DENY:
            default:
                mAuditLog.recordAction(taskId, "action_blocked", capabilityId);
                return "{\"status\":\"denied\",\"decision\":\"" + decision.toWireString() + "\"}";
        }
    }

    /**
     * Derive the capability id for an action-request JSON blob. Parses the
     * JSON properly (never substring-matches, which allowed capability
     * downgrade via nested payload fields) and only trusts the top-level
     * {@code type} field. Unknown / malformed input returns
     * {@link #CAPABILITY_UNKNOWN}, which the PolicyEngine denies.
     */
    private String capabilityFromAction(String actionRequestJson) {
        if (actionRequestJson == null || actionRequestJson.isEmpty()) {
            Log.w(TAG, "capabilityFromAction: empty action request; failing closed");
            return CAPABILITY_UNKNOWN;
        }
        JSONObject root;
        try {
            root = new JSONObject(actionRequestJson);
        } catch (JSONException parseError) {
            Log.w(TAG, "capabilityFromAction: JSON parse failed; failing closed", parseError);
            return CAPABILITY_UNKNOWN;
        }
        String type = root.optString("type", "");
        if (type.isEmpty()) {
            Log.w(TAG, "capabilityFromAction: action request missing type; failing closed");
            return CAPABILITY_UNKNOWN;
        }
        String capability = TYPE_TO_CAPABILITY.get(type);
        if (capability == null) {
            Log.w(TAG, "capabilityFromAction: unknown action type=" + type + "; failing closed");
            return CAPABILITY_UNKNOWN;
        }
        return capability;
    }

    private static Map<String, String> buildTypeToCapability() {
        // Preserves the previous string-contains inference for the known-good
        // happy path: open_app -> apps.launch, back/home/recents ->
        // input.perform. Synthetic touch/type events also route to
        // input.perform (the original code fell through to input.perform for
        // them). Anything else now fails closed via CAPABILITY_UNKNOWN rather
        // than silently defaulting to input.perform — see issue #65 for the
        // authoritative-registry-lookup follow-up.
        Map<String, String> map = new HashMap<>();
        map.put("open_app", "apps.launch");
        map.put("back", "input.perform");
        map.put("home", "input.perform");
        map.put("recents", "input.perform");
        map.put("tap", "input.perform");
        map.put("long_press", "input.perform");
        map.put("scroll", "input.perform");
        map.put("type_text", "input.perform");
        map.put("notification_action", "input.perform");
        return Collections.unmodifiableMap(map);
    }
}

