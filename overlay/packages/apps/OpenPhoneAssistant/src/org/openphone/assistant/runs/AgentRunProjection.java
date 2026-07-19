package org.openphone.assistant.runs;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.commitments.CommitmentRecord;
import org.openphone.assistant.commitments.CommitmentStore;
import org.openphone.assistant.jobs.AgentJobRecord;
import org.openphone.assistant.jobs.AgentJobStore;
import org.openphone.assistant.jobs.OpenPhoneAgentJobScheduler;
import org.openphone.assistant.OpenPhoneNotificationController;
import org.openphone.assistant.session.PhoneExecutionSession;
import org.openphone.assistant.session.PhoneSessionStore;
import org.openphone.assistant.watchers.WatcherRecord;
import org.openphone.assistant.watchers.WatcherStore;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Central read model for durable OpenPhone work.
 *
 * Source stores remain authoritative. Read/dismiss state belongs to this
 * projection because it is presentation state, not runtime execution state.
 */
public final class AgentRunProjection {
    private static final String PREFS = "openphone_run_projection";
    private static final String READ_PREFIX = "read:";
    private static final String HIDDEN_PREFIX = "hidden:";
    private static final long TERMINAL_VISIBILITY_MILLIS = 24L * 60L * 60L * 1000L;

    private final AgentJobStore mJobs;
    private final WatcherStore mWatchers;
    private final CommitmentStore mCommitments;
    private final PhoneSessionStore mSessions;
    private final SharedPreferences mPrefs;
    private final Context mContext;

