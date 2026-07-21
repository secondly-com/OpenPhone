package org.openphone.assistant.orchestrator;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.model.ModelAdapter;

import java.util.Locale;

/**
 * Model-first decision point for every user message. The model returns a
 * structured orchestrator_decision; deterministic logic is limited to true
 * safety rails (stop/cancel interception and the empty-message case). All
 * other routing — chat versus screen question versus one-shot tool versus
 * full agent task — is the model's call.
 */
public final class OpenPhoneOrchestrator {
    public OrchestratorDecision decide(ModelAdapter adapter, String userMessage,
            boolean hasActiveTask, OperatingMode operatingMode,
            String recentConversationJson) {
        OperatingMode mode = operatingMode == null ? OperatingMode.REVIEWED : operatingMode;
        String message = userMessage == null ? "" : userMessage.trim();
        if (message.isEmpty()) {
            return OrchestratorDecision.answer(
                    "Ask me anything, or tell me what to do on this phone.",
                    "empty_message", mode);
        }
        if (isStopIntent(normalize(message))) {
            return OrchestratorDecision.stop("user_stop_intent", mode);
        }
        if (adapter == null) {
            return OrchestratorDecision.answer("", "no_model_adapter", mode);
        }
        String decisionJson = adapter.decideOrchestration(message, hasActiveTask,
                recentConversationJson == null ? "" : recentConversationJson);
        return parseDecision(decisionJson, message, mode);
    }

    private static OrchestratorDecision parseDecision(String decisionJson,
            String originalMessage, OperatingMode operatingMode) {
        try {
            JSONObject decision = new JSONObject(decisionJson == null ? "{}" : decisionJson);
            String mode = decision.optString("mode", OrchestratorDecision.MODE_ANSWER);
            if (!OrchestratorDecision.isValidMode(mode)) {
                mode = OrchestratorDecision.MODE_ANSWER;
            }
            String reply = decision.optString("reply", "");
            String reason = decision.optString("reason", "");
            String deliverySurface = decision.optString("delivery_surface", "chat");
            if (OrchestratorDecision.MODE_STOP.equals(mode)) {
                return OrchestratorDecision.stop(reason, operatingMode);
            }
            if (OrchestratorDecision.MODE_INSPECT_SCREEN.equals(mode)) {
                return OrchestratorDecision.inspectScreen(reason, operatingMode);
            }
            if (OrchestratorDecision.MODE_CLARIFY.equals(mode)) {
                return OrchestratorDecision.clarify(
                        reply.isEmpty() ? "Can you tell me more about what you want?" : reply,
                        reason, operatingMode);
            }
            if (OrchestratorDecision.MODE_RETRIEVE.equals(mode)
                    || OrchestratorDecision.MODE_WATCH.equals(mode)
                    || OrchestratorDecision.MODE_MEMORY.equals(mode)
                    || OrchestratorDecision.MODE_ACT.equals(mode)) {
                JSONArray proposedActions = sanitizeProposedActions(
                        decision.optJSONArray("proposed_actions"));
                if (proposedActions.length() > 0) {
                    return OrchestratorDecision.oneShot(mode, proposedActions,
                            deliverySurface, reason, operatingMode);
                }
                if (OrchestratorDecision.MODE_ACT.equals(mode)) {
                    String goal = decision.optString("task_goal", "").trim();
                    return OrchestratorDecision.agentTask(
                            goal.isEmpty() ? originalMessage : goal, reason, operatingMode);
                }
                // watch/memory/retrieve without a concrete tool call: let the
                // full agent loop figure it out rather than guessing here.
                return OrchestratorDecision.agentTask(originalMessage,
                        reason.isEmpty() ? "missing_proposed_actions" : reason,
                        operatingMode);
            }
            return OrchestratorDecision.answer(nonDoneReply(reply), reason, operatingMode);
        } catch (JSONException e) {
            return OrchestratorDecision.answer("", "bad_decision_json", operatingMode);
        }
    }

    /** Keeps only well-formed {"tool": ..., "arguments": {...}} entries. */
    private static JSONArray sanitizeProposedActions(JSONArray proposedActions) {
        JSONArray sanitized = new JSONArray();
        if (proposedActions == null) {
            return sanitized;
        }
        for (int i = 0; i < proposedActions.length(); i++) {
            JSONObject action = proposedActions.optJSONObject(i);
            if (action == null) {
                continue;
            }
            String tool = action.optString("tool", "").trim();
            if (tool.isEmpty()) {
                continue;
            }
            JSONObject arguments = action.optJSONObject("arguments");
            try {
                sanitized.put(new JSONObject()
                        .put("tool", tool)
                        .put("arguments", arguments == null ? new JSONObject() : arguments));
            } catch (JSONException ignored) {
            }
        }
        return sanitized;
    }

    private static String nonDoneReply(String reply) {
        String text = reply == null ? "" : reply.trim();
        String normalized = normalize(text);
        if (normalized.equals("done") || normalized.equals("done.")) {
            return "";
        }
        return text;
    }

    private static boolean isStopIntent(String text) {
        return text.equals("stop") || text.equals("cancel") || text.equals("abort")
                || text.equals("nevermind") || text.equals("never mind")
                || text.equals("stop agent") || text.equals("cancel task")
                || text.equals("stop task") || text.equals("stop listening");
    }

    private static String normalize(String message) {
        String text = message == null ? "" : message.trim().toLowerCase(Locale.US);
        while (text.contains("  ")) {
            text = text.replace("  ", " ");
        }
        while (!text.isEmpty() && !Character.isLetterOrDigit(text.charAt(0))) {
            text = text.substring(1).trim();
        }
        while (!text.isEmpty() && ".!?".indexOf(text.charAt(text.length() - 1)) >= 0) {
            text = text.substring(0, text.length() - 1).trim();
        }
        return text;
    }
}
