package org.openphone.assistant.surface;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.context.ContextIndexStore;

/** Durable, bounded surface lifecycle log plus context-index audit projection. */
public final class SurfaceEventLog {
    public static final String PRESENTED = "assistant.surface.presented";
    public static final String REPLACED = "assistant.surface.replaced";
    public static final String DISMISSED = "assistant.surface.dismissed";
    public static final String ACTION_INVOKED = "assistant.surface.action_invoked";
    public static final String ACTION_RESULT = "assistant.surface.action_result";
    public static final String REJECTED = "assistant.surface.rejected";

    private static final String PREFS = "openphone_surface_events";
    private static final String KEY_EVENTS = "events";
    private static final int MAX_EVENTS = 100;

    private final SharedPreferences mPrefs;
    private final ContextIndexStore mContextIndex;

    public SurfaceEventLog(Context context) {
        Context app = context.getApplicationContext();
        mPrefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        mContextIndex = new ContextIndexStore(app);
    }

    public synchronized void record(String event, AdaptiveSurface surface,
            String detail, JSONObject payload) {
        long now = System.currentTimeMillis();
        JSONObject eventJson = new JSONObject();
        try {
            eventJson.put("schema", "openphone.surface_event.v1")
                    .put("timestamp_ms", now)
                    .put("event", clean(event))
                    .put("surface_id", surface == null ? "" : surface.surfaceId)
                    .put("revision", surface == null ? 0 : surface.revision)
                    .put("session_id", surface == null ? "" : surface.sessionId)
                    .put("runtime", surface == null ? "" : surface.runtime)
                    .put("detail", clean(detail))
                    .put("payload", payload == null
                            ? new JSONObject() : SurfaceComponent.copy(payload));
        } catch (JSONException ignored) {
        }
        JSONArray existing = read();
        JSONArray next = new JSONArray().put(eventJson);
        for (int i = 0; i < existing.length() && next.length() < MAX_EVENTS; i++) {
            JSONObject item = existing.optJSONObject(i);
            if (item != null) {
                next.put(item);
            }
        }
        mPrefs.edit().putString(KEY_EVENTS, next.toString()).apply();
        mContextIndex.recordAgentEvent(
                clean(event),
                surface == null ? "Adaptive surface" : surface.title,
                clean(detail),
                surface == null ? "" : surface.sessionId,
                eventJson.toString());
    }

    public synchronized String listJson(int limit) {
        JSONArray source = read();
        JSONArray out = new JSONArray();
        for (int i = 0; i < source.length() && out.length() < Math.max(1, limit); i++) {
            out.put(source.opt(i));
        }
        return out.toString();
    }

    private JSONArray read() {
        try {
            return new JSONArray(mPrefs.getString(KEY_EVENTS, "[]"));
        } catch (JSONException e) {
            return new JSONArray();
        }
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
