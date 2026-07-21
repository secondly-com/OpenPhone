package org.openphone.assistant.surface;

import android.content.Context;

import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.actions.ActionRegistry;
import org.openphone.assistant.actions.ToolCatalog;
import org.openphone.assistant.platform.PhoneToolGateway;
import org.openphone.assistant.runtime.RuntimeIdentity;
import org.openphone.assistant.runtime.RuntimeConfirmationResolution;
import org.openphone.assistant.runtime.RuntimeToolBridge;
import org.openphone.assistant.runtime.RuntimeToolRequest;
import org.openphone.assistant.runtime.RuntimeToolResult;

import java.util.Iterator;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Resolves a revision-bound action then delegates to RuntimeToolBridge.
 *
 * The renderer never executes intents, framework actions, or runtime code
 * directly. Existing policy, confirmation, grants, idempotency, and audit
 * behavior therefore remain authoritative.
 */
public final class SurfaceActionDispatcher {
    private final SurfaceRepository mRepository;
    private final SurfaceEventLog mEvents;
    private final RuntimeToolBridge mToolBridge;
    private final Context mContext;
    private final Map<String, PendingSurfaceAction> mPending = new HashMap<>();

    public SurfaceActionDispatcher(Context context, PhoneToolGateway phoneGateway) {
        Context app = context.getApplicationContext();
        mContext = app;
        mRepository = new SurfaceRepository(app);
        mEvents = new SurfaceEventLog(app);
        mToolBridge = phoneGateway == null || !phoneGateway.isAvailable()
                ? null : new RuntimeToolBridge(app, phoneGateway);
    }

    public synchronized SurfaceActionResult invoke(String surfaceId, int revision,
            String actionId, JSONObject input, String idempotencyKey) {
        SurfaceMutationResult resolved =
                mRepository.resolveInvocation(surfaceId, revision, actionId);
        if (!resolved.ok || resolved.surface == null) {
            return SurfaceActionResult.error(resolved.code, resolved.message);
        }
        AdaptiveSurface surface = resolved.surface;
        SurfaceAction action = surface.actions.get(clean(actionId));
        if (action == null) {
            return SurfaceActionResult.error("action_not_found", "Surface action was not found.");
        }
        if (mToolBridge == null) {
            return SurfaceActionResult.error(
                    "agent_service_unavailable", "OpenPhone agent service is unavailable.");
        }
        JSONObject params = SurfaceComponent.copy(action.params);
        SurfaceActionResult inputResult = mergeValidatedInput(action.tool, params, input);
        if (inputResult != null) {
            return inputResult;
        }
        try {
            params.put("reason", action.reason)
                    .put("_surface_id", surface.surfaceId)
                    .put("_surface_revision", surface.revision)
                    .put("_surface_action_id", action.id);
        } catch (JSONException e) {
            return SurfaceActionResult.error("params_invalid", "Could not bind surface action.");
        }
        String key = clean(idempotencyKey);
        if (key.isEmpty()) {
            key = "surface:" + surface.surfaceId + ":" + surface.revision
                    + ":" + action.id + ":" + UUID.randomUUID();
        }
        RuntimeToolRequest request = new RuntimeToolRequest(
                "surface-request-" + UUID.randomUUID(),
                surface.runtime,
                "surface:" + surface.sessionId,
                surface.sessionId,
                new RuntimeIdentity(surface.runtime, "phone_surface", surface.runtime),
                action.tool,
                params,
                action.reason,
                "confirm",
                key,
                30000L,
                "");
        JSONObject eventPayload = new JSONObject();
        try {
            eventPayload.put("action_id", action.id)
                    .put("tool", action.tool)
                    .put("idempotency_key", key);
        } catch (JSONException ignored) {
        }
        mEvents.record(SurfaceEventLog.ACTION_INVOKED, surface,
                "Invoked " + action.label, eventPayload);
        SurfaceRuntimeNotifier.actionInvoked(mContext, surface, action.id, key);
        RuntimeToolResult runtimeResult = mToolBridge.execute(request);
        SurfaceActionResult result = SurfaceActionResult.fromRuntime(runtimeResult);
        String confirmationId = result.result.optString("confirmation_id", "");
        if (!confirmationId.isEmpty()) {
            mPending.put(confirmationId, new PendingSurfaceAction(surface, action.id));
        }
        mEvents.record(SurfaceEventLog.ACTION_RESULT, surface,
                result.status + (result.code.isEmpty() ? "" : ": " + result.code),
                result.toJson());
        SurfaceRuntimeNotifier.actionResult(mContext, surface, action.id, result);
        return result;
    }

    public synchronized SurfaceActionResult resolveConfirmation(
            String confirmationId, boolean approved) {
        if (mToolBridge == null) {
            return SurfaceActionResult.error(
                    "agent_service_unavailable", "OpenPhone agent service is unavailable.");
        }
        RuntimeConfirmationResolution resolution =
                mToolBridge.resolveConfirmation(clean(confirmationId), approved);
        if (resolution == null || resolution.result() == null) {
            return SurfaceActionResult.error(
                    "confirmation_result_missing", "Confirmation returned no result.");
        }
        SurfaceActionResult result = SurfaceActionResult.fromRuntime(resolution.result());
        PendingSurfaceAction pending = mPending.remove(clean(confirmationId));
        if (pending != null) {
            SurfaceRuntimeNotifier.actionResult(
                    mContext, pending.surface, pending.actionId, result);
        }
        return result;
    }

    private static SurfaceActionResult mergeValidatedInput(String tool, JSONObject params,
            JSONObject input) {
        if (input == null || input.length() == 0) {
            return null;
        }
        if (input.length() > 16) {
            return SurfaceActionResult.error("input_too_large", "Surface input has too many keys.");
        }
        ActionRegistry.ActionMetadata metadata = null;
        for (ActionRegistry.ActionMetadata candidate : ToolCatalog.get().tools()) {
            if (tool.equals(candidate.modelTool)) {
                metadata = candidate;
                break;
            }
        }
        if (metadata == null) {
            return SurfaceActionResult.error("tool_metadata_missing", "Tool metadata is missing.");
        }
        JSONObject properties = metadata.inputSchema.optJSONObject("properties");
        Iterator<String> keys = input.keys();
        try {
            while (keys.hasNext()) {
                String key = keys.next();
                if (key.startsWith("_") || "reason".equals(key)
                        || properties == null || !properties.has(key)) {
                    return SurfaceActionResult.error(
                            "input_key_invalid", "Surface input key is not allowed: " + key);
                }
                params.put(key, input.opt(key));
            }
        } catch (JSONException e) {
            return SurfaceActionResult.error("input_invalid", "Could not merge surface input.");
        }
        return null;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    private static final class PendingSurfaceAction {
        final AdaptiveSurface surface;
        final String actionId;

        PendingSurfaceAction(AdaptiveSurface surface, String actionId) {
            this.surface = surface;
            this.actionId = actionId;
        }
    }
}
