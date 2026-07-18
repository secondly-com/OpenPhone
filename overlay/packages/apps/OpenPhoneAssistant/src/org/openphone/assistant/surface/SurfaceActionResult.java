package org.openphone.assistant.surface;

import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.runtime.RuntimeToolResult;

/** Result returned to the renderer/runtime after a bound surface action. */
public final class SurfaceActionResult {
    public final String status;
    public final String code;
    public final String message;
    public final JSONObject result;

    private SurfaceActionResult(String status, String code, String message, JSONObject result) {
        this.status = clean(status);
        this.code = clean(code);
        this.message = clean(message);
        this.result = SurfaceComponent.copy(result);
    }

    public static SurfaceActionResult fromRuntime(RuntimeToolResult result) {
        if (result == null) {
            return error("runtime_result_missing", "Phone tool returned no result.");
        }
        return new SurfaceActionResult(
                result.status(), result.errorCode(), result.errorMessage(), result.result());
    }

    public static SurfaceActionResult error(String code, String message) {
        return new SurfaceActionResult("error", code, message, new JSONObject());
    }

    public JSONObject toJson() {
        JSONObject out = new JSONObject();
        try {
            out.put("status", status)
                    .put("code", code)
                    .put("message", message)
                    .put("result", SurfaceComponent.copy(result));
        } catch (JSONException ignored) {
        }
        return out;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
