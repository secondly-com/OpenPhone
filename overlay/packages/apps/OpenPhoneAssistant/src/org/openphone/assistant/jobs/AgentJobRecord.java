package org.openphone.assistant.jobs;

public final class AgentJobRecord {
    public final long id;
    public final String type;
    public final String title;
    public final String prompt;
    public final String payloadJson;
    public final String scheduleJson;
    public final String sessionTarget;
    public final String deliveryJson;
    public final String status;
    public final long createdAtMillis;
    public final long updatedAtMillis;
    public final long nextRunAtMillis;
    public final long runningAtMillis;
    public final long lastRunAtMillis;
    public final String lastResult;
    public final int failureCount;
    public final long failureAlertAtMillis;
    public final String phase;
    public final String progressText;
    public final int progressCurrent;
    public final int progressTotal;
    public final String checkpointJson;
    public final String pendingConfirmationId;
    public final String pendingToolRequestJson;
    public final String lastSurfaceId;
    public final String resumeToken;
    public final long lastEventAtMillis;
    public final boolean unreadResult;
    public final long pausedAtMillis;

    AgentJobRecord(long id, String type, String title, String prompt, String payloadJson,
            String scheduleJson, String sessionTarget, String deliveryJson, String status,
            long createdAtMillis, long updatedAtMillis, long nextRunAtMillis,
            long runningAtMillis, long lastRunAtMillis, String lastResult, int failureCount,
            long failureAlertAtMillis, String phase, String progressText,
            int progressCurrent, int progressTotal, String checkpointJson,
            String pendingConfirmationId, String pendingToolRequestJson,
            String lastSurfaceId, String resumeToken, long lastEventAtMillis,
            boolean unreadResult, long pausedAtMillis) {
        this.id = id;
        this.type = type;
        this.title = title;
        this.prompt = prompt;
        this.payloadJson = payloadJson;
        this.scheduleJson = scheduleJson;
        this.sessionTarget = sessionTarget;
        this.deliveryJson = deliveryJson;
        this.status = status;
        this.createdAtMillis = createdAtMillis;
        this.updatedAtMillis = updatedAtMillis;
        this.nextRunAtMillis = nextRunAtMillis;
        this.runningAtMillis = runningAtMillis;
        this.lastRunAtMillis = lastRunAtMillis;
        this.lastResult = lastResult;
        this.failureCount = failureCount;
        this.failureAlertAtMillis = failureAlertAtMillis;
        this.phase = phase;
        this.progressText = progressText;
        this.progressCurrent = progressCurrent;
        this.progressTotal = progressTotal;
        this.checkpointJson = checkpointJson;
        this.pendingConfirmationId = pendingConfirmationId;
        this.pendingToolRequestJson = pendingToolRequestJson;
        this.lastSurfaceId = lastSurfaceId;
        this.resumeToken = resumeToken;
        this.lastEventAtMillis = lastEventAtMillis;
        this.unreadResult = unreadResult;
        this.pausedAtMillis = pausedAtMillis;
    }
}
