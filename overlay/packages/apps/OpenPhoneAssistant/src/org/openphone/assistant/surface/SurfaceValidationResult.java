package org.openphone.assistant.surface;

/** Fail-closed validation result with a stable machine-readable error code. */
public final class SurfaceValidationResult {
    public final boolean valid;
    public final String code;
    public final String message;

    private SurfaceValidationResult(boolean valid, String code, String message) {
        this.valid = valid;
        this.code = clean(code);
        this.message = clean(message);
    }

    public static SurfaceValidationResult ok() {
        return new SurfaceValidationResult(true, "ok", "");
    }

    public static SurfaceValidationResult reject(String code, String message) {
        return new SurfaceValidationResult(false, code, message);
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
