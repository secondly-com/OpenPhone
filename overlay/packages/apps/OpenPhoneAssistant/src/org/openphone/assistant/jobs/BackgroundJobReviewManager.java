package org.openphone.assistant.jobs;

import android.app.KeyguardManager;
import android.content.Context;
import android.openphone.OpenPhoneAgentManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.OpenPhoneNotificationController;
import org.openphone.assistant.actions.ToolCatalog;
import org.openphone.assistant.agent.FrameworkToolExecutor;
import org.openphone.assistant.context.ContextIndexStore;

import java.util.Iterator;
import java.util.List;

/**
 * Resolves Android-owned background approvals from the exact persisted request.
 *
 * The store's atomic claim is the execution gate: a second notification or UI
 * tap cannot receive a claim and therefore cannot execute the action twice.
 */
public final class BackgroundJobReviewManager {
    private static final String TAG = "OpenPhoneJobReview";

    private BackgroundJobReviewManager() {
    }

    public static String resolve(Context context, String confirmationId, boolean approved) {
        if (context == null) {
            return result("background.review_error", "context_unavailable");
        }
        Context app = context.getApplicationContext();
        KeyguardManager keyguard = app.getSystemService(KeyguardManager.class);
        if (keyguard != null && keyguard.isDeviceLocked()) {
            return result("background.review_unlock_required",
                    "unlock_device_to_review");
        }
        AgentJobStore store = new AgentJobStore(app);
        long now = System.currentTimeMillis();
        AgentJobRecord pendingJob = store.findByConfirmationId(confirmationId);
        boolean selectedExpired = pendingJob != null
                && parseObject(pendingJob.pendingToolRequestJson)
                        .optLong("expires_at", 0L) <= now;
        List<Long> expiringReviewIds = store.reviewJobIdsExpiringBy(now);
        int expired = store.expirePendingReviews(now);
        if (expired > 0) {
            for (Long jobId : expiringReviewIds) {
                OpenPhoneNotificationController.cancelAgentJobReview(
                        app, jobId == null ? -1L : jobId);
            }
            OpenPhoneAgentJobScheduler.checkNow(app);
        }
        if (expired > 0 && selectedExpired) {
            return result("background.review_expired", "approval_expired");
        }
        AgentJobStore.ReviewClaim claim = store.claimReview(confirmationId, approved, now);
        if (claim == null) {
            return result("background.review_already_resolved", "claim_unavailable");
        }

        JSONObject request = claim.pendingRequest;
        String tool = request.optString("tool", "");
        String resolution = approved ? "approved" : "denied";
        String toolResult = approved
                ? result("background.review_error", "execution_not_started")
                : result("background.action_denied", "user_denied");
        String taskId = "";
        OpenPhoneAgentManager manager = null;
        try {
            if (!BackgroundJobReviewContract.verify(claim, System.currentTimeMillis())) {
                resolution = "binding_invalid";
                toolResult = result("background.review_error",
                        "approval_binding_invalid_or_expired");
            } else if (!approved) {
                resolution = "denied";
            } else {
                ToolCatalog catalog = ToolCatalog.get();
                if (!catalog.isLoaded() || !catalog.isAllowedTool(tool)
                        || !catalog.isStateChangingTool(tool)
                        || catalog.isTerminalTool(tool)) {
                    resolution = "tool_invalid";
                    toolResult = result("background.review_error",
                            "tool_not_eligible_for_background_approval");
                } else {
                    manager = app.getSystemService(OpenPhoneAgentManager.class);
                    if (manager == null) {
                        resolution = "framework_unavailable";
                        toolResult = result("background.review_error",
                                "framework_unavailable");
                    } else {
                        taskId = startApprovedTask(manager, claim.job, tool,
                                catalog.capabilityForTool(tool));
                        if (taskId.isEmpty()) {
                            resolution = "task_start_failed";
                            toolResult = result("background.review_error",
                                    "approved_task_start_failed");
                        } else {
                            FrameworkToolExecutor executor =
                                    new FrameworkToolExecutor(app, manager);
                            JSONObject params = request.optJSONObject("params");
                            toolResult = executor.execute(taskId, tool,
                                    params == null ? new JSONObject() : copy(params));
                            toolResult = confirmFrameworkActionIfNeeded(
                                    manager, toolResult);
                            resolution = resultSucceeded(toolResult)
                                    ? "approved" : "approved_action_failed";
                        }
                    }
                }
            }
        } catch (RuntimeException e) {
            resolution = "execution_error";
            toolResult = result("background.review_error",
                    "execution_" + e.getClass().getSimpleName());
            Log.w(TAG, "background review execution failed", e);
        } finally {
            if (manager != null && !taskId.isEmpty()) {
                try {
                    manager.stopTask(taskId,
                            "{\"reason\":\"background_review_execution_finished\"}");
                } catch (RuntimeException ignored) {
                }
            }
        }

        long resolvedAt = System.currentTimeMillis();
        boolean completed = store.completeReview(
                claim.job.id, confirmationId, resolution, toolResult, resolvedAt);
        recordAudit(app, claim, resolution, toolResult, completed, resolvedAt);
        OpenPhoneNotificationController.cancelAgentJobReview(
                app, claim.job.id);
        if (completed) {
            OpenPhoneAgentJobScheduler.checkNow(app);
        }
        return reviewResult(completed, claim.job.id, resolution, toolResult);
    }

