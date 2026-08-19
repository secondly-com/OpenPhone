package org.openphone.assistant.surface;

import android.content.Context;
import android.content.Intent;

import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.OpenPhoneAssistantService;

/** Sends local renderer lifecycle/action results to the owning runtime service. */
public final class SurfaceRuntimeNotifier {
    private SurfaceRuntimeNotifier() {
    }

    public static void actionInvoked(Context context, AdaptiveSurface surface,
            String actionId, String idempotencyKey) {
        JSONObject payload = base(surface);
        try {
            payload.put("action_id", clean(actionId))
                    .put("idempotency_key", clean(idempotencyKey));
        } catch (JSONException ignored) {
        }
        send(context, surface, "phone.surface.action_invoked", payload);
    }

    public static void actionResult(Context context, AdaptiveSurface surface,
            String actionId, SurfaceActionResult result) {
        JSONObject payload = base(surface);
        try {
            payload.put("action_id", clean(actionId))
                    .put("status", result == null ? "error" : result.status)
                    .put("message", result == null ? "" : result.message)
                    .put("result", result == null ? new JSONObject() : result.toJson());
        } catch (JSONException ignored) {
        }
        send(context, surface, "runtime.surface.action_result", payload);
    }

    public static void dismissed(Context context, AdaptiveSurface surface, String reason) {
        JSONObject payload = base(surface);
        try {
            payload.put("reason", clean(reason));
        } catch (JSONException ignored) {
        }
        send(context, surface, "phone.surface.dismissed", payload);
    }

    private static JSONObject base(AdaptiveSurface surface) {
        JSONObject payload = new JSONObject();
        try {
            payload.put("surface_id", surface == null ? "" : surface.surfaceId)
                    .put("revision", surface == null ? 0 : surface.revision)
                    .put("session_id", surface == null ? "" : surface.sessionId)
                    .put("runtime", surface == null ? "" : surface.runtime);
        } catch (JSONException ignored) {
        }
        return payload;
    }

    private static void send(Context context, AdaptiveSurface surface,
            String event, JSONObject payload) {
        if (context == null || surface == null || "builtin".equals(surface.runtime)) {
            return;
        }
        Intent intent = new Intent(context, OpenPhoneAssistantService.class)
                .setAction(OpenPhoneAssistantService.ACTION_RUNTIME_SURFACE_EVENT)
                .putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_SURFACE_RUNTIME, surface.runtime)
                .putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_SURFACE_EVENT, event)
                .putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_SURFACE_PAYLOAD,
                        payload.toString());
        try {
            context.startService(intent);
        } catch (RuntimeException ignored) {
        }
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
