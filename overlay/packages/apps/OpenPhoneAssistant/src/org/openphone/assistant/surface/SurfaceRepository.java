package org.openphone.assistant.surface;

import android.app.KeyguardManager;
import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Revisioned durable repository for phone-validated adaptive surfaces. */
public final class SurfaceRepository {
    private static final String PREFS = "openphone_adaptive_surfaces";
    private static final String KEY_ENTRIES = "entries";
    private static final int MAX_ENTRIES = 16;

    private final SharedPreferences mPrefs;
    private final SurfaceValidator mValidator;
    private final SurfaceEventLog mEvents;
    private final KeyguardManager mKeyguard;

    public SurfaceRepository(Context context) {
        Context app = context.getApplicationContext();
        mPrefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        mValidator = new SurfaceValidator(app);
        mEvents = new SurfaceEventLog(app);
        mKeyguard = app.getSystemService(KeyguardManager.class);
    }

    public synchronized SurfaceMutationResult present(AdaptiveSurface surface) {
        SurfaceValidationResult validation = mValidator.validate(surface);
        if (!validation.valid) {
            mEvents.record(SurfaceEventLog.REJECTED, surface,
                    validation.code + ": " + validation.message, null);
            return SurfaceMutationResult.error(validation.code, validation.message);
        }
        JSONArray entries = read();
        JSONObject existing = findEntry(entries, surface.surfaceId);
        if (existing != null) {
            AdaptiveSurface current = entrySurface(existing);
            if (current != null && current.revision == surface.revision
                    && current.toJson().toString().equals(surface.toJson().toString())
                    && "active".equals(existing.optString("state", ""))) {
                return SurfaceMutationResult.ok("already_presented", current);
            }
            return SurfaceMutationResult.error(
                    "surface_exists", "Use replace with the expected revision.");
        }
        entries = prepend(entries, entry(surface, "active", "", System.currentTimeMillis()));
        if (!write(entries)) {
            return SurfaceMutationResult.error("storage_failed", "Could not persist surface.");
        }
        mEvents.record(SurfaceEventLog.PRESENTED, surface, "Surface presented.", null);
        return SurfaceMutationResult.ok("presented", surface);
    }

    public synchronized SurfaceMutationResult replace(AdaptiveSurface surface,
            int expectedRevision) {
        SurfaceValidationResult validation = mValidator.validate(surface);
        if (!validation.valid) {
            mEvents.record(SurfaceEventLog.REJECTED, surface,
                    validation.code + ": " + validation.message, null);
            return SurfaceMutationResult.error(validation.code, validation.message);
        }
        JSONArray entries = read();
        int index = findEntryIndex(entries, surface.surfaceId);
        if (index < 0) {
            return SurfaceMutationResult.error("surface_not_found", "Surface was not found.");
        }
        JSONObject existing = entries.optJSONObject(index);
        AdaptiveSurface current = entrySurface(existing);
        if (current == null || !"active".equals(existing.optString("state", ""))) {
            return SurfaceMutationResult.error("surface_not_active", "Surface is not active.");
        }
        if (current.revision != expectedRevision) {
            return SurfaceMutationResult.error("stale_revision",
                    "Expected revision does not match the current surface.");
        }
        if (!current.sessionId.equals(surface.sessionId)
                || surface.revision != expectedRevision + 1) {
            return SurfaceMutationResult.error("replacement_invalid",
                    "Replacement must keep session ownership and increment revision by one.");
        }
        JSONArray next = new JSONArray();
        next.put(entry(surface, "active", "", System.currentTimeMillis()));
        for (int i = 0; i < entries.length() && next.length() < MAX_ENTRIES; i++) {
            if (i != index) {
                next.put(entries.opt(i));
            }
        }
        if (!write(next)) {
            return SurfaceMutationResult.error("storage_failed", "Could not persist surface.");
        }
        mEvents.record(SurfaceEventLog.REPLACED, surface, "Surface replaced.", null);
        return SurfaceMutationResult.ok("replaced", surface);
    }