    private static String startApprovedTask(OpenPhoneAgentManager manager,
            AgentJobRecord job, String tool, String capability) {
        try {
            JSONObject task = new JSONObject()
                    .put("goal", "Execute approved background action: " + tool)
                    .put("user_visible", false)
                    .put("background_allowed", true)
                    .put("runtime", "builtin")
                    .put("phone_session_id", "background-job:" + job.id)
                    .put("approved_capabilities", new JSONArray()
                            .put("tasks.observe")
                            .put("screen.read.visible")
                            .put(capability));
            return new JSONObject(manager.startTask(task.toString()))
                    .optString("task_id", "");
        } catch (JSONException | RuntimeException e) {
            return "";
        }
    }

    private static String confirmFrameworkActionIfNeeded(
            OpenPhoneAgentManager manager, String rawResult) {
        JSONObject parsed = parseObject(rawResult);
        String pendingActionId = findStringRecursive(parsed, "pending_action_id");
        String status = parsed.optString("status", "");
        String state = parsed.optString("state", "");
        if (pendingActionId.isEmpty()
                || (!status.contains("confirmation")
                        && !state.contains("confirmation"))) {
            return rawResult;
        }
        try {
            return manager.confirmAction(pendingActionId, true);
        } catch (RuntimeException e) {
            return result("background.review_error",
                    "framework_confirmation_failed");
        }
    }

    private static boolean resultSucceeded(String rawResult) {
        JSONObject result = parseObject(rawResult);
        String status = result.optString("status", "");
        return !status.isEmpty()
                && !result.has("error")
                && !status.contains("denied")
                && !status.contains("failed")
                && !status.contains("error")
                && !status.contains("confirmation");
    }

    private static void recordAudit(Context context, AgentJobStore.ReviewClaim claim,
            String resolution, String toolResult, boolean completed, long nowMillis) {
        JSONObject request = claim.pendingRequest;
        JSONObject payload = new JSONObject();
        try {
            payload.put("schema", "openphone.background_review_audit.v1")
                    .put("job_id", claim.job.id)
                    .put("confirmation_id",
                            request.optString("confirmation_id", ""))
                    .put("runtime", request.optString("runtime", ""))
                    .put("phone_session_id",
                            request.optString("phone_session_id", ""))
                    .put("tool", request.optString("tool", ""))
                    .put("params_digest",
                            request.optString("params_digest", ""))
                    .put("binding_digest",
                            request.optString("binding_digest", ""))
                    .put("idempotency_key",
                            request.optString("idempotency_key", ""))
                    .put("resolution", resolution)
                    .put("result_status",
                            parseObject(toolResult).optString("status", ""))
                    .put("checkpoint_committed", completed)
                    .put("resolved_at", nowMillis);
        } catch (JSONException ignored) {
        }
        try {
            new ContextIndexStore(context).recordAgentEvent(
                    "assistant.background_job.review_resolved",
                    "Background action review resolved",
                    resolution,
                    "background-job:" + claim.job.id,
                    payload.toString());
        } catch (RuntimeException e) {
            Log.w(TAG, "background review audit write failed", e);
        }
    }

    private static String reviewResult(boolean completed, long jobId,
            String resolution, String toolResult) {
        try {
            return new JSONObject()
                    .put("status", completed
                            ? "background.review_resolved"
                            : "background.review_commit_failed")
                    .put("job_id", jobId)
                    .put("resolution", resolution)
                    .put("tool_result", parseObject(toolResult))
                    .toString();
        } catch (JSONException e) {
            return result("background.review_error", "result_encoding_failed");
        }
    }

    private static String result(String status, String reason) {
        try {
            return new JSONObject()
                    .put("status", status)
                    .put("reason", reason)
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"background.review_error\"}";
        }
    }

    private static JSONObject copy(JSONObject object) {
        return parseObject(object == null ? "{}" : object.toString());
    }

    private static JSONObject parseObject(String raw) {
        try {
            return new JSONObject(raw == null || raw.trim().isEmpty() ? "{}" : raw);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static String findStringRecursive(Object value, String key) {
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            if (object.has(key)) {
                String found = object.optString(key, "");
                if (!found.isEmpty() && !"null".equals(found)) {
                    return found;
                }
            }
            Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String found = findStringRecursive(object.opt(keys.next()), key);
                if (!found.isEmpty()) {
                    return found;
                }
            }
        } else if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            for (int i = 0; i < array.length(); i++) {
                String found = findStringRecursive(array.opt(i), key);
                if (!found.isEmpty()) {
                    return found;
                }
            }
        }
        return "";
    }
}
