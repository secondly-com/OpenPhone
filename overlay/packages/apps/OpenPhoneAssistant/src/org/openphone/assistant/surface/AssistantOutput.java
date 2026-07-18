package org.openphone.assistant.surface;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

/** Explicit runtime-neutral assistant output envelope. */
public final class AssistantOutput {
    public static final String SCHEMA = "openphone.assistant_output.v1";

    public final String sessionId;
    public final String speech;
    public final String text;
    public final AdaptiveSurface surface;
    public final JSONObject backgroundRun;

    private final JSONObject mJson;

    private AssistantOutput(JSONObject json, String sessionId, String speech, String text,
            AdaptiveSurface surface, JSONObject backgroundRun) {
        mJson = SurfaceComponent.copy(json);
        this.sessionId = clean(sessionId);
        this.speech = clean(speech);
        this.text = clean(text);
        this.surface = surface;
        this.backgroundRun = SurfaceComponent.copy(backgroundRun);
    }

    /**
     * Parses only an object already identified as an output envelope.
     * Callers must never pass arbitrary assistant prose here.
     */
    public static AssistantOutput fromJson(JSONObject json) {
        if (json == null || !SCHEMA.equals(json.optString("schema", ""))) {
            return null;
        }
        Set<String> allowed = new HashSet<>(Arrays.asList(
                "schema", "session_id", "speech", "text", "surface", "background_run"));
        Iterator<String> keys = json.keys();
        while (keys.hasNext()) {
            if (!allowed.contains(keys.next())) {
                return null;
            }
        }
        if (!(json.opt("session_id") instanceof String)
                || !(json.opt("speech") instanceof String)
                || !(json.opt("text") instanceof String)) {
            return null;
        }
        String sessionId = clean(json.optString("session_id", ""));
        String speech = clean(json.optString("speech", ""));
        String text = clean(json.optString("text", ""));
        if (sessionId.isEmpty() || sessionId.length() > 160
                || speech.length() > 4000 || text.length() > 12000) {
            return null;
        }
        AdaptiveSurface surface = AdaptiveSurface.fromJson(json.optJSONObject("surface"));
        if (json.has("surface") && !JSONObject.NULL.equals(json.opt("surface"))
                && surface == null) {
            return null;
        }
        if (surface != null && !sessionId.equals(surface.sessionId)) {
            return null;
        }
        Object background = json.opt("background_run");
        if (background != null && !JSONObject.NULL.equals(background)
                && !(background instanceof JSONObject)) {
            return null;
        }
        return new AssistantOutput(
                json,
                sessionId,
                speech,
                text,
                surface,
                background instanceof JSONObject ? (JSONObject) background : new JSONObject());
    }

    public static AssistantOutput builtin(String sessionId, String speech, String text,
            AdaptiveSurface surface) {
        JSONObject out = new JSONObject();
        try {
            out.put("schema", SCHEMA)
                    .put("session_id", clean(sessionId))
                    .put("speech", clean(speech))
                    .put("text", clean(text))
                    .put("surface", surface == null ? JSONObject.NULL : surface.toJson())
                    .put("background_run", JSONObject.NULL);
        } catch (JSONException ignored) {
        }
        return fromJson(out);
    }

    public JSONObject toJson() {
        return SurfaceComponent.copy(mJson);
    }

    public String displayText() {
        return text.isEmpty() ? speech : text;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
