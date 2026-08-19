package org.openphone.assistant.surface;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** Parsed, immutable phone-owned Adaptive Surface V1 document. */
public final class AdaptiveSurface {
    public static final String SCHEMA = "openphone.surface.v1";

    public final String surfaceId;
    public final int revision;
    public final String sessionId;
    public final String runtime;
    public final String title;
    public final String presentation;
    public final long expiresAtMillis;
    public final String sensitivity;
    public final long createdAtMillis;
    public final SurfaceComponent body;
    public final Map<String, SurfaceAction> actions;
    public final JSONArray artifacts;

    private final JSONObject mJson;

    private AdaptiveSurface(JSONObject json, String surfaceId, int revision, String sessionId,
            String runtime, String title, String presentation, long expiresAtMillis,
            String sensitivity, long createdAtMillis, SurfaceComponent body,
            Map<String, SurfaceAction> actions, JSONArray artifacts) {
        mJson = SurfaceComponent.copy(json);
        this.surfaceId = clean(surfaceId);
        this.revision = revision;
        this.sessionId = clean(sessionId);
        this.runtime = clean(runtime);
        this.title = clean(title);
        this.presentation = clean(presentation);
        this.expiresAtMillis = expiresAtMillis;
        this.sensitivity = clean(sensitivity);
        this.createdAtMillis = createdAtMillis;
        this.body = body;
        this.actions = Collections.unmodifiableMap(actions);
        this.artifacts = SurfaceComponent.copy(artifacts);
    }

    public static AdaptiveSurface fromJson(String raw) {
        if (raw == null || raw.trim().isEmpty()) {
            return null;
        }
        try {
            return fromJson(new JSONObject(raw));
        } catch (JSONException e) {
            return null;
        }
    }

    public static AdaptiveSurface fromJson(JSONObject json) {
        if (json == null) {
            return null;
        }
        JSONObject actionsJson = json.optJSONObject("actions");
        Map<String, SurfaceAction> actions = new LinkedHashMap<>();
        if (actionsJson != null) {
            JSONArray names = actionsJson.names();
            if (names != null) {
                for (int i = 0; i < names.length(); i++) {
                    String id = names.optString(i, "");
                    SurfaceAction action = SurfaceAction.fromJson(
                            id, actionsJson.optJSONObject(id));
                    if (action != null) {
                        actions.put(id, action);
                    }
                }
            }
        }
        JSONArray artifacts = json.optJSONArray("artifacts");
        if (artifacts == null) {
            artifacts = new JSONArray();
        }
        return new AdaptiveSurface(
                json,
                json.optString("surface_id", ""),
                json.optInt("revision", 0),
                json.optString("session_id", ""),
                json.optString("runtime", ""),
                json.optString("title", ""),
                json.optString("presentation", ""),
                json.optLong("expires_at", 0L),
                json.optString("sensitivity", ""),
                json.optLong("created_at", 0L),
                SurfaceComponent.fromJson(json.optJSONObject("body")),
                actions,
                artifacts);
    }

    public JSONObject toJson() {
        return SurfaceComponent.copy(mJson);
    }

    public boolean isExpired(long nowMillis) {
        return expiresAtMillis > 0L && expiresAtMillis <= nowMillis;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
