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
import org.openphone.assistant.context.ContextIndexStore;
import org.openphone.assistant.runtime.RuntimeConfig;
import org.openphone.assistant.model.ModelAdapter;
import org.openphone.assistant.model.ModelEndpointConfig;
import org.openphone.assistant.model.OpenAiResponsesAgentAdapter;

import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

public final class OpenPhoneAgentJobScheduler {
    private static final String TAG = "OpenPhoneAgentJobs";
    public static final String ACTION_CHECK =
            "org.openphone.assistant.action.CHECK_AGENT_JOBS";
    private static final long MIN_DELAY_MILLIS = 15_000L;
    private static final long STUCK_TIMEOUT_MILLIS = 10L * 60L * 1000L;
    private static final int MAX_DUE_PER_CHECK = 3;

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
        List<Long> expiringReviewIds = store.reviewJobIdsExpiringBy(now);
        int expired = store.expirePendingReviews(now);
        if (expired > 0) {
            for (Long jobId : expiringReviewIds) {
                OpenPhoneNotificationController.cancelAgentJobReview(
                        appContext, jobId == null ? -1L : jobId);
            }
            Log.i(TAG, "Expired background reviews: " + expired);
        }
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
        AgentJobRecord persistedJob = store.find(job.id);
        if (persistedJob != null) {
            job = persistedJob;
        }
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
        if (parseOrEmpty(job.checkpointJson).optBoolean("resume_pending", false)) {
            backgroundRuntime = AssistantBrainConfig.BUILTIN;
        }
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
        AtomicBoolean reviewPending = new AtomicBoolean(false);
        try {
            final AgentJobRecord runJob = job;
            final String runPrompt = BackgroundJobReviewContract.resumePrompt(runJob);
            String response = agentManager.startTask(taskRequestJson(runJob, runPrompt));
            taskId = parseString(response, "task_id");
            if (taskId == null || taskId.isEmpty()) {
                failJob(context, store, job, "task_start_failed");
                return;
            }
            FrameworkToolExecutor toolExecutor = new FrameworkToolExecutor(context, agentManager);
            OpenAiResponsesAgentAdapter adapter =
                    new OpenAiResponsesAgentAdapter(endpointConfig, true);
            final String activeTaskId = taskId;
            final AtomicBoolean resumeConsumed = new AtomicBoolean(false);
            final AtomicReference<String> setupFailure = new AtomicReference<>("");
            String result = adapter.runTask(activeTaskId, runPrompt,
                    new ModelAdapter.ToolExecutor() {
                @Override
                public String callTool(String toolName, String argumentsJson) {
                    try {
                        JSONObject arguments = new JSONObject(
                                argumentsJson == null ? "{}" : argumentsJson);
                        if (isStateChangingBackgroundTool(toolName)) {
                            if (BackgroundJobReviewContract.matchesResume(
                                    runJob, toolName, arguments)
                                    && resumeConsumed.compareAndSet(false, true)) {
                                return BackgroundJobReviewContract.resumeToolResult(runJob);
                            }
                            long requestedAt = System.currentTimeMillis();
                            BackgroundJobReviewContract.PreparedRequest prepared =
                                    BackgroundJobReviewContract.prepare(
                                            runJob, toolName, arguments, requestedAt);
                            if (prepared == null) {
                                setupFailure.compareAndSet("",
                                        "review_request_rejected_sensitive_or_oversized");
                                return "{\"status\":\"denied\","
                                        + "\"code\":\"background.review_request_rejected\","
                                        + "\"reason\":\"sensitive_or_oversized_checkpoint\"}";
                            }
                            boolean saved = store.markAwaitingReview(
                                    runJob.id,
                                    prepared.checkpoint,
                                    prepared.pendingRequest,
                                    prepared.confirmationId,
                                    prepared.resumeToken,
                                    "Approval needed: " + toolName,
                                    requestedAt);
                            if (!saved) {
                                setupFailure.compareAndSet("",
                                        "review_checkpoint_persist_failed");
                                return "{\"status\":\"denied\","
                                        + "\"code\":\"background.review_persist_failed\"}";
                            }
                            reviewPending.set(true);
                            OpenPhoneNotificationController.showAgentJobReview(
                                    context, runJob, prepared.pendingRequest);
                            recordReviewRequested(
                                    context, runJob, prepared, toolName, requestedAt);
                            return confirmationRequired(prepared, toolName);
                        }
                        return toolExecutor.execute(activeTaskId, toolName, arguments);
                    } catch (JSONException e) {
                        return "{\"status\":\"error\",\"reason\":\"bad_tool_json\"}";
                    }
                }

                @Override
                public boolean isCancelled() {
                    AgentJobRecord current = store.find(runJob.id);
                    return current == null || "stopped".equals(current.status);
                }
            });
            if (reviewPending.get()) {
                Log.i(TAG, "Background job awaiting review: " + runJob.id);
            } else if (!setupFailure.get().isEmpty()) {
                failJob(context, store, runJob, setupFailure.get());
            } else {
                boolean completed = store.markCompleted(
                        runJob.id, result, System.currentTimeMillis());
                if (completed && shouldNotify(runJob)) {
                    OpenPhoneNotificationController.showAgentJobFinished(
                            context, runJob, result);
                }
            }
        } catch (RuntimeException e) {
            if (!reviewPending.get()) {
                failJob(context, store, job,
                        "job_error:" + e.getClass().getSimpleName());
            }
        } finally {
            if (agentManager != null && taskId != null && !taskId.isEmpty()) {
                try {
                    agentManager.stopTask(taskId, reviewPending.get()
                            ? "{\"reason\":\"background_job_paused_for_review\"}"
                            : "{\"reason\":\"background_job_finished\"}");
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
        boolean failed = store.markFailed(
                job.id, reason, nextRunAt, failures, failureAlertAt, now);
        if (!failed) {
            scheduleNext(context, store);
            return;
        }
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

    private static String taskRequestJson(AgentJobRecord job, String prompt) {
        try {
            return new JSONObject()
                    .put("goal", prompt == null ? job.prompt : prompt)
                    .put("user_visible", false)
                    .put("background_allowed", true)
                    .put("runtime", "builtin")
                    .put("phone_session_id", "background-job:" + job.id)
                    .put("approved_capabilities",
                            new org.json.JSONArray()
                                    .put("tasks.observe")
                                    .put("screen.read.visible"))
                    .toString();
        } catch (JSONException e) {
            return "{}";
        }
    }

    private static String confirmationRequired(
            BackgroundJobReviewContract.PreparedRequest prepared, String toolName) {
        try {
            return new JSONObject()
                    .put("status", "confirmation_required")
                    .put("code", "background.confirmation_required")
                    .put("reason", "state_changing_background_tool")
                    .put("tool", toolName)
                    .put("confirmation_id", prepared.confirmationId)
                    .put("params_digest", prepared.paramsDigest)
                    .put("binding_digest", prepared.bindingDigest)
                    .put("expires_at",
                            prepared.pendingRequest.optLong("expires_at", 0L))
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"confirmation_required\","
                    + "\"code\":\"background.confirmation_required\"}";
        }
    }

    private static void recordReviewRequested(Context context, AgentJobRecord job,
            BackgroundJobReviewContract.PreparedRequest prepared,
            String toolName, long requestedAt) {
        JSONObject payload = new JSONObject();
        try {
            payload.put("schema", "openphone.background_review_audit.v1")
                    .put("job_id", job.id)
                    .put("confirmation_id", prepared.confirmationId)
                    .put("runtime", "builtin")
                    .put("phone_session_id", "background-job:" + job.id)
                    .put("tool", toolName)
                    .put("params_digest", prepared.paramsDigest)
                    .put("binding_digest", prepared.bindingDigest)
                    .put("expires_at",
                            prepared.pendingRequest.optLong("expires_at", 0L))
                    .put("requested_at", requestedAt);
        } catch (JSONException ignored) {
        }
        try {
            new ContextIndexStore(context).recordAgentEvent(
                    "assistant.background_job.review_requested",
                    "Background action needs review",
                    toolName,
                    "background-job:" + job.id,
                    payload.toString());
        } catch (RuntimeException e) {
            Log.w(TAG, "background review audit write failed", e);
        }
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
