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

    private final SharedPreferences mPrefs;

    public AgentJobStore(Context context) {
        mPrefs = context.getApplicationContext().getSharedPreferences(PREFS,
                Context.MODE_PRIVATE);
    }

    public synchronized long createJob(String type, String title, String prompt,
            String payloadJson, String scheduleJson, String sessionTarget,
            String deliveryJson, long nextRunAtMillis) {
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
                    .put("delivery_json", objectOrEmpty(defaultDelivery(deliveryJson)))
                    .put("status", "active")
                    .put("created_at", now)
                    .put("updated_at", now)
                    .put("next_run_at", Math.max(0L, nextRunAtMillis))
                    .put("running_at", 0L)
                    .put("last_run_at", 0L)
                    .put("last_result", "")
                    .put("failure_count", 0)
                    .put("failure_alert_at", 0L);
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

    public synchronized List<AgentJobRecord> due(long nowMillis, int limit) {
        List<AgentJobRecord> out = new ArrayList<>();
        JSONArray jobs = readJobs();
        for (int i = 0; i < jobs.length() && out.size() < Math.max(1, limit); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job == null || !"active".equals(job.optString("status", ""))) {
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
            if (job == null || !"active".equals(job.optString("status", ""))) {
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
            if (!"active".equals(job.optString("status", ""))) {
                return false;
            }
            job.put("status", "running")
                    .put("running_at", nowMillis)
                    .put("updated_at", nowMillis);
            return true;
        });
    }

    /**
     * Current stored status for a job, or "" when the job no longer exists.
     * Running jobs poll this so a user stop ({@link #stop}) or a stuck-run
     * repair actually cancels the in-flight run instead of being ignored.
     */
    public synchronized String statusOf(long id) {
        JSONArray jobs = readJobs();
        for (int i = 0; i < jobs.length(); i++) {
            JSONObject job = jobs.optJSONObject(i);
            if (job != null && job.optLong("id", -1L) == id) {
                return job.optString("status", "");
            }
        }
        return "";
    }

    public synchronized boolean markCompleted(long id, String result, long nowMillis) {
        return updateJob(id, job -> {
            // Only a run the store still considers live may record completion.
            // Without this guard a finishing run would resurrect a job the
            // user stopped (or that stuck-run repair already rescheduled).
            if (!"running".equals(job.optString("status", ""))) {
                return false;
            }
            JSONObject schedule = job.optJSONObject("schedule_json");
            long interval = schedule == null ? 0L : schedule.optLong("interval_ms", 0L);
            job.put("status", interval > 0 ? "active" : "completed")
                    .put("updated_at", nowMillis)
                    .put("last_run_at", nowMillis)
                    .put("running_at", 0L)
                    .put("last_result", truncate(result))
                    .put("failure_count", 0)
                    .put("failure_alert_at", 0L);
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
                    .put("updated_at", nowMillis)
                    .put("last_run_at", nowMillis)
                    .put("running_at", 0L)
                    .put("last_result", truncate(result))
                    .put("next_run_at", 0L);
            return true;
        });
    }

    public synchronized boolean markFailed(long id, String reason, long nextRunAtMillis,
            int failureCount, long failureAlertAtMillis, long nowMillis) {
        return updateJob(id, job -> {
            // Same live-run guard as markCompleted: a failure from a run the
            // user already stopped must not reactivate the job for retry.
            if (!"running".equals(job.optString("status", ""))) {
                return false;
            }
            job.put("status", "active")
                    .put("updated_at", nowMillis)
                    .put("last_run_at", nowMillis)
                    .put("running_at", 0L)
                    .put("last_result", truncate(reason))
                    .put("next_run_at", nextRunAtMillis)
                    .put("failure_count", Math.max(1, failureCount))
                    .put("failure_alert_at", failureAlertAtMillis);
            return true;
        });
    }

    public synchronized boolean stop(long id) {
        long now = System.currentTimeMillis();
        return updateJob(id, job -> {
            job.put("status", "stopped")
                    .put("updated_at", now)
                    .put("running_at", 0L)
                    .put("next_run_at", 0L);
            return true;
        });
    }

    public synchronized int repairStuck(long staleBeforeMillis, long nowMillis) {
        final int[] repaired = {0};
        updateAllJobs(job -> {
            if ("running".equals(job.optString("status", ""))
                    && job.optLong("running_at", 0L) > 0
                    && job.optLong("running_at", 0L) < staleBeforeMillis) {
                int failures = job.optInt("failure_count", 0) + 1;
                job.put("status", "active")
                        .put("running_at", 0L)
                        .put("updated_at", nowMillis)
                        .put("last_result", "stuck_running_repaired")
                        .put("failure_count", failures)
                        .put("next_run_at", nowMillis + backoffMillis(failures));
                repaired[0]++;
                return true;
            }
            return false;
        });
        return repaired[0];
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
                    .put("failure_alert_at", job.failureAlertAtMillis);
        } catch (JSONException ignored) {
        }
        return out;
    }

    private interface JobUpdater {
        boolean update(JSONObject job) throws JSONException;
    }

    private boolean updateJob(long id, JobUpdater updater) {
        final boolean[] changed = {false};
        updateAllJobs(job -> {
            if (job.optLong("id", -1L) != id) {
                return false;
            }
            changed[0] = updater.update(job);
            return changed[0];
        });
        return changed[0];
    }

    private boolean updateAllJobs(JobUpdater updater) {
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

    private JSONArray readJobs() {
        String raw = mPrefs.getString(KEY_JOBS, "[]");
        try {
            return new JSONArray(raw == null || raw.isEmpty() ? "[]" : raw);
        } catch (JSONException e) {
            Log.w(TAG, "agent job store corrupt; ignoring", e);
            return new JSONArray();
        }
    }

    private boolean writeJobs(JSONArray jobs, long nextId) {
        return mPrefs.edit()
                .putString(KEY_JOBS, jobs.toString())
                .putLong(KEY_NEXT_ID, Math.max(1L, nextId))
                .commit();
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
                job.optLong("failure_alert_at", 0L));
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
