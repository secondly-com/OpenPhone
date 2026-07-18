package org.openphone.assistant.surface;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.UUID;

/**
 * Small metadata/data store for trusted tool artifacts referenced by surfaces.
 *
 * It deliberately does not fetch URLs. Artifacts are created by phone tools,
 * session-bound, sensitivity-labelled, and expire independently.
 */
public final class SurfaceArtifactStore {
    private static final String PREFS = "openphone_surface_artifacts";
    private static final String KEY_ARTIFACTS = "artifacts";
    private static final int MAX_ARTIFACTS = 64;

    private final SharedPreferences mPrefs;

    public SurfaceArtifactStore(Context context) {
        mPrefs = context.getApplicationContext().getSharedPreferences(
                PREFS, Context.MODE_PRIVATE);
    }

    public synchronized String put(String sessionId, String runtime, String tool,
            String capability, String sensitivity, JSONObject data, long expiresAtMillis) {
        String cleanSession = clean(sessionId);
        if (cleanSession.isEmpty() || data == null) {
            return "";
        }
        long now = System.currentTimeMillis();
        String id = "artifact-" + UUID.randomUUID();
        JSONObject artifact = new JSONObject();
        try {
            artifact.put("artifact_id", id)
                    .put("session_id", cleanSession)
                    .put("runtime", clean(runtime))
                    .put("tool", clean(tool))
                    .put("capability", clean(capability))
                    .put("sensitivity", clean(sensitivity))
                    .put("created_at", now)
                    .put("expires_at", expiresAtMillis)
                    .put("data", SurfaceComponent.copy(data));
        } catch (JSONException e) {
            return "";
        }
        JSONArray stored = read();
        JSONArray next = new JSONArray().put(artifact);
        for (int i = 0; i < stored.length() && next.length() < MAX_ARTIFACTS; i++) {
            JSONObject item = stored.optJSONObject(i);
            if (item == null || expired(item, now)) {
                continue;
            }
            next.put(item);
        }
        return write(next) ? id : "";
    }

    public synchronized JSONObject metadata(String artifactId) {
        long now = System.currentTimeMillis();
        JSONArray artifacts = read();
        for (int i = 0; i < artifacts.length(); i++) {
            JSONObject item = artifacts.optJSONObject(i);
            if (item != null && clean(artifactId).equals(item.optString("artifact_id", ""))
                    && !expired(item, now)) {
                return SurfaceComponent.copy(item);
            }
        }
        return null;
    }

    public synchronized boolean belongsToSession(String artifactId, String sessionId) {
        JSONObject artifact = metadata(artifactId);
        return artifact != null
                && clean(sessionId).equals(artifact.optString("session_id", ""));
    }

    private JSONArray read() {
        try {
            return new JSONArray(mPrefs.getString(KEY_ARTIFACTS, "[]"));
        } catch (JSONException e) {
            return new JSONArray();
        }
    }

    private boolean write(JSONArray artifacts) {
        return mPrefs.edit().putString(KEY_ARTIFACTS, artifacts.toString()).commit();
    }

    private static boolean expired(JSONObject artifact, long now) {
        long expiresAt = artifact.optLong("expires_at", 0L);
        return expiresAt > 0L && expiresAt <= now;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
