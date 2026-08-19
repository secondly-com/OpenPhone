package org.openphone.assistant.surface;

/** Result for repository lifecycle operations. */
public final class SurfaceMutationResult {
    public final boolean ok;
    public final String code;
    public final String message;
    public final AdaptiveSurface surface;

    private SurfaceMutationResult(boolean ok, String code, String message,
            AdaptiveSurface surface) {
        this.ok = ok;
        this.code = clean(code);
        this.message = clean(message);
        this.surface = surface;
    }

    public static SurfaceMutationResult ok(String code, AdaptiveSurface surface) {
        return new SurfaceMutationResult(true, code, "", surface);
    }

    public static SurfaceMutationResult error(String code, String message) {
        return new SurfaceMutationResult(false, code, message, null);
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
