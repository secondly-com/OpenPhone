package org.openphone.assistant.surface;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Immutable JSON-backed node from the bounded Adaptive Surface V1 registry. */
public final class SurfaceComponent {
    private final JSONObject mJson;

    private SurfaceComponent(JSONObject json) {
        mJson = copy(json);
    }

    public static SurfaceComponent fromJson(JSONObject json) {
        return json == null ? null : new SurfaceComponent(json);
    }

    public String type() {
        return mJson.optString("type", "");
    }

    public String string(String key) {
        return mJson.optString(key, "");
    }

    public boolean bool(String key, boolean fallback) {
        return mJson.has(key) ? mJson.optBoolean(key, fallback) : fallback;
    }

    public double number(String key, double fallback) {
        return mJson.has(key) ? mJson.optDouble(key, fallback) : fallback;
    }

    public JSONArray array(String key) {
        JSONArray value = mJson.optJSONArray(key);
        return value == null ? new JSONArray() : copy(value);
    }

    public JSONObject object(String key) {
        JSONObject value = mJson.optJSONObject(key);
        return value == null ? new JSONObject() : copy(value);
    }

    public JSONObject toJson() {
        return copy(mJson);
    }

    static JSONObject copy(JSONObject source) {
        try {
            return new JSONObject(source == null ? "{}" : source.toString());
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    static JSONArray copy(JSONArray source) {
        try {
            return new JSONArray(source == null ? "[]" : source.toString());
        } catch (JSONException e) {
            return new JSONArray();
        }
    }
}
