package org.openphone.assistant.runs;

/** Read-only projection of durable OpenPhone work for Home and SystemUI. */
public final class AgentRunSummary {
    public static final String KIND_JOB = "job";
    public static final String KIND_WATCHER = "watcher";
    public static final String KIND_COMMITMENT = "commitment";
    public static final String KIND_SESSION = "foreground_session";

    public final String id;
    public final String kind;
    public final String sourceId;
    public final String title;
    public final String status;
    public final String phase;
    public final String progressText;
    public final String origin;
    public final String runtime;
    public final long createdAtMillis;
    public final long updatedAtMillis;
    public final long nextRunAtMillis;
    public final boolean needsAttention;
    public final boolean unreadResult;
    public final String pendingConfirmationId;
    public final String surfaceId;
    public final boolean canPause;
    public final boolean canResume;
    public final boolean canStop;

    public AgentRunSummary(String id, String kind, String sourceId, String title,
            String status, String phase, String progressText, String origin, String runtime,
            long createdAtMillis, long updatedAtMillis, long nextRunAtMillis,
            boolean needsAttention, boolean unreadResult, String pendingConfirmationId,
            String surfaceId, boolean canPause, boolean canResume, boolean canStop) {
        this.id = clean(id);
        this.kind = clean(kind);
        this.sourceId = clean(sourceId);
        this.title = clean(title);
        this.status = clean(status);
        this.phase = clean(phase);
        this.progressText = clean(progressText);
        this.origin = clean(origin);
        this.runtime = clean(runtime);
        this.createdAtMillis = createdAtMillis;
        this.updatedAtMillis = updatedAtMillis;
        this.nextRunAtMillis = nextRunAtMillis;
        this.needsAttention = needsAttention;
        this.unreadResult = unreadResult;
        this.pendingConfirmationId = clean(pendingConfirmationId);
        this.surfaceId = clean(surfaceId);
        this.canPause = canPause;
        this.canResume = canResume;
        this.canStop = canStop;
    }

    public boolean isLive() {
        return "active".equals(status)
                || "queued".equals(status)
                || "running".equals(status)
                || "waiting".equals(status)
                || "waiting_for_runtime".equals(status)
                || "awaiting_review".equals(status)
                || "created".equals(status);
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