    public AgentRunProjection(Context context) {
        Context app = context.getApplicationContext();
        mContext = app;
        mJobs = new AgentJobStore(app);
        mWatchers = new WatcherStore(app);
        mCommitments = new CommitmentStore(app);
        mSessions = new PhoneSessionStore(app);
        mPrefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public List<AgentRunSummary> snapshot(int limit) {
        long now = System.currentTimeMillis();
        ArrayList<AgentRunSummary> out = new ArrayList<>();
        appendJobs(out, now);
        appendWatchers(out);
        appendCommitments(out, now);
        appendSessions(out, now);
        Collections.sort(out, RUN_ORDER);
        int bounded = Math.max(1, Math.min(limit, 100));
        if (out.size() <= bounded) {
            return out;
        }
        return new ArrayList<>(out.subList(0, bounded));
    }

    public boolean markRead(String stableId) {
        String clean = clean(stableId);
        if (clean.isEmpty()) {
            return false;
        }
        return mPrefs.edit().putLong(READ_PREFIX + clean, System.currentTimeMillis()).commit();
    }

    public boolean dismiss(String stableId) {
        String clean = clean(stableId);
        if (clean.isEmpty()) {
            return false;
        }
        return mPrefs.edit()
                .putLong(READ_PREFIX + clean, System.currentTimeMillis())
                .putLong(HIDDEN_PREFIX + clean, System.currentTimeMillis())
                .commit();
    }

    public boolean stop(String stableId) {
        ParsedId parsed = ParsedId.parse(stableId);
        if (parsed == null) {
            return false;
        }
        if (AgentRunSummary.KIND_JOB.equals(parsed.kind)) {
            AgentJobRecord job = mJobs.find(parsed.longId);
            boolean stopped = mJobs.stop(parsed.longId);
            if (stopped && job != null && !job.pendingConfirmationId.isEmpty()) {
                OpenPhoneNotificationController.cancelAgentJobReview(
                        mContext, job.id);
            }
            return stopped;
        }
        if (AgentRunSummary.KIND_WATCHER.equals(parsed.kind)) {
            return mWatchers.stop(parsed.longId);
        }
        if (AgentRunSummary.KIND_COMMITMENT.equals(parsed.kind)) {
            return mCommitments.dismiss(parsed.longId);
        }
        return false;
    }

    public boolean pause(String stableId) {
        ParsedId parsed = ParsedId.parse(stableId);
        boolean paused = parsed != null
                && AgentRunSummary.KIND_JOB.equals(parsed.kind)
                && mJobs.pause(parsed.longId);
        if (paused) {
            OpenPhoneAgentJobScheduler.scheduleNext(mContext);
        }
        return paused;
    }

    public boolean resume(String stableId) {
        ParsedId parsed = ParsedId.parse(stableId);
        boolean resumed = parsed != null
                && AgentRunSummary.KIND_JOB.equals(parsed.kind)
                && mJobs.resume(parsed.longId);
        if (resumed) {
            OpenPhoneAgentJobScheduler.checkNow(mContext);
        }
        return resumed;
    }

    private void appendJobs(List<AgentRunSummary> out, long now) {
        for (AgentJobRecord job : mJobs.list("", 50)) {
            String stableId = stableId(AgentRunSummary.KIND_JOB, job.id);
            if (isHidden(stableId)) {
                continue;
            }
            boolean terminal = isTerminal(job.status);
            boolean unread = terminal && job.unreadResult && !isRead(stableId);
            if (terminal && !unread
                    && now - Math.max(job.updatedAtMillis, job.lastRunAtMillis)
                            > TERMINAL_VISIBILITY_MILLIS) {
                continue;
            }
            JSONObject payload = objectOrEmpty(job.payloadJson);
            String phase = firstNonEmpty(job.phase,
                    payload.optString("phase", ""), job.status);
            String progress = firstNonEmpty(job.progressText,
                    payload.optString("progress_text", ""));
            if (progress.isEmpty()) {
                progress = terminal ? summarizeResult(job.lastResult) : job.prompt;
            }
            String pending = firstNonEmpty(job.pendingConfirmationId,
                    payload.optString("pending_confirmation_id", ""));
            JSONObject pendingRequest = objectOrEmpty(job.pendingToolRequestJson);
            String reviewSummary = pending.isEmpty() ? "" : firstNonEmpty(
                    pendingRequest.optString("summary", ""),
                    pendingRequest.optString("tool", ""));
            String surface = firstNonEmpty(job.lastSurfaceId,
                    payload.optString("surface_id", ""));
            boolean attention = "awaiting_review".equals(job.status)
                    || job.failureCount > 0 || !pending.isEmpty()
                    || "failed".equals(job.status);
            out.add(new AgentRunSummary(
                    stableId,
                    AgentRunSummary.KIND_JOB,
                    Long.toString(job.id),
                    job.title,
                    job.status,
                    phase,
                    progress,
                    "background_job",
                    job.sessionTarget,
                    job.createdAtMillis,
                    job.updatedAtMillis,
                    job.nextRunAtMillis,
                    attention,
                    unread,
                    pending,
                    reviewSummary,
                    surface,
                    "queued".equals(job.status) || "active".equals(job.status),
                    "paused".equals(job.status),
                    !terminal));
        }
    }

    private void appendWatchers(List<AgentRunSummary> out) {
        for (WatcherRecord watcher : mWatchers.active(50)) {
            String stableId = stableId(AgentRunSummary.KIND_WATCHER, watcher.id);
            if (isHidden(stableId)) {
                continue;
            }
            boolean attention = watcher.failureCount > 0;
            out.add(new AgentRunSummary(
                    stableId,
                    AgentRunSummary.KIND_WATCHER,
                    Long.toString(watcher.id),
                    watcher.title,
                    watcher.status,
                    "running".equals(watcher.status) ? "checking" : "watching",
                    watcher.type,
                    "watcher",
                    watcher.sessionTarget,
                    watcher.createdAtMillis,
                    watcher.updatedAtMillis,
                    watcher.nextRunAtMillis,
                    attention,
                    false,
                    "",
                    "",
                    "",
                    false,
                    false,
                    true));
        }
    }

    private void appendCommitments(List<AgentRunSummary> out, long now) {
        for (CommitmentRecord commitment : mCommitments.active(50)) {
            String stableId = stableId(AgentRunSummary.KIND_COMMITMENT, commitment.id);
            if (isHidden(stableId)) {
                continue;
            }
            boolean due = commitment.dueAtMillis > 0 && commitment.dueAtMillis <= now;
            if (!due && commitment.updatedAtMillis + TERMINAL_VISIBILITY_MILLIS < now) {
                continue;
            }
            out.add(new AgentRunSummary(
                    stableId,
                    AgentRunSummary.KIND_COMMITMENT,
                    Long.toString(commitment.id),
                    commitment.title,
                    commitment.status,
                    due ? "due" : "waiting",
                    commitment.description,
                    "commitment",
                    "",
                    commitment.createdAtMillis,
                    commitment.updatedAtMillis,
                    commitment.dueAtMillis,
                    due,
                    due && !isRead(stableId),
                    "",
                    "",
                    "",
                    false,
                    false,
                    true));
        }
    }

    private void appendSessions(List<AgentRunSummary> out, long now) {
        for (PhoneExecutionSession session : mSessions.list(50)) {
            String stableId = sessionStableId(session.phoneSessionId);
            if (isHidden(stableId)) {
                continue;
            }
            boolean terminal = isSessionTerminal(session.status);
            boolean unread = terminal && !isRead(stableId);
            if (terminal && (!unread
                    || now - session.updatedAtMillis > TERMINAL_VISIBILITY_MILLIS)) {
                continue;
            }
            boolean attention = "awaiting_confirmation".equals(session.status)
                    || "failed".equals(session.status);
            out.add(new AgentRunSummary(
                    stableId,
                    AgentRunSummary.KIND_SESSION,
                    session.phoneSessionId,
                    session.summary.isEmpty() ? "Runtime session" : session.summary,
                    session.status,
                    session.status,
                    session.source,
                    session.source,
                    session.runtimeKind,
                    session.createdAtMillis,
                    session.updatedAtMillis,
                    0L,
                    attention,
                    unread,
                    "",
                    "",
                    "",
                    false,
                    false,
                    false));
        }
    }

    private boolean isRead(String stableId) {
        return mPrefs.contains(READ_PREFIX + stableId);
    }

    private boolean isHidden(String stableId) {
        return mPrefs.contains(HIDDEN_PREFIX + stableId);
    }

    private static String stableId(String kind, long id) {
        return kind + ":" + id;
    }

    private static String sessionStableId(String sessionId) {
        return AgentRunSummary.KIND_SESSION + ":" + clean(sessionId);
    }

    private static boolean isTerminal(String status) {
        return "completed".equals(status)
                || "failed".equals(status)
                || "stopped".equals(status)
                || "dispatched".equals(status);
    }

    private static boolean isSessionTerminal(String status) {
        return "completed".equals(status)
                || "failed".equals(status)
                || "stopped".equals(status)
                || "final".equals(status);
    }

    private static JSONObject objectOrEmpty(String raw) {
        try {
            return new JSONObject(raw == null || raw.trim().isEmpty() ? "{}" : raw);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static String summarizeResult(String value) {
        String clean = clean(value).replaceAll("\\s+", " ");
        return clean.length() <= 240 ? clean : clean.substring(0, 240) + "…";
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    private static String firstNonEmpty(String... values) {
        for (String value : values) {
            if (value != null && !value.trim().isEmpty()) {
                return value.trim();
            }
        }
        return "";
    }

    private static final Comparator<AgentRunSummary> RUN_ORDER = (left, right) -> {
        int attention = Boolean.compare(right.needsAttention, left.needsAttention);
        if (attention != 0) {
            return attention;
        }
        int live = Boolean.compare(right.isLive(), left.isLive());
        if (live != 0) {
            return live;
        }
        return Long.compare(right.updatedAtMillis, left.updatedAtMillis);
    };

    private static final class ParsedId {
        final String kind;
        final long longId;

        ParsedId(String kind, long longId) {
            this.kind = kind;
            this.longId = longId;
        }

        static ParsedId parse(String stableId) {
            String clean = clean(stableId);
            int separator = clean.indexOf(':');
            if (separator <= 0 || separator >= clean.length() - 1) {
                return null;
            }
            String kind = clean.substring(0, separator);
            try {
                return new ParsedId(kind, Long.parseLong(clean.substring(separator + 1)));
            } catch (NumberFormatException e) {
                return null;
            }
        }
    }
}
