package org.openphone.assistant.surface;

import org.json.JSONException;
import org.json.JSONObject;

/** A declarative action binding. Execution always goes through the phone tool bridge. */
public final class SurfaceAction {
    public final String id;
    public final String label;
    public final String tool;
    public final JSONObject params;
    public final String reason;
    public final boolean requiresConfirmation;

    public SurfaceAction(String id, String label, String tool, JSONObject params,
            String reason, boolean requiresConfirmation) {
        this.id = clean(id);
        this.label = clean(label);
        this.tool = clean(tool);
        this.params = SurfaceComponent.copy(params);
        this.reason = clean(reason);
        this.requiresConfirmation = requiresConfirmation;
    }

    public static SurfaceAction fromJson(String id, JSONObject json) {
        if (json == null) {
            return null;
        }
        return new SurfaceAction(
                id,
                json.optString("label", ""),
                json.optString("tool", ""),
                json.optJSONObject("params"),
                json.optString("reason", ""),
                json.optBoolean("requires_confirmation", false));
    }

    public JSONObject toJson() {
        JSONObject out = new JSONObject();
        try {
            out.put("label", label)
                    .put("tool", tool)
                    .put("params", SurfaceComponent.copy(params))
                    .put("reason", reason);
            if (requiresConfirmation) {
                out.put("requires_confirmation", true);
            }
        } catch (JSONException ignored) {
        }
        return out;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
