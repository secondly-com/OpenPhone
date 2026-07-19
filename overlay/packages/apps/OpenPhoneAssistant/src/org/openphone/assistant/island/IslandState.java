package org.openphone.assistant.island;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * Bounded, privacy-minimized projection published for the SystemUI island.
 *
 * <p>system_server validates this shape, discards unknown fields, and assigns
 * the authoritative revision and publication timestamps.</p>
 */
public final class IslandState {
    public static final String SCHEMA = "openphone.island_state.v1";

    private final String mMode;
    private final String mLabel;
    private final String mTitle;
    private final String mDetail;
    private final boolean mVisible;
    private final boolean mNeedsAttention;
    private final String mSensitivity;
    private final String mActiveTaskId;
    private final String mPendingConfirmationId;
    private final int mLiveRuns;
    private final long mUpdatedAtMillis;

    public IslandState(String mode, String label, String title, String detail,
            boolean visible, boolean needsAttention, String sensitivity,
            String activeTaskId, String pendingConfirmationId, int liveRuns,
            long updatedAtMillis) {
        mMode = bounded(mode, 32);
        mLabel = bounded(label, 48);
        mTitle = bounded(title, 80);
        mDetail = bounded(detail, 160);
        mVisible = visible;
        mNeedsAttention = needsAttention;
        mSensitivity = bounded(sensitivity, 16);
        mActiveTaskId = bounded(activeTaskId, 96);
        mPendingConfirmationId = bounded(pendingConfirmationId, 128);
        mLiveRuns = Math.max(0, Math.min(liveRuns, 100));
        mUpdatedAtMillis = Math.max(0L, updatedAtMillis);
    }

    public String toJson() {
        try {
            return new JSONObject()
                    .put("schema", SCHEMA)
                    .put("mode", mMode)
                    .put("label", mLabel)
                    .put("title", mTitle)
                    .put("detail", mDetail)
                    .put("visible", mVisible)
                    .put("needs_attention", mNeedsAttention)
                    .put("sensitivity", mSensitivity)
                    .put("active_task_id", mActiveTaskId)
                    .put("pending_confirmation_id", mPendingConfirmationId)
                    .put("live_runs", mLiveRuns)
                    .put("updated_at", mUpdatedAtMillis)
                    .toString();
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    private static String bounded(String value, int maxLength) {
        String clean = value == null ? "" : value.trim();
        return clean.length() <= maxLength ? clean : clean.substring(0, maxLength);
    }
}