    public synchronized SurfaceMutationResult dismiss(String surfaceId, String reason) {
        JSONArray entries = read();
        int index = findEntryIndex(entries, clean(surfaceId));
        if (index < 0) {
            return SurfaceMutationResult.error("surface_not_found", "Surface was not found.");
        }
        JSONObject existing = entries.optJSONObject(index);
        AdaptiveSurface surface = entrySurface(existing);
        if (surface == null) {
            return SurfaceMutationResult.error("surface_malformed", "Stored surface is malformed.");
        }
        if ("dismissed".equals(existing.optString("state", ""))) {
            return SurfaceMutationResult.ok("already_dismissed", surface);
        }
        try {
            existing.put("state", "dismissed")
                    .put("dismissed_reason", clean(reason))
                    .put("updated_at", System.currentTimeMillis());
        } catch (JSONException e) {
            return SurfaceMutationResult.error("storage_failed", "Could not update surface.");
        }
        if (!write(entries)) {
            return SurfaceMutationResult.error("storage_failed", "Could not persist dismissal.");
        }
        mEvents.record(SurfaceEventLog.DISMISSED, surface,
                clean(reason).isEmpty() ? "Surface dismissed." : clean(reason), null);
        return SurfaceMutationResult.ok("dismissed", surface);
    }

    public synchronized AdaptiveSurface getActive(String surfaceId) {
        JSONObject entry = findEntry(read(), clean(surfaceId));
        if (entry == null || !"active".equals(entry.optString("state", ""))) {
            return null;
        }
        AdaptiveSurface surface = entrySurface(entry);
        return surface == null || surface.isExpired(System.currentTimeMillis()) ? null : surface;
    }

    public synchronized AdaptiveSurface currentVisible() {
        JSONArray entries = read();
        long now = System.currentTimeMillis();
        boolean locked = mKeyguard != null && mKeyguard.isDeviceLocked();
        for (int i = 0; i < entries.length(); i++) {
            JSONObject entry = entries.optJSONObject(i);
            if (entry == null || !"active".equals(entry.optString("state", ""))) {
                continue;
            }
            AdaptiveSurface surface = entrySurface(entry);
            if (surface == null || surface.isExpired(now)) {
                continue;
            }
            if (locked && ("sensitive".equals(surface.sensitivity)
                    || "restricted".equals(surface.sensitivity))) {
                continue;
            }
            return surface;
        }
        return null;
    }

    public synchronized SurfaceMutationResult resolveInvocation(String surfaceId,
            int revision, String actionId) {
        AdaptiveSurface surface = getActive(surfaceId);
        if (surface == null) {
            return SurfaceMutationResult.error(
                    "surface_not_active", "Surface is missing, dismissed, or expired.");
        }
        if (surface.revision != revision) {
            return SurfaceMutationResult.error(
                    "stale_revision", "Surface changed; reopen it before acting.");
        }
        if (!surface.actions.containsKey(clean(actionId))) {
            return SurfaceMutationResult.error("action_not_found", "Surface action was not found.");
        }
        SurfaceValidationResult validation = mValidator.validate(surface);
        if (!validation.valid) {
            return SurfaceMutationResult.error(validation.code, validation.message);
        }
        return SurfaceMutationResult.ok("invocation_resolved", surface);
    }

    private static JSONObject entry(AdaptiveSurface surface, String state,
            String dismissedReason, long updatedAt) {
        JSONObject out = new JSONObject();
        try {
            out.put("surface", surface.toJson())
                    .put("state", state)
                    .put("dismissed_reason", dismissedReason)
                    .put("updated_at", updatedAt);
        } catch (JSONException ignored) {
        }
        return out;
    }

    private static AdaptiveSurface entrySurface(JSONObject entry) {
        return entry == null ? null : AdaptiveSurface.fromJson(entry.optJSONObject("surface"));
    }

    private static JSONArray prepend(JSONArray entries, JSONObject first) {
        JSONArray out = new JSONArray().put(first);
        for (int i = 0; i < entries.length() && out.length() < MAX_ENTRIES; i++) {
            out.put(entries.opt(i));
        }
        return out;
    }

    private static JSONObject findEntry(JSONArray entries, String surfaceId) {
        int index = findEntryIndex(entries, surfaceId);
        return index < 0 ? null : entries.optJSONObject(index);
    }

    private static int findEntryIndex(JSONArray entries, String surfaceId) {
        for (int i = 0; i < entries.length(); i++) {
            AdaptiveSurface candidate = entrySurface(entries.optJSONObject(i));
            if (candidate != null && surfaceId.equals(candidate.surfaceId)) {
                return i;
            }
        }
        return -1;
    }

    private JSONArray read() {
        try {
            return new JSONArray(mPrefs.getString(KEY_ENTRIES, "[]"));
        } catch (JSONException e) {
            return new JSONArray();
        }
    }

    private boolean write(JSONArray entries) {
        return mPrefs.edit().putString(KEY_ENTRIES, entries.toString()).commit();
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
