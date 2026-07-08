package org.openphone.assistant.jobs;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.UserManager;
import android.provider.Settings;
import android.util.Log;

import android.openphone.OpenPhoneAgentManager;

import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.OpenPhoneNotificationController;
import org.openphone.assistant.AssistantBrainConfig;
import org.openphone.assistant.OpenPhoneAssistantService;
import org.openphone.assistant.actions.ToolCatalog;
import org.openphone.assistant.agent.FrameworkToolExecutor;
import org.openphone.assistant.runtime.RuntimeConfig;
import org.openphone.assistant.model.ModelAdapter;
import org.openphone.assistant.model.ModelEndpointConfig;
import org.openphone.assistant.model.OpenAiResponsesAgentAdapter;

import java.util.List;

public final class OpenPhoneAgentJobScheduler {
    private static final String TAG = "OpenPhoneAgentJobs";
    public static final String ACTION_CHECK =
            "org.openphone.assistant.action.CHECK_AGENT_JOBS";
    private static final long MIN_DELAY_MILLIS = 15_000L;
    private static final long STUCK_TIMEOUT_MILLIS = 10L * 60L * 1000L;
    private static final int MAX_DUE_PER_CHECK = 3;
    private static final long CANCEL_POLL_MILLIS = 2_000L;

    private OpenPhoneAgentJobScheduler() {}

    public static void checkNow(Context context) {
        if (context == null) {
            return;
        }
        if (!isUserUnlocked(context)) {
            return;
        }
        Context appContext = context.getApplicationContext();
        AgentJobStore store = new AgentJobStore(appContext);
        long now = System.currentTimeMillis();
        int repaired = store.repairStuck(now - STUCK_TIMEOUT_MILLIS, now);
        if (repaired > 0) {
            Log.w(TAG, "Repaired stuck jobs: " + repaired);
        }
        List<AgentJobRecord> due = store.due(now, MAX_DUE_PER_CHECK);
        for (AgentJobRecord job : due) {
            fireJob(appContext, store, job, now);
        }
        scheduleNext(appContext, store);
    }

    public static void scheduleNext(Context context) {
        if (context == null) {
            return;
        }
        if (!isUserUnlocked(context)) {
            return;
        }
        scheduleNext(context.getApplicationContext(), new AgentJobStore(context));
    }

