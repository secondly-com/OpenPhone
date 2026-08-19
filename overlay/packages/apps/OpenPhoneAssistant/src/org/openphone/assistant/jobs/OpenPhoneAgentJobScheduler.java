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
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

public final class OpenPhoneAgentJobScheduler {
    private static final String TAG = "OpenPhoneAgentJobs";
    public static final String ACTION_CHECK =
            "org.openphone.assistant.action.CHECK_AGENT_JOBS";
    private static final long MIN_DELAY_MILLIS = 15_000L;
    private static final long STUCK_TIMEOUT_MILLIS = 10L * 60L * 1000L;
    private static final int MAX_DUE_PER_CHECK = 3;
    private static final ConcurrentHashMap<Long, AtomicBoolean> sCancelFlags =
            new ConcurrentHashMap<>();

    private OpenPhoneAgentJobScheduler() {}

    /** Signals a running background job to stop at its next isCancelled() check. */
    public static void cancelJob(String jobId) {
        Long id = parseJobId(jobId);
        AtomicBoolean flag = id == null ? null : sCancelFlags.get(id);
        if (flag != null) {
            flag.set(true);
        }
    }

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
                runJob(context, job);
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
        AtomicBoolean cancelFlag = sCancelFlags.computeIfAbsent(job.id,
                id -> new AtomicBoolean(false));
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
            String result = adapter.runTask(activeTaskId, job.prompt,
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
                    return cancelFlag.get() || Thread.currentThread().isInterrupted();
                }
            });
            store.markCompleted(job.id, result, System.currentTimeMillis());
            if (shouldNotify(job)) {
                OpenPhoneNotificationController.showAgentJobFinished(context, job, result);
            }
        } catch (RuntimeException e) {
            failJob(context, store, job, "job_error:" + e.getClass().getSimpleName());
        } finally {
            sCancelFlags.remove(job.id);
            if (agentManager != null && taskId != null && !taskId.isEmpty()) {
                try {
                    agentManager.stopTask(taskId, "{\"reason\":\"background_job_finished\"}");
                } catch (RuntimeException ignored) {
                }
            }
            scheduleNext(context, store);
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
        store.markFailed(job.id, reason, nextRunAt, failures, failureAlertAt, now);
        Log.w(TAG, "Agent job failed: " + job.id + " " + reason);
        if (failures >= 3 && shouldNotify(job)) {
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

    private static Long parseJobId(String jobId) {
        if (jobId == null) {
            return null;
        }
        try {
            return Long.parseLong(jobId.trim());
        } catch (NumberFormatException e) {
            return null;
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
