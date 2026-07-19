package org.openphone.assistant.jobs;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public final class AgentJobStore {
    private static final String TAG = "OpenPhoneAgentJobs";
    private static final String PREFS = "openphone_agent_jobs";
    private static final String KEY_JOBS = "jobs";
    private static final String KEY_NEXT_ID = "next_id";
    private static final int MAX_JOBS = 200;
    private static final int MAX_CHECKPOINT_CHARS = 12000;
    private static final int MAX_PENDING_REQUEST_CHARS = 12000;
    private static final Object STORE_LOCK = new Object();
    private static final Object REVIEW_LOCK = STORE_LOCK;

    private final SharedPreferences mPrefs;

    public AgentJobStore(Context context) {
        mPrefs = context.getApplicationContext().getSharedPreferences(PREFS,
                Context.MODE_PRIVATE);
    }

    public synchronized long createJob(String type, String title, String prompt,
            String payloadJson, String scheduleJson, String sessionTarget,
            String deliveryJson, long nextRunAtMillis) {
        synchronized (STORE_LOCK) {
            String cleanTitle = safe(title).trim();
            if (cleanTitle.isEmpty()) {
                return -1L;
            }
            long now = System.currentTimeMillis();
            long id = Math.max(1L, mPrefs.getLong(KEY_NEXT_ID, 1L));
            JSONArray jobs = readJobs();
            JSONObject job = new JSONObject();
            try {
                job.put("id", id)
                        .put("type", normalizeType(type))
                        .put("title", cleanTitle)
                        .put("prompt", safe(prompt))
                        .put("payload_json", objectOrEmpty(payloadJson))
                        .put("schedule_json", objectOrEmpty(scheduleJson))
                        .put("session_target", safe(sessionTarget).isEmpty()
                                ? "main" : safe(sessionTarget))
                        .put("delivery_json", objectOrEmpty(
                                defaultDelivery(deliveryJson)))
                        .put("status", "queued")
                        .put("created_at", now)
                        .put("updated_at", now)
                        .put("next_run_at", Math.max(0L, nextRunAtMillis))
                        .put("running_at", 0L)
                        .put("last_run_at", 0L)
                        .put("last_result", "")
                        .put("failure_count", 0)
                        .put("failure_alert_at", 0L)
                        .put("phase", "queued")
                        .put("progress_text", "Queued")
                        .put("progress_current", 0)
                        .put("progress_total", 0)
                        .put("checkpoint_json", new JSONObject())
                        .put("pending_confirmation_id", "")
                        .put("pending_tool_request_json", new JSONObject())
                        .put("last_surface_id", "")
                        .put("resume_token", "")
                        .put("last_event_at", now)
                        .put("unread_result", false)
                        .put("paused_at", 0L);
            } catch (JSONException e) {
                return -1L;
            }
            jobs.put(job);
            trimOldTerminalJobs(jobs);
            if (!writeJobs(jobs, id + 1L)) {
                return -1L;
            }
            return id;
        }
    }

    public synchronized List<AgentJobRecord> due(long nowMillis, int limit) {
        List<AgentJobRecord> out = new ArrayList<>();
        JSONArray jobs = readJobs();
        for (int i = 0; i < jobs.length() && out.size() < Math.max(1, limit); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job == null || !isQueued(job.optString("status", ""))) {
                continue;
            }
            long nextRunAt = job.optLong("next_run_at", 0L);
            if (nextRunAt <= 0 || nextRunAt <= nowMillis) {
                out.add(fromJson(job));
            }
        }
        return out;
    }

    public synchronized List<AgentJobRecord> list(String query, int limit) {
        String cleanQuery = safe(query).toLowerCase(Locale.US);
        int boundedLimit = Math.max(1, Math.min(limit, 50));
        List<AgentJobRecord> out = new ArrayList<>();
        JSONArray jobs = readJobs();
        for (int i = jobs.length() - 1; i >= 0 && out.size() < boundedLimit; i--) {
            JSONObject job = jobs.optJSONObject(i);
            if (job == null) {
                continue;
            }
            if (!cleanQuery.isEmpty()) {
                String haystack = (job.optString("title", "") + " "
                        + job.optString("prompt", "") + " "
                        + job.optString("status", "")).toLowerCase(Locale.US);
                if (!haystack.contains(cleanQuery)) {
                    continue;
                }
            }
            out.add(fromJson(job));
        }
        return out;
    }

    public synchronized String listJson(String query, int limit) {
        JSONArray array = new JSONArray();
        for (AgentJobRecord job : list(query, limit)) {
            array.put(toJson(job));
        }
        try {
            return new JSONObject().put("jobs", array).toString();
        } catch (JSONException e) {
            return "{\"jobs\":[]}";
        }
    }

    public synchronized long nextRunAt(long nowMillis) {
        long next = 0L;
        JSONArray jobs = readJobs();
        for (int i = 0; i < jobs.length(); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job == null || !isQueued(job.optString("status", ""))) {
                continue;
            }
            long due = job.optLong("next_run_at", 0L);
            if (due <= 0) {
                due = nowMillis;
            }
            if (next <= 0 || due < next) {
                next = due;
            }
        }
        return next;
    }

    public synchronized boolean markRunning(long id, long nowMillis) {
        return updateJob(id, job -> {
            if (!isQueued(job.optString("status", ""))) {
                return false;
            }
            job.put("status", "running")
                    .put("phase", "running")
                    .put("progress_text", "Working")
                    .put("running_at", nowMillis)
                    .put("updated_at", nowMillis)
                    .put("last_event_at", nowMillis);
            return true;
        });
    }

    public synchronized boolean markCompleted(long id, String result, long nowMillis) {
        return updateJob(id, job -> {
            if (!"running".equals(job.optString("status", ""))) {
                return false;
            }
            JSONObject schedule = job.optJSONObject("schedule_json");
            long interval = schedule == null ? 0L : schedule.optLong("interval_ms", 0L);
            job.put("status", interval > 0 ? "queued" : "completed")
                    .put("phase", interval > 0 ? "queued" : "completed")
                    .put("progress_text", interval > 0 ? "Waiting for next run" : "Completed")
                    .put("updated_at", nowMillis)
                    .put("last_run_at", nowMillis)
                    .put("running_at", 0L)
                    .put("last_result", truncate(result))
                    .put("failure_count", 0)
                    .put("failure_alert_at", 0L)
                    .put("checkpoint_json", new JSONObject())
                    .put("pending_confirmation_id", "")
                    .put("pending_tool_request_json", new JSONObject())
                    .put("resume_token", "")
                    .put("last_event_at", nowMillis)
                    .put("unread_result", interval <= 0);
            if (interval > 0) {
                job.put("next_run_at", nowMillis + Math.max(interval, 15_000L));
            } else {
                job.put("next_run_at", 0L);
            }
            return true;
        });
    }

    public synchronized boolean markDispatched(long id, String result, long nowMillis) {
        return updateJob(id, job -> {
            job.put("status", "dispatched")
                    .put("phase", "waiting_for_runtime")
                    .put("progress_text", "Sent to runtime")
                    .put("updated_at", nowMillis)
                    .put("last_run_at", nowMillis)
                    .put("running_at", 0L)
                    .put("last_result", truncate(result))
                    .put("next_run_at", 0L)
                    .put("last_event_at", nowMillis)
                    .put("unread_result", true);
            return true;
        });
    }

    public synchronized boolean markFailed(long id, String reason, long nextRunAtMillis,
            int failureCount, long failureAlertAtMillis, long nowMillis) {
        return updateJob(id, job -> {
            if ("stopped".equals(job.optString("status", ""))) {
                return false;
            }
            boolean terminal = failureCount >= 6;
            job.put("status", terminal ? "failed" : "queued")
                    .put("phase", terminal ? "failed" : "waiting")
                    .put("progress_text", truncate(reason))
                    .put("updated_at", nowMillis)
                    .put("last_run_at", nowMillis)
                    .put("running_at", 0L)
                    .put("last_result", truncate(reason))
                    .put("next_run_at", nextRunAtMillis)
                    .put("failure_count", Math.max(1, failureCount))
                    .put("failure_alert_at", failureAlertAtMillis)
                    .put("last_event_at", nowMillis)
                    .put("unread_result", terminal);
            return true;
        });
    }

    public synchronized boolean stop(long id) {
        long now = System.currentTimeMillis();
        return updateJob(id, job -> {
            job.put("status", "stopped")
                    .put("phase", "stopped")
                    .put("progress_text", "Stopped")
                    .put("updated_at", now)
                    .put("running_at", 0L)
                    .put("next_run_at", 0L)
                    .put("checkpoint_json", new JSONObject())
                    .put("pending_confirmation_id", "")
                    .put("pending_tool_request_json", new JSONObject())
                    .put("resume_token", "")
                    .put("last_event_at", now)
                    .put("unread_result", true);
            return true;
        });
    }

    public synchronized AgentJobRecord find(long id) {
        JSONArray jobs = readJobs();
        for (int i = 0; i < jobs.length(); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job != null && job.optLong("id", -1L) == id) {
                return fromJson(job);
            }
        }
        return null;
    }

    public synchronized AgentJobRecord findByConfirmationId(String confirmationId) {
        String cleanId = safe(confirmationId).trim();
        if (cleanId.isEmpty()) {
            return null;
        }
        JSONArray jobs = readJobs();
        for (int i = 0; i < jobs.length(); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job != null && cleanId.equals(
                    job.optString("pending_confirmation_id", ""))) {
                return fromJson(job);
            }
        }
        return null;
    }

    public boolean markAwaitingReview(long id, JSONObject checkpoint,
            JSONObject pendingRequest, String confirmationId, String resumeToken,
            String progressText, long nowMillis) {
        String checkpointRaw = boundedJson(checkpoint, MAX_CHECKPOINT_CHARS);
        String pendingRaw = boundedJson(pendingRequest, MAX_PENDING_REQUEST_CHARS);
        if (checkpointRaw == null || pendingRaw == null
                || safe(confirmationId).trim().isEmpty()
                || safe(resumeToken).trim().isEmpty()) {
            return false;
        }
        synchronized (REVIEW_LOCK) {
            return updateJob(id, job -> {
                if (!"running".equals(job.optString("status", ""))) {
                    return false;
                }
                job.put("status", "awaiting_review")
                        .put("phase", "awaiting_review")
                        .put("progress_text", truncate(progressText))
                        .put("checkpoint_json", new JSONObject(checkpointRaw))
                        .put("pending_confirmation_id", confirmationId)
                        .put("pending_tool_request_json", new JSONObject(pendingRaw))
                        .put("resume_token", resumeToken)
                        .put("running_at", 0L)
                        .put("next_run_at", 0L)
                        .put("updated_at", nowMillis)
                        .put("last_event_at", nowMillis)
                        .put("unread_result", false);
                return true;
            });
        }
    }

    /**
     * Atomically claims a still-pending review. Only the first tap can move it
     * to resolving; later taps observe no claim and cannot execute the tool.
     */
    public ReviewClaim claimReview(String confirmationId, boolean approved, long nowMillis) {
        String cleanId = safe(confirmationId).trim();
        if (cleanId.isEmpty()) {
            return null;
        }
        synchronized (REVIEW_LOCK) {
            JSONArray jobs = readJobs();
            for (int i = 0; i < jobs.length(); i++) {
                JSONObject job = jobs.optJSONObject(i);
                if (job == null || !"awaiting_review".equals(
                        job.optString("status", ""))) {
                    continue;
                }
                if (!cleanId.equals(job.optString("pending_confirmation_id", ""))) {
                    continue;
                }
                JSONObject pending = job.optJSONObject("pending_tool_request_json");
                if (pending == null || !"pending".equals(
                        pending.optString("review_state", ""))) {
                    return null;
                }
                long expiresAt = pending.optLong("expires_at", 0L);
                if (expiresAt <= nowMillis) {
                    try {
                        applyReviewResolution(job, pending, "timeout",
                                "{\"status\":\"background.confirmation_timeout\"}",
                                nowMillis);
                    } catch (JSONException e) {
                        Log.w(TAG, "failed to expire claimed review", e);
                        return null;
                    }
                    writeJobs(jobs, mPrefs.getLong(KEY_NEXT_ID, 1L));
                    return null;
                }
                try {
                    pending.put("review_state", "resolving")
                            .put("decision", approved ? "approved" : "denied")
                            .put("reviewed_at", nowMillis);
                    job.put("status", "waiting")
                            .put("phase", approved ? "approval_executing" : "denial_resolving")
                            .put("progress_text", approved
                                    ? "Executing approved action" : "Applying denial")
                            .put("pending_tool_request_json", pending)
                            .put("updated_at", nowMillis)
                            .put("last_event_at", nowMillis);
                } catch (JSONException e) {
                    return null;
                }
                if (!writeJobs(jobs, mPrefs.getLong(KEY_NEXT_ID, 1L))) {
                    return null;
                }
                return new ReviewClaim(fromJson(job), objectOrEmpty(pending.toString()), approved);
            }
        }
        return null;
    }

    public boolean completeReview(long jobId, String confirmationId, String resolution,
            String toolResult, long nowMillis) {
        synchronized (REVIEW_LOCK) {
            return updateJob(jobId, job -> {
                if (!safe(confirmationId).equals(
                        job.optString("pending_confirmation_id", ""))) {
                    return false;
                }
                JSONObject pending = job.optJSONObject("pending_tool_request_json");
                if (pending == null || !"resolving".equals(
                        pending.optString("review_state", ""))) {
                    return false;
                }
                applyReviewResolution(job, pending, resolution, toolResult, nowMillis);
                return true;
            });
        }
    }

    public int expirePendingReviews(long nowMillis) {
        final int[] expired = {0};
        final boolean persisted;
        synchronized (REVIEW_LOCK) {
            persisted = updateAllJobs(job -> {
                if (!"awaiting_review".equals(job.optString("status", ""))) {
                    return false;
                }
                JSONObject pending = job.optJSONObject("pending_tool_request_json");
                if (pending == null || pending.optLong("expires_at", 0L) > nowMillis) {
                    return false;
                }
                try {
                    applyReviewResolution(job, pending, "timeout",
                            "{\"status\":\"background.confirmation_timeout\","
                                    + "\"reason\":\"approval_expired\"}", nowMillis);
                } catch (JSONException e) {
                    Log.w(TAG, "failed to expire background review", e);
                    return false;
                }
                expired[0]++;
                return true;
            });
        }
        return persisted ? expired[0] : 0;
    }

    public synchronized List<Long> reviewJobIdsExpiringBy(long nowMillis) {
        List<Long> ids = new ArrayList<>();
        JSONArray jobs = readJobs();
        for (int i = 0; i < jobs.length(); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job == null
                    || !"awaiting_review".equals(job.optString("status", ""))) {
                continue;
            }
            JSONObject pending = job.optJSONObject("pending_tool_request_json");
            if (pending != null && pending.optLong("expires_at", 0L) <= nowMillis) {
                ids.add(job.optLong("id", -1L));
            }
        }
        return ids;
    }

    public synchronized boolean pause(long id) {
        long now = System.currentTimeMillis();
        return updateJob(id, job -> {
            String status = job.optString("status", "");
            if (!isQueued(status)) {
                return false;
            }
            job.put("status", "paused")
                    .put("phase", "paused")
                    .put("progress_text", "Paused")
                    .put("paused_at", now)
                    .put("next_run_at", 0L)
                    .put("updated_at", now)
                    .put("last_event_at", now);
            return true;
        });
    }

    public synchronized boolean resume(long id) {
        long now = System.currentTimeMillis();
        return updateJob(id, job -> {
            if (!"paused".equals(job.optString("status", ""))) {
                return false;
            }
            job.put("status", "queued")
                    .put("phase", "queued")
                    .put("progress_text", "Queued")
                    .put("paused_at", 0L)
                    .put("next_run_at", now)
                    .put("updated_at", now)
                    .put("last_event_at", now);
            return true;
        });
    }

    public synchronized int repairStuck(long staleBeforeMillis, long nowMillis) {
        final int[] repaired = {0};
        boolean persisted = updateAllJobs(job -> {
            if ("running".equals(job.optString("status", ""))
                    && job.optLong("running_at", 0L) > 0
                    && job.optLong("running_at", 0L) < staleBeforeMillis) {
                int failures = job.optInt("failure_count", 0) + 1;
                job.put("status", "queued")
                        .put("phase", "waiting")
                        .put("progress_text", "Recovered after interruption")
                        .put("running_at", 0L)
                        .put("updated_at", nowMillis)
                        .put("last_result", "stuck_running_repaired")
                        .put("failure_count", failures)
                        .put("next_run_at", nowMillis + backoffMillis(failures))
                        .put("last_event_at", nowMillis);
                repaired[0]++;
                return true;
            }
            JSONObject pending = job.optJSONObject("pending_tool_request_json");
            if ("waiting".equals(job.optString("status", ""))
                    && pending != null
                    && "resolving".equals(pending.optString("review_state", ""))
                    && pending.optLong("reviewed_at", 0L) > 0
                    && pending.optLong("reviewed_at", 0L) < staleBeforeMillis) {
                if ("denied".equals(pending.optString("decision", ""))) {
                    applyReviewResolution(job, pending, "denied_after_restart",
                            "{\"status\":\"background.action_denied\","
                                    + "\"reason\":\"user_denied\"}", nowMillis);
                    repaired[0]++;
                    return true;
                }
                pending.put("review_state", "resolved")
                        .put("resolution", "interrupted_unknown")
                        .put("resolved_at", nowMillis);
                job.put("status", "failed")
                        .put("phase", "review_resolution_unknown")
                        .put("progress_text",
                                "Approved action was interrupted; it was not replayed")
                        .put("running_at", 0L)
                        .put("updated_at", nowMillis)
                        .put("last_result",
                                "background.review_interrupted_result_unknown")
                        .put("pending_confirmation_id", "")
                        .put("pending_tool_request_json", pending)
                        .put("next_run_at", 0L)
                        .put("last_event_at", nowMillis)
                        .put("unread_result", true);
                repaired[0]++;
                return true;
            }
            return false;
        });
        return persisted ? repaired[0] : 0;
    }

    public static long backoffMillis(int failureCount) {
        int bounded = Math.max(1, Math.min(failureCount, 6));
        return (1L << (bounded - 1)) * 60L * 1000L;
    }

    static JSONObject toJson(AgentJobRecord job) {
        JSONObject out = new JSONObject();
        try {
            out.put("id", job.id)
                    .put("type", job.type)
                    .put("title", job.title)
                    .put("prompt", job.prompt)
                    .put("payload_json", objectOrEmpty(job.payloadJson))
                    .put("schedule_json", objectOrEmpty(job.scheduleJson))
                    .put("session_target", job.sessionTarget)
                    .put("delivery_json", objectOrEmpty(job.deliveryJson))
                    .put("status", job.status)
                    .put("created_at", job.createdAtMillis)
                    .put("updated_at", job.updatedAtMillis)
                    .put("next_run_at", job.nextRunAtMillis)
                    .put("running_at", job.runningAtMillis)
                    .put("last_run_at", job.lastRunAtMillis)
                    .put("last_result", job.lastResult)
                    .put("failure_count", job.failureCount)
                    .put("failure_alert_at", job.failureAlertAtMillis)
                    .put("phase", job.phase)
                    .put("progress_text", job.progressText)
                    .put("progress_current", job.progressCurrent)
                    .put("progress_total", job.progressTotal)
                    .put("checkpoint_json", objectOrEmpty(job.checkpointJson))
                    .put("pending_confirmation_id", job.pendingConfirmationId)
                    .put("pending_tool_request_json",
                            objectOrEmpty(job.pendingToolRequestJson))
                    .put("last_surface_id", job.lastSurfaceId)
                    .put("resume_token", job.resumeToken)
                    .put("last_event_at", job.lastEventAtMillis)
                    .put("unread_result", job.unreadResult)
                    .put("paused_at", job.pausedAtMillis);
        } catch (JSONException ignored) {
        }
        return out;
    }

    private interface JobUpdater {
        boolean update(JSONObject job) throws JSONException;
    }

    private boolean updateJob(long id, JobUpdater updater) {
        final boolean[] changed = {false};
        boolean persisted = updateAllJobs(job -> {
            if (job.optLong("id", -1L) != id) {
                return false;
            }
            changed[0] = updater.update(job);
            return changed[0];
        });
        return changed[0] && persisted;
    }

    private boolean updateAllJobs(JobUpdater updater) {
        synchronized (STORE_LOCK) {
            JSONArray jobs = readJobs();
            boolean changed = false;
            for (int i = 0; i < jobs.length(); i++) {
                JSONObject job = jobs.optJSONObject(i);
                if (job == null) {
                    continue;
                }
                try {
                    changed |= updater.update(job);
                } catch (JSONException e) {
                    Log.w(TAG, "job update failed", e);
                }
            }
            return !changed || writeJobs(jobs, mPrefs.getLong(KEY_NEXT_ID, 1L));
        }
    }

    private JSONArray readJobs() {
        synchronized (STORE_LOCK) {
            String raw = mPrefs.getString(KEY_JOBS, "[]");
            try {
                JSONArray jobs = new JSONArray(raw == null || raw.isEmpty() ? "[]" : raw);
                boolean migrated = false;
                for (int i = 0; i < jobs.length(); i++) {
                    JSONObject job = jobs.optJSONObject(i);
                    if (job != null) {
                        migrated |= ensureLifecycleDefaults(job);
                    }
                }
                if (migrated) {
                    mPrefs.edit().putString(KEY_JOBS, jobs.toString()).commit();
                }
                return jobs;
            } catch (JSONException e) {
                Log.w(TAG, "agent job store corrupt; ignoring", e);
                return new JSONArray();
            }
        }
    }

    private boolean writeJobs(JSONArray jobs, long nextId) {
        synchronized (STORE_LOCK) {
            return mPrefs.edit()
                    .putString(KEY_JOBS, jobs.toString())
                    .putLong(KEY_NEXT_ID, Math.max(1L, nextId))
                    .commit();
        }
    }

    private static AgentJobRecord fromJson(JSONObject job) {
        return new AgentJobRecord(
                job.optLong("id", -1L),
                job.optString("type", "agent_turn"),
                job.optString("title", ""),
                job.optString("prompt", ""),
                stringify(job.optJSONObject("payload_json")),
                stringify(job.optJSONObject("schedule_json")),
                job.optString("session_target", "main"),
                stringify(job.optJSONObject("delivery_json")),
                job.optString("status", ""),
                job.optLong("created_at", 0L),
                job.optLong("updated_at", 0L),
                job.optLong("next_run_at", 0L),
                job.optLong("running_at", 0L),
                job.optLong("last_run_at", 0L),
                job.optString("last_result", ""),
                job.optInt("failure_count", 0),
                job.optLong("failure_alert_at", 0L),
                job.optString("phase", job.optString("status", "")),
                job.optString("progress_text", ""),
                job.optInt("progress_current", 0),
                job.optInt("progress_total", 0),
                stringify(job.optJSONObject("checkpoint_json")),
                job.optString("pending_confirmation_id", ""),
                stringify(job.optJSONObject("pending_tool_request_json")),
                job.optString("last_surface_id", ""),
                job.optString("resume_token", ""),
                job.optLong("last_event_at", job.optLong("updated_at", 0L)),
                job.optBoolean("unread_result", false),
                job.optLong("paused_at", 0L));
    }

    private static String normalizeType(String type) {
        String clean = safe(type).toLowerCase(Locale.US);
        if ("system_event".equals(clean) || "heartbeat".equals(clean)) {
            return clean;
        }
        return "agent_turn";
    }

    private static String defaultDelivery(String deliveryJson) {
        String clean = safe(deliveryJson).trim();
        return clean.isEmpty() ? "{\"mode\":\"notification\"}" : clean;
    }

    private static JSONObject objectOrEmpty(String raw) {
        try {
            return new JSONObject(raw == null || raw.trim().isEmpty() ? "{}" : raw);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static String stringify(JSONObject object) {
        return object == null ? "{}" : object.toString();
    }

    private static String truncate(String value) {
        String clean = safe(value);
        return clean.length() <= 4000 ? clean : clean.substring(0, 4000);
    }

    private static boolean isQueued(String status) {
        return "active".equals(status) || "queued".equals(status);
    }

    private static String boundedJson(JSONObject object, int maxChars) {
        String raw = object == null ? "{}" : object.toString();
        return raw.length() <= maxChars ? raw : null;
    }

    private static void applyReviewResolution(JSONObject job, JSONObject pending,
            String resolution, String toolResult, long nowMillis) throws JSONException {
        JSONObject checkpoint = job.optJSONObject("checkpoint_json");
        if (checkpoint == null) {
            checkpoint = new JSONObject();
        }
        String boundedResult = truncate(toolResult);
        checkpoint.put("resume_pending", true)
                .put("review_resolution", safe(resolution))
                .put("tool", pending.optString("tool", ""))
                .put("params_digest", pending.optString("params_digest", ""))
                .put("idempotency_key", pending.optString("idempotency_key", ""))
                .put("tool_result", boundedResult)
                .put("resolved_at", nowMillis);
        pending.put("review_state", "resolved")
                .put("resolution", safe(resolution))
                .put("resolved_at", nowMillis);
        job.put("status", "queued")
                .put("phase", "resuming")
                .put("progress_text", "Resuming after review")
                .put("checkpoint_json", checkpoint)
                .put("pending_confirmation_id", "")
                .put("pending_tool_request_json", pending)
                .put("running_at", 0L)
                .put("next_run_at", nowMillis)
                .put("updated_at", nowMillis)
                .put("last_event_at", nowMillis);
    }

    private static boolean ensureLifecycleDefaults(JSONObject job) throws JSONException {
        boolean changed = false;
        long updatedAt = job.optLong("updated_at", System.currentTimeMillis());
        changed |= putDefault(job, "phase", job.optString("status", "queued"));
        changed |= putDefault(job, "progress_text", "");
        changed |= putDefault(job, "progress_current", 0);
        changed |= putDefault(job, "progress_total", 0);
        changed |= putDefault(job, "checkpoint_json", new JSONObject());
        changed |= putDefault(job, "pending_confirmation_id", "");
        changed |= putDefault(job, "pending_tool_request_json", new JSONObject());
        changed |= putDefault(job, "last_surface_id", "");
        changed |= putDefault(job, "resume_token", "");
        changed |= putDefault(job, "last_event_at", updatedAt);
        changed |= putDefault(job, "unread_result", false);
        changed |= putDefault(job, "paused_at", 0L);
        return changed;
    }

    private static boolean putDefault(JSONObject object, String key, Object value)
            throws JSONException {
        if (object.has(key)) {
            return false;
        }
        object.put(key, value);
        return true;
    }

    public static final class ReviewClaim {
        public final AgentJobRecord job;
        public final JSONObject pendingRequest;
        public final boolean approved;

        ReviewClaim(AgentJobRecord job, JSONObject pendingRequest, boolean approved) {
            this.job = job;
            this.pendingRequest = objectOrEmpty(
                    pendingRequest == null ? "{}" : pendingRequest.toString());
            this.approved = approved;
        }
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }

    private static void trimOldTerminalJobs(JSONArray jobs) {
        if (jobs.length() <= MAX_JOBS) {
            return;
        }
        JSONArray kept = new JSONArray();
        int overflow = jobs.length() - MAX_JOBS;
        for (int i = 0; i < jobs.length(); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job == null) {
                continue;
            }
            String status = job.optString("status", "");
            if (overflow > 0
                    && ("completed".equals(status) || "failed".equals(status)
                    || "stopped".equals(status) || "dispatched".equals(status))) {
                overflow--;
                continue;
            }
            kept.put(job);
        }
        while (kept.length() < jobs.length()) {
            jobs.remove(0);
        }
        for (int i = 0; i < kept.length(); i++) {
            try {
                jobs.put(i, kept.get(i));
            } catch (JSONException ignored) {
            }
        }
    }
}
