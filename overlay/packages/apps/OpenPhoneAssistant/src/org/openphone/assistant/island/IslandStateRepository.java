package org.openphone.assistant.island;

import android.content.Context;
import android.openphone.OpenPhoneAgentManager;
import android.os.SystemProperties;
import android.util.Log;

import org.openphone.assistant.runs.AgentRunProjection;
import org.openphone.assistant.runs.AgentRunSummary;

import java.util.List;

/**
 * Projects assistant and durable-run state into the compact SystemUI contract.
 *
 * <p>The projection deliberately contains no transcript, reply, screenshot,
 * notification body, tool parameters, or result payload. AI Home remains the
 * review surface for those richer details.</p>
 */
public final class IslandStateRepository {
    private static final String TAG = "OpenPhoneIslandState";
    private static final String SYSTEM_UI_PROPERTY = "ro.openphone.systemui_island";
    private static final long MIN_REPEAT_PUBLISH_MS = 1500L;

    private final OpenPhoneAgentManager mAgentManager;
    private final AgentRunProjection mRunProjection;
    private String mLastProjectionKey = "";
    private long mLastPublishedAtMillis;

    public IslandStateRepository(Context context) {
        Context app = context.getApplicationContext();
        mAgentManager = app.getSystemService(OpenPhoneAgentManager.class);
        mRunProjection = new AgentRunProjection(app);
    }

    public boolean isSystemUiOwned() {
        return SystemProperties.getBoolean(SYSTEM_UI_PROPERTY, false);
    }

    public void publish(String requestedMode, boolean visible, String activeTaskId,
            int watchingCount) {
        if (!isSystemUiOwned() || mAgentManager == null) {
            return;
        }

        String mode = cleanMode(requestedMode);
        int liveRuns = 0;
        boolean needsAttention = "needs_review".equals(mode) || "error".equals(mode);
        String pendingConfirmationId = "";
        try {
            List<AgentRunSummary> runs = mRunProjection.snapshot(50);
            for (AgentRunSummary run : runs) {
                if (run.isLive()) {
                    liveRuns++;
                }
                if (pendingConfirmationId.isEmpty()
                        && !run.pendingConfirmationId.isEmpty()) {
                    pendingConfirmationId = run.pendingConfirmationId;
                }
                needsAttention |= run.needsAttention;
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "Unable to project durable runs for island", e);
        }
        liveRuns = Math.max(liveRuns, Math.max(0, watchingCount));

        if (("idle".equals(mode) || "watching".equals(mode))
                && !pendingConfirmationId.isEmpty()) {
            mode = "needs_review";
        } else if ("idle".equals(mode) && liveRuns > 0) {
            mode = "watching";
        }

        IslandCopy copy = copyForMode(mode, liveRuns);
        String sensitivity = "idle".equals(mode) && liveRuns == 0 && !needsAttention
                ? "public" : "personal";
        long now = System.currentTimeMillis();
        String projectionKey = mode + "|" + visible + "|" + needsAttention + "|"
                + clean(activeTaskId) + "|" + pendingConfirmationId + "|" + liveRuns;
        if (projectionKey.equals(mLastProjectionKey)
                && now - mLastPublishedAtMillis < MIN_REPEAT_PUBLISH_MS) {
            return;
        }
        IslandState state = new IslandState(
                mode,
                copy.label,
                copy.title,
                copy.detail,
                visible,
                needsAttention,
                sensitivity,
                activeTaskId,
                pendingConfirmationId,
                liveRuns,
                now);
        try {
            mAgentManager.publishIslandState(state.toJson());
            mLastProjectionKey = projectionKey;
            mLastPublishedAtMillis = now;
        } catch (RuntimeException e) {
            Log.w(TAG, "Unable to publish SystemUI island state", e);
        }
    }

    private static IslandCopy copyForMode(String mode, int liveRuns) {
        switch (mode) {
            case "listening":
                return new IslandCopy("Listening", "Listening", "Voice capture active");
            case "transcript":
                return new IslandCopy("OpenPhone", "Request captured",
                        "Voice request captured");
            case "thinking":
                return new IslandCopy("OpenPhone", "Thinking", "Working on your request");
            case "realtime":
                return new IslandCopy("OpenPhone", "Live", "Realtime session active");
            case "action_running":
                return new IslandCopy("OpenPhone", "Working", "Task running");
            case "answer_ready":
                return new IslandCopy("OpenPhone", "Done", "Task complete");
            case "reply":
                return new IslandCopy("OpenPhone", "Ready", "Response ready");
            case "needs_review":
                return new IslandCopy("Review", "Approval needed",
                        "Open AI Home to review");
            case "error":
                return new IslandCopy("OpenPhone", "Needs attention",
                        "Open AI Home for details");
            case "watching":
                return new IslandCopy("OpenPhone", "Background activity",
                        liveRuns > 0 ? liveRuns + " active" : "Watching");
            case "idle":
            default:
                return new IslandCopy("OpenPhone", "Ready", "");
        }
    }

    private static String cleanMode(String mode) {
        String clean = clean(mode);
        switch (clean) {
            case "idle":
            case "listening":
            case "transcript":
            case "thinking":
            case "realtime":
            case "action_running":
            case "answer_ready":
            case "reply":
            case "needs_review":
            case "error":
            case "watching":
                return clean;
            default:
                return "idle";
        }
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    private static final class IslandCopy {
        final String label;
        final String title;
        final String detail;

        IslandCopy(String label, String title, String detail) {
            this.label = label;
            this.title = title;
            this.detail = detail;
        }
    }
}