    private static void fireJob(Context context, AgentJobStore store,
            AgentJobRecord job, long now) {
        if (!store.markRunning(job.id, now)) {
            return;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    runJob(context, job);
                } catch (RuntimeException e) {
                    // An uncaught exception here (broker outage, store
                    // corruption, notification failure) would kill the
                    // whole assistant process, not just this job. Record
                    // the failure with backoff and keep the runtime alive.
                    Log.e(TAG, "Agent job crashed: " + job.id, e);
                    try {
                        failJob(context, new AgentJobStore(context), job,
                                "job_crash:" + e.getClass().getSimpleName());
                    } catch (RuntimeException inner) {
                        Log.e(TAG, "Agent job crash handling failed: " + job.id, inner);
                    }
                }
            }
        }, "OpenPhoneAgentJob-" + job.id).start();
    }

    private static void runJob(Context context, AgentJobRecord job) {
        AgentJobStore store = new AgentJobStore(context);
        long now = System.currentTimeMillis();
        if ("heartbeat".equals(job.type)) {
            store.markCompleted(job.id, "heartbeat", now);
            scheduleNext(context, store);
            return;
        }
        if (!"agent_turn".equals(job.type)) {
            store.markCompleted(job.id, "system_event_recorded", now);
            scheduleNext(context, store);
            return;
        }
        RuntimeConfig runtimeConfig = RuntimeConfig.load(context);
        String backgroundRuntime = AssistantBrainConfig.routeBackgroundRuntime(
                context, runtimeConfig);
        if (!AssistantBrainConfig.BUILTIN.equals(backgroundRuntime)) {
            sendBackgroundJobToRuntime(context, store, job, backgroundRuntime, runtimeConfig);
            scheduleNext(context, store);
            return;
        }
        OpenPhoneAgentManager agentManager = context.getSystemService(OpenPhoneAgentManager.class);
        if (agentManager == null) {
            failJob(context, store, job, "framework_unavailable");
            return;
        }
        ModelEndpointConfig endpointConfig = backgroundEndpointConfig(context);
        if (!endpointConfig.isConfigured()) {
            failJob(context, store, job, "model_unconfigured");
            return;
        }
        String taskId = null;
        try {
            String response = agentManager.startTask(taskRequestJson(job));
            taskId = parseString(response, "task_id");
            if (taskId == null || taskId.isEmpty()) {
                failJob(context, store, job, "task_start_failed");
                return;
            }
            FrameworkToolExecutor toolExecutor = new FrameworkToolExecutor(context, agentManager);
            OpenAiResponsesAgentAdapter adapter = new OpenAiResponsesAgentAdapter(endpointConfig);
            final String activeTaskId = taskId;
            final JobCancellationSignal cancellation = new JobCancellationSignal(store, job.id);
            Thread cancelWatchdog = startCancelWatchdog(adapter, cancellation, job.id);
            String result;
            try {
                result = adapter.runTask(activeTaskId, job.prompt,
                        new ModelAdapter.ToolExecutor() {
                    @Override
                    public String callTool(String toolName, String argumentsJson) {
                        if (isStateChangingBackgroundTool(toolName)) {
                            return "{\"status\":\"background.confirmation_required\","
                                    + "\"reason\":\"state_changing_tool_blocked\","
                                    + "\"tool\":\"" + jsonEscape(toolName) + "\"}";
                        }
                        try {
                            return toolExecutor.execute(activeTaskId, toolName,
                                    new JSONObject(argumentsJson == null ? "{}" : argumentsJson));
                        } catch (JSONException e) {
                            return "{\"status\":\"error\",\"reason\":\"bad_tool_json\"}";
                        }
                    }

                    @Override
                    public boolean isCancelled() {
                        return cancellation.isCancelled();
                    }
                });
            } finally {
                cancellation.finish();
                cancelWatchdog.interrupt();
            }
            // markCompleted refuses to record when the job is no longer
            // "running" (user stop or stuck-run repair), so a cancelled run
            // neither resurrects the job nor notifies as if it finished.
            boolean recorded = store.markCompleted(job.id, result, System.currentTimeMillis());
            if (recorded && shouldNotify(job)) {
                OpenPhoneNotificationController.showAgentJobFinished(context, job, result);
            }
        } catch (RuntimeException e) {
            failJob(context, store, job, "job_error:" + e.getClass().getSimpleName());
        } finally {
            if (agentManager != null && taskId != null && !taskId.isEmpty()) {
                try {
                    agentManager.stopTask(taskId, "{\"reason\":\"background_job_finished\"}");
                } catch (RuntimeException ignored) {
                }
            }
            scheduleNext(context, store);
        }
    }

    /**
     * Aborts the in-flight model call once the job leaves the "running"
     * status. The adapter checks {@code isCancelled()} between steps and
     * while backing off between HTTP retries, but only a hard
     * {@code adapter.cancel()} can break a thread blocked on a stuck
     * upstream read, so a dedicated watcher does that.
     */
    private static Thread startCancelWatchdog(OpenAiResponsesAgentAdapter adapter,
            JobCancellationSignal cancellation, long jobId) {
        Thread watchdog = new Thread(new Runnable() {
            @Override
            public void run() {
                while (!cancellation.isFinished()) {
                    if (cancellation.isCancelled()) {
                        adapter.cancel();
                        return;
                    }
                    try {
                        Thread.sleep(CANCEL_POLL_MILLIS);
                    } catch (InterruptedException e) {
                        return;
                    }
                }
            }
        }, "OpenPhoneAgentJobCancel-" + jobId);
        watchdog.setDaemon(true);
        watchdog.start();
        return watchdog;
    }

    /**
     * Live cancellation signal for one job run, backed by the job store:
     * the run counts as cancelled as soon as the stored status leaves
     * "running" (user called background_job_stop, or stuck-run repair
     * reclaimed the job). Store reads are throttled so per-step
     * isCancelled() checks stay cheap, and store failures are treated as
     * "not cancelled" rather than crashing the job thread.
     */
    static final class JobCancellationSignal {
        private final AgentJobStore mStore;
        private final long mJobId;
        private volatile boolean mCancelled;
        private volatile boolean mFinished;
        private long mLastPolledAtMillis;

        JobCancellationSignal(AgentJobStore store, long jobId) {
            mStore = store;
            mJobId = jobId;
        }

        boolean isCancelled() {
            if (mCancelled) {
                return true;
            }
            long now = System.currentTimeMillis();
            synchronized (this) {
                if (now - mLastPolledAtMillis < CANCEL_POLL_MILLIS) {
                    return false;
                }
                mLastPolledAtMillis = now;
            }
            try {
                if (!"running".equals(mStore.statusOf(mJobId))) {
                    mCancelled = true;
                }
            } catch (RuntimeException e) {
                Log.w(TAG, "Cancellation poll failed for job " + mJobId, e);
            }
            return mCancelled;
        }

        void finish() {
            mFinished = true;
        }

        boolean isFinished() {
            return mFinished;
        }
    }

    private static boolean isStateChangingBackgroundTool(String toolName) {
        if (ToolCatalog.get().isTerminalTool(toolName)) {
            return false;
        }
        return ToolCatalog.get().isStateChangingTool(toolName);
    }

    private static void sendBackgroundJobToRuntime(Context context, AgentJobStore store,
            AgentJobRecord job, String runtime, RuntimeConfig config) {
        String cleanRuntime = runtime == null ? "" : runtime.trim().toLowerCase(java.util.Locale.US);
        if (cleanRuntime.isEmpty() || !config.configured(cleanRuntime)) {
            failJob(context, store, job,
                    "runtime_background_dispatch_unavailable:" + cleanRuntime);
            return;
        }
        try {
            Intent intent = new Intent(context, OpenPhoneAssistantService.class);
            intent.setAction(OpenPhoneAssistantService.ACTION_REQUEST_RUNTIME_ATTENTION);
            intent.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_RUNTIME,
                    cleanRuntime);
            intent.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_TEXT,
                    job.prompt + "\n\nBackground job payload JSON:\n"
                            + (job.payloadJson == null ? "{}" : job.payloadJson));
            intent.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_SOURCE,
                    "background_job");
            intent.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_AUTONOMY,
                    "ask_before_action");
            intent.putExtra(OpenPhoneAssistantService.EXTRA_RUNTIME_ATTENTION_INCLUDE_SCREEN,
                    true);
            context.startService(intent);
            store.markDispatched(job.id, "runtime_attention.sent:" + cleanRuntime,
                    System.currentTimeMillis());
            if (shouldNotify(job)) {
                OpenPhoneNotificationController.showAgentJobFinished(context, job,
                        AssistantBrainConfig.label(cleanRuntime)
                                + " accepted this background job.");
            }
        } catch (RuntimeException e) {
            failJob(context, store, job,
                    "runtime_background_dispatch_failed:" + cleanRuntime + ":"
                            + e.getClass().getSimpleName());
        }
    }

    private static void failJob(Context context, AgentJobStore store,
            AgentJobRecord job, String reason) {
        long now = System.currentTimeMillis();
        int failures = job.failureCount + 1;
        long nextRunAt = now + AgentJobStore.backoffMillis(failures);
        long failureAlertAt = failures >= 3 ? now : job.failureAlertAtMillis;
        boolean recorded = store.markFailed(job.id, reason, nextRunAt, failures,
                failureAlertAt, now);
        Log.w(TAG, "Agent job failed: " + job.id + " " + reason
                + (recorded ? "" : " (not recorded; job no longer running)"));
        if (recorded && failures >= 3 && shouldNotify(job)) {
            OpenPhoneNotificationController.showAgentJobFailed(context, job, reason);
        }
        scheduleNext(context, store);
    }

    private static void scheduleNext(Context context, AgentJobStore store) {
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms == null) {
            return;
        }
        PendingIntent pending = checkPendingIntent(context);
        long now = System.currentTimeMillis();
        long nextDueAt = store.nextRunAt(now);
        if (nextDueAt <= 0) {
            alarms.cancel(pending);
            return;
        }
        long triggerAt = Math.max(nextDueAt, now + MIN_DELAY_MILLIS);
        try {
            alarms.set(AlarmManager.RTC_WAKEUP, triggerAt, pending);
            Log.i(TAG, "Scheduled agent job check at " + triggerAt);
        } catch (RuntimeException e) {
            Log.w(TAG, "Failed to schedule agent job check", e);
        }
    }

    private static PendingIntent checkPendingIntent(Context context) {
        Intent intent = new Intent(context, OpenPhoneAgentJobReceiver.class);
        intent.setAction(ACTION_CHECK);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(context, 7101, intent, flags);
    }

    private static boolean isUserUnlocked(Context context) {
        UserManager userManager = context.getSystemService(UserManager.class);
        return userManager == null || userManager.isUserUnlocked();
    }

    private static ModelEndpointConfig backgroundEndpointConfig(Context context) {
        if (!"userdebug".equals(Build.TYPE) && !"eng".equals(Build.TYPE)) {
            return ModelEndpointConfig.directOpenAi("");
        }
        String apiKey = Settings.Secure.getString(context.getContentResolver(),
                "openphone_dev_openai_api_key");
        return ModelEndpointConfig.directOpenAi(apiKey == null ? "" : apiKey);
    }

    private static String taskRequestJson(AgentJobRecord job) {
        return "{"
                + "\"goal\":\"" + jsonEscape(job.prompt) + "\","
                + "\"user_visible\":false,"
                + "\"background_allowed\":true,"
                + "\"approved_capabilities\":[\"tasks.observe\",\"screen.read.visible\"]"
                + "}";
    }

    private static boolean shouldNotify(AgentJobRecord job) {
        JSONObject delivery = parseOrEmpty(job.deliveryJson);
        String mode = delivery.optString("mode", "notification");
        return !"none".equals(mode) && !"silent".equals(mode);
    }

    private static JSONObject parseOrEmpty(String json) {
        try {
            return new JSONObject(json == null || json.isEmpty() ? "{}" : json);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static String parseString(String json, String key) {
        try {
            return new JSONObject(json == null ? "{}" : json).optString(key, "");
        } catch (JSONException e) {
            return "";
        }
    }

    private static String jsonEscape(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
