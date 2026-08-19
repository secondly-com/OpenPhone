package org.openphone.assistant.model;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import org.openphone.assistant.actions.ToolCatalog;

public final class OpenAiResponsesAgentAdapter implements ModelAdapter {
    // gpt-5.5 was way too slow for interactive voice replies (multi-second
    // latency on simple "what's on my screen" answers). gpt-5.4-mini is one
    // generation back but is the fastest mini variant currently published —
    // gpt-5.5 has no mini sibling — and answer quality is fine for the agent
    // surface where vision + tool-routing matter more than reasoning depth.
    //
    // To experiment with other models without a rebuild, write the model id
    // to /data/local/tmp/openphone_model_override (no trailing newline):
    //   adb shell 'echo -n gpt-5-mini > /data/local/tmp/openphone_model_override'
    //   # restore default by deleting the file:
    //   adb shell rm /data/local/tmp/openphone_model_override
    // The override is consulted lazily on each call, so changes take effect
    // on the next request without restarting the assistant.
    private static final String DEFAULT_MODEL = "gpt-5.4-mini";
    private static final java.io.File MODEL_OVERRIDE_FILE =
            new java.io.File("/data/local/tmp/openphone_model_override");

    private static String resolvedModel() {
        if (!MODEL_OVERRIDE_FILE.exists() || !MODEL_OVERRIDE_FILE.canRead()) {
            return DEFAULT_MODEL;
        }
        try {
            byte[] raw = java.nio.file.Files.readAllBytes(MODEL_OVERRIDE_FILE.toPath());
            String override = new String(raw, StandardCharsets.UTF_8).trim();
            return override.isEmpty() ? DEFAULT_MODEL : override;
        } catch (java.io.IOException ignored) {
            return DEFAULT_MODEL;
        }
    }
    // Legacy alias kept so the rest of the file does not need to change every
    // call site at once. It is computed lazily via the static helper above so
    // override changes take effect on the next call without restarting the
    // assistant.
    private static String MODEL() { return resolvedModel(); }
    private static final int MAX_STEPS = 25;
    private static final int MAX_CONSECUTIVE_TOOL_ERRORS = 2;
    private static final int MAX_CONSECUTIVE_NO_PROGRESS_ACTIONS = 2;
    private static final long MAX_DURATION_MS = 300000;

    private final ModelEndpointConfig mEndpointConfig;
    private final boolean mFullYolo;
    private volatile boolean mCancelled;
    private volatile HttpURLConnection mActiveConnection;

    public OpenAiResponsesAgentAdapter(String apiKey) {
        this(ModelEndpointConfig.directOpenAi(apiKey), false);
    }

    public OpenAiResponsesAgentAdapter(ModelEndpointConfig endpointConfig) {
        this(endpointConfig, false);
    }

    public OpenAiResponsesAgentAdapter(ModelEndpointConfig endpointConfig, boolean fullYolo) {
        mEndpointConfig = endpointConfig == null
                ? ModelEndpointConfig.directOpenAi("") : endpointConfig;
        mFullYolo = fullYolo;
    }

    @Override
    public String name() {
        return mEndpointConfig.providerName();
    }

    @Override
    public String providerDisplayName() {
        return mEndpointConfig.providerDisplayName();
    }

    @Override
    public String modelName() {
        return MODEL();
    }

    @Override
    public boolean usesCloud() {
        return true;
    }

    @Override
    public String privacyDisclosure() {
        return mEndpointConfig.privacyDisclosure();
    }

    @Override
    public void cancel() {
        mCancelled = true;
        HttpURLConnection connection = mActiveConnection;
        if (connection != null) {
            connection.disconnect();
        }
    }

    @Override
    public String decideOrchestration(String userMessage, boolean hasActiveTask,
            String recentConversationJson) {
        mCancelled = false;
        if (!mEndpointConfig.isConfigured()) {
            return new LocalHeuristicModelAdapter()
                    .decideOrchestration(userMessage, hasActiveTask, recentConversationJson);
        }
        try {
            JSONObject response = callOrchestratorResponsesApi(userMessage, hasActiveTask,
                    recentConversationJson);
            JSONObject decision = parseOrchestratorDecision(extractOutputText(response));
            return decision.toString();
        } catch (JSONException e) {
            return fallbackAnswerDecision("I could not decide how to handle that message.");
        } catch (IOException e) {
            if (mCancelled) {
                return fallbackAnswerDecision("Message stopped.");
            }
            return fallbackAnswerDecision("Message routing failed: " + e.getMessage());
        }
    }

    @Override
    public String chat(String userMessage) {
        mCancelled = false;
        if (!mEndpointConfig.isConfigured()) {
            return "Cloud chat is not configured. Open Developer settings and add a "
                    + "broker token or development API key.";
        }
        try {
            JSONObject response = callChatResponsesApi(userMessage);
            String outputText = extractOutputText(response).trim();
            return outputText.isEmpty() ? "I did not get a text response." : outputText;
        } catch (JSONException e) {
            return "I could not parse the chat response.";
        } catch (IOException e) {
            if (mCancelled) {
                return "Chat stopped.";
            }
            return "Chat request failed: " + e.getMessage();
        }
    }

    /**
     * Strict yes/no semantic judgment for background watchers. Throws IOException on any
     * model failure so callers can route it through their normal retry/backoff path.
     */
    public boolean judgeWatcherCondition(String conditionText, String observedText)
            throws IOException {
        mCancelled = false;
        if (!mEndpointConfig.isConfigured()) {
            throw new IOException("semantic_model_unconfigured");
        }
        try {
            JSONObject response = callWatcherJudgmentResponsesApi(conditionText, observedText);
            String verdict = extractOutputText(response).trim().toLowerCase(Locale.US);
            if (verdict.startsWith("yes")) {
                return true;
            }
            if (verdict.startsWith("no")) {
                return false;
            }
            throw new IOException("semantic_judgment_unparseable:"
                    + verdict.substring(0, Math.min(verdict.length(), 40)));
        } catch (JSONException e) {
            throw new IOException("semantic_judgment_parse");
        }
    }

    private JSONObject callWatcherJudgmentResponsesApi(String conditionText,
            String observedText) throws IOException, JSONException {
        String prompt = "You evaluate a background watcher for OpenPhone, an AI-native "
                + "Android OS. The user asked to be notified when a condition becomes true "
                + "on a web page. Judge semantically, not by keyword overlap: the condition "
                + "counts as satisfied only if the page content actually states or clearly "
                + "implies it. Reply with exactly one word: yes or no.\n\n"
                + "Condition: " + (conditionText == null ? "" : conditionText.trim())
                + "\n\nPage content (may be truncated):\n"
                + (observedText == null ? "" : observedText);
        JSONObject body = new JSONObject()
                .put("model", MODEL())
                .put("input", new JSONArray()
                        .put(new JSONObject()
                                .put("role", "user")
                                .put("content", new JSONArray()
                                        .put(new JSONObject()
                                                .put("type", "input_text")
                                                .put("text", prompt)))))
                .put("metadata", new JSONObject()
                        .put("openphone_watcher", "true")
                        .put("mode", "semantic_watcher_judgment"))
                .put("max_output_tokens", 300);
        return postResponses(body);
    }

    @Override
    public String answerScreenQuestion(String userMessage, String screenJson) {
        mCancelled = false;
        if (!mEndpointConfig.isConfigured()) {
            return "Cloud screen understanding is not configured. Open Developer settings and "
                    + "add a broker token or development API key.";
        }
        try {
            JSONObject screen = new JSONObject(screenJson == null ? "{}" : screenJson);
            JSONObject screenshot = screen.optJSONObject("screenshot");
            JSONObject response = callScreenAnswerResponsesApi(userMessage, screen, screenshot);
            String outputText = extractOutputText(response).trim();
            return outputText.isEmpty() ? "I could not describe the screen." : outputText;
        } catch (JSONException e) {
            return "I could not parse the screen context.";
        } catch (IOException e) {
            if (mCancelled) {
                return "Screen question stopped.";
            }
            return "Screen question failed: " + e.getMessage();
        }
    }

    @Override
    public String runTask(String taskId, String userGoal, ToolExecutor executor) {
        mCancelled = false;
        if (!mEndpointConfig.isConfigured()) {
            return unavailable(mEndpointConfig.missingCredentialReason());
        }
        if (!ToolCatalog.get().isLoaded()) {
            return unavailable("Action registry is not installed; no model tools available.");
        }

        JSONArray steps = new JSONArray();
        try {
            long startedAtMillis = System.currentTimeMillis();
            int consecutiveToolErrors = 0;
            int consecutiveNoProgressActions = 0;
            for (int step = 1; step <= MAX_STEPS; step++) {
                if (mCancelled || executor.isCancelled()) {
                    return result("cancelled", userGoal, steps);
                }
                if (System.currentTimeMillis() - startedAtMillis > MAX_DURATION_MS) {
                    return result("duration_limit_reached", userGoal, steps);
                }
                String screen = captureScreenWithRetry(executor);
                if (mCancelled || executor.isCancelled()) {
                    return result("cancelled", userGoal, steps);
                }
                JSONObject screenJson = new JSONObject(screen);
                JSONObject screenshot = screenJson.optJSONObject("screenshot");
                if (screenshot == null || screenshot.optString("data").isEmpty()) {
                    String status = screenJson.optString("status", "");
                    if (!"screen.blocked".equals(status)) {
                        return new JSONObject()
                                .put("status", "screen_capture_failed")
                                .put("provider", name())
                                .put("steps", steps)
                                .put("screen", redactScreenshot(screenJson))
                                .put("screenshot_error", screenJson.optString("screenshot_error"))
                                .toString(2);
                    }
                }

                JSONObject response = callResponsesApi(userGoal, steps, screenJson, screenshot);
                if (mCancelled || executor.isCancelled()) {
                    return result("cancelled", userGoal, steps);
                }
                String outputText = extractOutputText(response);
                JSONObject decision = parseDecision(outputText);
                JSONObject stepJson = new JSONObject()
                        .put("step", step)
                        .put("openai_response_id", response.optString("id"))
                        .put("thought", decision.optString("thought"))
                        .put("task_state", decision.optString("task_state"))
                        .put("next_subgoal", decision.optString("next_subgoal"))
                        .put("success_criteria", decision.optString("success_criteria"))
                        .put("tool", decision.optString("tool"))
                        .put("arguments", decision.optJSONObject("arguments") == null
                                ? new JSONObject() : decision.optJSONObject("arguments"))
                        .put("screen", redactScreenshot(new JSONObject(screenJson.toString())));
                steps.put(stepJson);

                String toolName = decision.optString("tool", "");
                JSONObject arguments = decision.optJSONObject("arguments");
                if (arguments == null) {
                    arguments = new JSONObject();
                }
                normalizeBrowserUrlDecision(userGoal, steps, screenJson, decision, arguments);
                toolName = decision.optString("tool", "");
                arguments = decision.optJSONObject("arguments");
                if (arguments == null) {
                    arguments = new JSONObject();
                }
                ensureToolReason(toolName, arguments, decision.optString("thought", ""));
                stepJson.put("arguments", arguments);
                stepJson.put("tool", toolName);

                if (shouldAutoFinishSatisfiedOpenGoal(userGoal, screenJson, toolName)) {
                    toolName = "finish_task";
                    arguments = new JSONObject()
                            .put("summary", "The requested app or site is visible.");
                    stepJson.put("thought", "The requested app or site is already visible. "
                            + "Finish instead of interacting with login or install surfaces.");
                    stepJson.put("tool", toolName);
                    stepJson.put("arguments", arguments);
                }

                if ("finish_task".equals(toolName)) {
                    JSONObject finishEvidence = finishEvidence(userGoal,
                            decision.optString("success_criteria"), screenJson);
                    stepJson.put("finish_evidence", finishEvidence);
                    if (!finishEvidence.optBoolean("has_screen_evidence", false)) {
                        String toolResult = executor.callTool("wait", new JSONObject()
                                .put("duration_ms", 1500)
                                .put("reason", "Wait for visible evidence before finishing.")
                                .toString());
                        stepJson.put("tool_result", toolResult);
                        continue;
                    }
                    String toolResult = executor.callTool(toolName, arguments.toString());
                    stepJson.put("tool_result", toolResult);
                    return result("task.finished", userGoal, steps);
                }
                if ("fail_task".equals(toolName)) {
                    String toolResult = executor.callTool(toolName, arguments.toString());
                    stepJson.put("tool_result", toolResult);
                    return result("task.failed", userGoal, steps);
                }
                if (!isAllowedTool(toolName)) {
                    stepJson.put("tool_result", errorJson("unknown_model_tool:" + toolName));
                    return result("agent.blocked", userGoal, steps);
                }
                JSONObject guardrail = guardrailConfirmation(mFullYolo, userGoal, screenJson,
                        toolName, arguments);
                if (guardrail != null) {
                    stepJson.put("guardrail", guardrail);
                    String toolResult = executor.callTool("ask_user_confirmation",
                            guardrail.toString());
                    stepJson.put("tool_result", toolResult);
                    return result("confirmation_required", userGoal, steps);
                }

                String toolResult = executor.callTool(toolName, arguments.toString());
                stepJson.put("tool_result", toolResult);
                if (mCancelled || executor.isCancelled()) {
                    return result("cancelled", userGoal, steps);
                }
                String toolStatus = toolStatus(toolResult);
                if ("dry_run.preview".equals(toolStatus)) {
                    return result("dry_run.preview", userGoal, steps);
                }
                if ("confirmation_requested".equals(toolStatus)
                        || "confirmation_required".equals(toolStatus)) {
                    return result("confirmation_required", userGoal, steps);
                }
                if ("denied".equals(toolStatus)) {
                    return result("action_denied", userGoal, steps);
                }
                if (isToolFailure(toolStatus)) {
                    consecutiveToolErrors++;
                    stepJson.put("consecutive_tool_errors", consecutiveToolErrors);
                    if (consecutiveToolErrors >= MAX_CONSECUTIVE_TOOL_ERRORS) {
                        return result("action_failed", userGoal, steps);
                    }
                } else {
                    consecutiveToolErrors = 0;
                }
                if (shouldVerifyProgress(toolName)) {
                    sleepAfterAction();
                    String afterScreen = captureScreenWithRetry(executor);
                    if (mCancelled || executor.isCancelled()) {
                        return result("cancelled", userGoal, steps);
                    }
                    JSONObject afterScreenJson = new JSONObject(afterScreen);
                    JSONObject verification = progressVerification(screenJson, afterScreenJson);
                    stepJson.put("verification", verification);
                    stepJson.put("after_screen", redactScreenshot(
                            new JSONObject(afterScreenJson.toString())));
                    if (verification.optBoolean("screen_changed", false)) {
                        consecutiveNoProgressActions = 0;
                    } else {
                        consecutiveNoProgressActions++;
                        stepJson.put("consecutive_no_progress_actions",
                                consecutiveNoProgressActions);
                        if (consecutiveNoProgressActions >= MAX_CONSECUTIVE_NO_PROGRESS_ACTIONS) {
                            return result("no_progress", userGoal, steps);
                        }
                    }
                } else {
                    consecutiveNoProgressActions = 0;
                    sleepAfterAction();
                }
            }
            return result("step_limit_reached", userGoal, steps);
        } catch (JSONException e) {
            return error("json_error", e.getMessage(), steps);
        } catch (IOException e) {
            if (mCancelled || executor.isCancelled()) {
                return cancelledResult(userGoal, steps);
            }
            return error("network_error", e.getMessage(), steps);
        }
    }

    private JSONObject callChatResponsesApi(String userMessage) throws IOException, JSONException {
        String prompt = "You are OpenPhone, a concise AI assistant inside an Android phone. "
                + "This is normal conversation, not an autonomous phone-control task. "
                + "Do not claim that a phone action was completed. If the user asks you "
                + "to operate the phone, tell them you can do that when they phrase it "
                + "as an action request. Keep the reply brief and helpful.\n\n"
                + "User message: " + (userMessage == null ? "" : userMessage.trim());
        JSONObject body = new JSONObject()
                .put("model", MODEL())
                .put("input", new JSONArray()
                        .put(new JSONObject()
                                .put("role", "user")
                                .put("content", new JSONArray()
                                        .put(new JSONObject()
                                                .put("type", "input_text")
                                                .put("text", prompt)))))
                .put("metadata", new JSONObject()
                        .put("openphone_chat", "true")
                        .put("mode", "conversation"))
                .put("max_output_tokens", 350);

        HttpURLConnection connection = (HttpURLConnection) new URL(
                mEndpointConfig.responsesUrl()).openConnection();
        mActiveConnection = connection;
        try {
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(45000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setRequestProperty("Authorization", "Bearer "
                    + mEndpointConfig.bearerToken());
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setRequestProperty("Accept", "application/json");
            if (mEndpointConfig.isBrokerMode()) {
                connection.setRequestProperty("X-OpenPhone-Model-Provider", "openai_responses");
                connection.setRequestProperty("X-OpenPhone-Request-Shape", "responses_proxy");
            }

            byte[] bodyBytes = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(bodyBytes.length);
            try (OutputStream outputStream = connection.getOutputStream()) {
                outputStream.write(bodyBytes);
            }

            int statusCode = connection.getResponseCode();
            String responseBody = readAll(statusCode >= 200 && statusCode < 300
                    ? connection.getInputStream() : connection.getErrorStream());
            if (statusCode < 200 || statusCode >= 300) {
                throw new IOException("OpenAI HTTP " + statusCode + ": "
                        + summarizeError(responseBody));
            }
            return new JSONObject(responseBody);
        } finally {
            if (mActiveConnection == connection) {
                mActiveConnection = null;
            }
            connection.disconnect();
        }
    }

    private JSONObject callOrchestratorResponsesApi(String userMessage, boolean hasActiveTask,
            String recentConversationJson) throws IOException, JSONException {
        String continuityContext = recentConversationJson == null
                ? "" : recentConversationJson.trim();
        String prompt = "You are the OpenPhone orchestrator: the single decision point for "
                + "every user message on an AI-native Android phone. Decide how to help and "
                + "return exactly one JSON object, no markdown.\n\n"
                + "Decision schema:\n"
                + "{\"mode\":\"answer|clarify|retrieve|inspect_screen|act|watch|memory|stop\","
                + "\"reply\":\"text shown to the user (answer/clarify modes)\","
                + "\"task_goal\":\"goal for a multi-step phone task (act mode without "
                + "proposed_actions)\","
                + "\"proposed_actions\":[{\"tool\":\"tool_name\",\"arguments\":{...}}],"
                + "\"delivery_surface\":\"chat\","
                + "\"reason\":\"short decision reason\"}\n\n"
                + "Identity:\n"
                + "- You are not a chatbot bolted onto Android. You are the phone-resident "
                + "OpenPhone intelligence layer. Assume useful personal state may already "
                + "exist in memories, commitments, watchers, notifications, messages, calls, "
                + "calendar, and prior context.\n"
                + "- Do not answer \"I don't know\" for phone-state questions until you have "
                + "used the relevant retrieval tool. When the user asks what they missed, "
                + "what is pending, what they promised, what is due, who replied, or what "
                + "changed, retrieve from the phone substrate instead of answering from "
                + "general knowledge.\n"
                + "- Treat open loops as durable state. If the user expresses an intent that "
                + "should survive this conversation, propose a memory, commitment, or watcher "
                + "instead of only replying.\n\n"
                + "- Maintain continuity across sessions. Use the recent continuity context "
                + "below when the user says things like \"that\", \"continue\", \"what were "
                + "we doing\", \"last time\", or asks about recent OpenPhone work. For deeper "
                + "history, choose retrieve with context_search or memory_search instead of "
                + "guessing.\n\n"
                + "Modes:\n"
                + "- answer: reply conversationally now. Greetings, general questions, advice, "
                + "anything that needs no phone data and no phone action.\n"
                + "- clarify: only when no available read-only discovery, observation, or "
                + "reversible action can reduce the ambiguity. If any tool can establish the "
                + "missing context, choose act with a task_goal and let the agent loop discover "
                + "it. Do not clarify for normal preference gaps, random/any/surprise requests, "
                + "broad exploration, app navigation, media playback, search, or visible UI "
                + "choices; "
                + "choose a reasonable default, top result, random item, or reversible first "
                + "step and continue.\n"
                + "- retrieve: answer using on-device data via one or more read-only tool "
                + "calls in proposed_actions (notifications, messages, calendar, contacts, "
                + "calls, memories, commitments, watchers, context). Use a small bundle when "
                + "the natural answer depends on multiple stores: for example, \"what did I "
                + "miss?\" can use notifications_summary plus messages_summary; \"what's on "
                + "my plate?\" can use commitment_search with query=\"\" plus watcher_list "
                + "and calendar_search.\n"
                + "- inspect_screen: the user asks about the currently visible screen, "
                + "foreground app, page, dialog, image, or what OpenPhone can see. "
                + "Voice transcripts like \"can you see my screen?\", \"what am I "
                + "looking at?\", \"read this\", \"summarize this screen\", and "
                + "\"what does this say?\" should choose inspect_screen. No "
                + "proposed_actions needed.\n"
                + "- act: change device or external state. If ONE registry tool call clearly "
                + "completes the whole user goal (create/update/delete a calendar event, "
                + "draft a message, place a call, open a notification, or simply open an "
                + "app when the user only asked to open/launch/show that app), put that "
                + "single call in proposed_actions. If the user asks to do anything inside "
                + "an app after opening it (play media, search, choose content, change a "
                + "setting, buy/book/post/send/select something, or otherwise navigate UI), "
                + "do not use open_app as a one-shot proposed_action; leave proposed_actions "
                + "empty and set task_goal for the autonomous multi-step agent. Moving or "
                + "cancelling an existing event needs its "
                + "event_id: if you do not have one, set task_goal so the agent can "
                + "calendar_search first. Use calendar_check_availability (retrieve) for "
                + "free/busy questions. "
                + "If the user explicitly asks for a background job/task, asks OpenPhone to "
                + "keep working after this chat, run something as soon as possible, or notify "
                + "when an async agent task is done, use background_job_create. "
                + "Otherwise leave proposed_actions empty and set task_goal for the autonomous "
                + "multi-step agent (UI navigation, web tasks, anything needing the screen).\n"
                + "- watch: the user wants future monitoring or an open-loop follow-up "
                + "(\"tell me when...\", \"remind me if...\", \"watch this\", \"let me know\", "
                + "\"make sure I don't forget\"). Use watcher_create or a commitment tool in "
                + "proposed_actions; do not merely promise to remember. Watchers monitor an "
                + "external condition such as a reply, call, notification, page change, or "
                + "semantic state. Do not use watcher_create for explicit background jobs, "
                + "queued agent work, or run-as-soon-as-possible tasks. If the user wants "
                + "the phone to do something when the watched event happens, store that "
                + "reaction in watcher_create.delivery using delivery.tool plus "
                + "delivery.arguments, or delivery.prompt for a background agent job. "
                + "Delivery argument strings may reference the trigger with templates such "
                + "as {{event.number}}, {{event.address}}, {{event.title}}, {{event.text}}, "
                + "{{event.url}}, {{watcher.id}}, and {{watcher.title}}. If the user asks "
                + "to monitor SMS/messages and then check, research, classify, summarize, "
                + "or otherwise reason about each message, create a message "
                + "watcher with match_any=true and recurring=true, then put the requested "
                + "work in delivery.prompt so the fired watcher starts a background agent "
                + "job. That prompt should include {{event.text}} and may instruct the "
                + "agent to use browser_search or browser_fetch_page for internet context "
                + "before notifying the user. For "
                + "message replies use watcher_create with source=message and the sender's "
                + "number/name as address; add deadline_at (unix ms) plus notify_on=no_reply "
                + "when the user wants a reminder only if no reply arrives in time. For calls "
                + "use watcher_create with source=call and the number; notify_on=call alerts "
                + "when a call with that number appears, notify_on=no_call plus deadline_at "
                + "reminds only if no call happened in time (e.g. \"remind me to call back\", "
                + "\"tell me when she calls\"). For every/any incoming caller, set "
                + "source=call, direction=incoming, match_any=true, and recurring=true.\n"
                + "- memory: the user wants something remembered or recalled, or states a "
                + "stable preference/standing instruction that would help future phone use. "
                + "Use memory_save or memory_search in proposed_actions.\n"
                + "- stop: the user wants to stop or cancel what is happening.\n\n"
                + "Rules:\n"
                + initiativeRule()
                + orchestratorAutonomyRule()
                + "- Every proposed_actions tool call must come from the tool list below, with "
                + "arguments matching its schema, including a specific \"reason\" argument "
                + "where the tool requires one.\n"
                + "- Never invent device data in answer mode; use retrieve.\n"
                + "- Bias toward taking action. If the user gave an actionable goal and a "
                + "concrete first step exists, choose act/retrieve/watch/memory instead of "
                + "clarify. Put assumptions in task_goal; do not ask the user to make "
                + "ordinary product/content/navigation choices for you.\n"
                + "- Before choosing clarify, inspect the available tool catalog. If any "
                + "read-only lookup, current-state observation, or reversible action could "
                + "resolve the uncertainty, clarification is premature: choose act with an "
                + "empty proposed_actions list and a task_goal that lets the full agent loop "
                + "investigate and continue. Do not ask permission merely to use capabilities "
                + "the OS has already granted; the policy layer enforces real approval "
                + "boundaries.\n"
                + "- For words like random, any, surprise me, something, whatever, best, or "
                + "quick, make the choice yourself and proceed. The whole point is that the "
                + "phone agent should decide and execute, not hand the task back.\n"
                + "- If the user asks a broad personal-state question, prefer retrieve with "
                + "the most relevant stores over answer mode. Examples: reminders and "
                + "follow-ups use commitment_search query=\"\"; active monitors use "
                + "watcher_list; background jobs use background_job_list; prior assistant "
                + "work uses context_search; durable "
                + "preferences use memory_search.\n"
                + "- State-changing tools are allowed in proposed_actions. Do not pre-ask "
                + "for permission; the OS/tool layer will return approval_required when "
                + "approval is actually needed.\n"
                + "- If has_active_task is true, follow-up instructions about the running task "
                + "should be mode act with task_goal carrying the follow-up.\n"
                + "- Never return Done as a reply.\n\n"
                + "Available tools:\n" + ToolCatalog.get().promptToolCatalog() + "\n"
                + (continuityContext.isEmpty() || "{}".equals(continuityContext) ? ""
                        : "Recent continuity context:\n" + continuityContext + "\n\n")
                + "device_time: " + deviceTimeContext() + "\n"
                + "has_active_task: " + hasActiveTask + "\n"
                + "user_message: " + (userMessage == null ? "" : userMessage.trim());
        JSONObject body = new JSONObject()
                .put("model", MODEL())
                .put("input", new JSONArray()
                        .put(new JSONObject()
                                .put("role", "user")
                                .put("content", new JSONArray()
                                        .put(new JSONObject()
                                                .put("type", "input_text")
                                                .put("text", prompt)))))
                .put("metadata", new JSONObject()
                        .put("openphone_orchestrator", "true")
                        .put("mode", "orchestrator_decision"))
                .put("max_output_tokens", 600);
        return postResponses(body);
    }

    private String orchestratorAutonomyRule() {
        if (mFullYolo) {
            return "- Autonomy mode is full YOLO: do not create confirmation requests for "
                    + "payment, purchase, booking, sending, calling, posting, installation, "
                    + "or other high-risk actions. Route actionable requests to act/retrieve/"
                    + "watch/memory and let the tool layer execute them.\n";
        }
        return "";
    }

    private String initiativeRule() {
        return "- Be execution-biased. If the request is actionable, do the useful thing "
                + "instead of explaining limits, asking the user to verify every step, or "
                + "handing ordinary choices back. Make reasonable assumptions, choose "
                + "default/top/visible options, and proceed through reversible UI. Ask only "
                + "when missing information blocks every concrete path.\n";
    }

    private String taskAutonomyRule() {
        if (mFullYolo) {
            return "- Autonomy mode is full YOLO: execute requested high-risk visible UI "
                    + "actions directly, including payment, purchase, booking, sending, "
                    + "calling, posting, installation, and account surfaces. Do not call "
                    + "ask_user_confirmation unless a tool result explicitly requires it.\n";
        }
        return "";
    }

    private String sensitiveActionRule() {
        if (mFullYolo) {
            return "- If the goal involves credentials, payment, purchase, posting, sending, "
                    + "calling, deleting, booking, or installation, keep operating the app "
                    + "until the requested result is visible or no tool can progress.\n";
        }
        return "- If the goal involves credentials, payment, purchase, posting, sending, "
                + "calling, deleting, booking, or installation, keep operating the app until "
                + "the next concrete tool result requires approval or no tool can progress.\n";
    }

    private String approvalResultRule() {
        if (mFullYolo) {
            return "Do not call ask_user_confirmation in full YOLO. If a tool result asks "
                    + "for approval, choose a concrete next tool if possible; otherwise fail "
                    + "with the tool's reason.";
        }
        return "If a tool result requires approval, surface that approval and then continue "
                + "after the result.";
    }

    private String workflowEndStateRule() {
        if (mFullYolo) {
            return "ready, or no tool can progress.\n";
        }
        return "ready, or the tool/result layer reports that approval is required.\n";
    }

    private String installPaymentRule() {
        if (mFullYolo) {
            return "Full YOLO is enabled. Do not stop to request approval before Android "
                    + "install-security prompts, credential entry, or payment/subscription "
                    + "acceptance when the user asked for the workflow.\n\n";
        }
        return "Do not bypass Android install-security prompts, enter credentials, or "
                + "accept payments/subscriptions.\n\n";
    }

    private JSONObject callScreenAnswerResponsesApi(String userMessage, JSONObject screenJson,
            JSONObject screenshot) throws IOException, JSONException {
        String mimeType = screenshot == null ? "image/jpeg"
                : screenshot.optString("mime_type", "image/jpeg");
        String dataUrl = screenshot == null || screenshot.optString("data").isEmpty()
                ? "" : "data:" + mimeType + ";base64," + screenshot.optString("data");
        String prompt = "You are OpenPhone, an AI assistant inside Android. The user is asking "
                + "about the current visible screen. Answer directly in natural language. "
                + "Do not perform phone actions. Do not say Done. If the screen is unclear, "
                + "say what you can infer from the visible text and foreground app.\n\n"
                + "User question: " + (userMessage == null ? "" : userMessage.trim())
                + "\n\nScreen metadata without image bytes:\n"
                + redactScreenshot(new JSONObject(screenJson.toString())).toString(2);
        JSONArray content = new JSONArray()
                .put(new JSONObject()
                        .put("type", "input_text")
                        .put("text", prompt));
        if (!dataUrl.isEmpty()) {
            content.put(new JSONObject()
                    .put("type", "input_image")
                    .put("image_url", dataUrl)
                    .put("detail", "low"));
        }
        JSONObject body = new JSONObject()
                .put("model", MODEL())
                .put("input", new JSONArray()
                        .put(new JSONObject()
                                .put("role", "user")
                                .put("content", content)))
                .put("metadata", new JSONObject()
                        .put("openphone_chat", "true")
                        .put("mode", "screen_question"))
                .put("max_output_tokens", 500);

        return postResponses(body);
    }

    private JSONObject postResponses(JSONObject body) throws IOException, JSONException {
        HttpURLConnection connection = (HttpURLConnection) new URL(
                mEndpointConfig.responsesUrl()).openConnection();
        mActiveConnection = connection;
        try {
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(45000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setRequestProperty("Authorization", "Bearer "
                    + mEndpointConfig.bearerToken());
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setRequestProperty("Accept", "application/json");
            if (mEndpointConfig.isBrokerMode()) {
                connection.setRequestProperty("X-OpenPhone-Model-Provider", "openai_responses");
                connection.setRequestProperty("X-OpenPhone-Request-Shape", "responses_proxy");
            }

            byte[] bodyBytes = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(bodyBytes.length);
            try (OutputStream outputStream = connection.getOutputStream()) {
                outputStream.write(bodyBytes);
            }

            int statusCode = connection.getResponseCode();
            String responseBody = readAll(statusCode >= 200 && statusCode < 300
                    ? connection.getInputStream() : connection.getErrorStream());
            if (statusCode < 200 || statusCode >= 300) {
                throw new IOException("OpenAI HTTP " + statusCode + ": "
                        + summarizeError(responseBody));
            }
            return new JSONObject(responseBody);
        } finally {
            if (mActiveConnection == connection) {
                mActiveConnection = null;
            }
            connection.disconnect();
        }
    }

    private String captureScreenWithRetry(ToolExecutor executor) {
        String request = "{\"include_screenshot\":true,\"include_activity\":true,"
                + "\"include_ui_tree\":true,"
                + "\"max_dimension\":512,\"quality\":65,"
                + "\"reason\":\"observe current screen for the active task\"}";
        String screen = executor.callTool("get_screen", request);
        if (hasScreenshot(screen) || mCancelled || executor.isCancelled()) {
            return screen;
        }
        try {
            Thread.sleep(750);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return screen;
        }
        return executor.callTool("get_screen", request);
    }

    private JSONObject callResponsesApi(String userGoal, JSONArray steps, JSONObject screenJson,
            JSONObject screenshot) throws IOException, JSONException {
        String mimeType = screenshot == null ? "image/jpeg"
                : screenshot.optString("mime_type", "image/jpeg");
        String dataUrl = screenshot == null || screenshot.optString("data").isEmpty()
                ? "" : "data:" + mimeType + ";base64," + screenshot.optString("data");

        String prompt = "You are OpenPhone Agent, a mobile GUI agent running inside Android. "
                + "Your job is to complete the user's real phone task, not to demonstrate "
                + "one action, narrate a plan, or hand ordinary choices back to the user. "
                + "Work like a long-horizon mobile agent: observe the current screen, "
                + "maintain task state from prior steps, choose the next subgoal, execute "
                + "exactly one action, then verify progress on the next observation. Return "
                + "exactly one JSON object and no markdown.\n\n"
                + "Agent rules:\n"
                + initiativeRule()
                + taskAutonomyRule()
                + "- Treat this as a long-horizon task. Use up to the available step budget.\n"
                + "- First understand where you are: foreground app, visible text, UI tree, "
                + "and screenshot.\n"
                + "- Treat the screenshot as the rendered full-screen view and the UI tree as "
                + "supplemental metadata. When the UI tree is sparse, custom-rendered, or "
                + "missing labels, use screenshot coordinates instead of claiming you only "
                + "have a limited accessibility view.\n"
                + "- Do not mumble, apologize, narrate uncertainty, or stop at a plan. "
                + "When a tool can advance the task, call the tool. Keep user-facing "
                + "summaries brief and outcome-focused.\n"
                + "- Prefer semantic UI actions. Use tap_element or long_press_element with "
                + "an interactive_elements id whenever a matching enabled element exists.\n"
                + "- Use raw coordinates only for unlabeled/custom UI when no suitable "
                + "element id exists.\n"
                + "- If an action did not change the screen, recover: choose another visible "
                + "target, scroll, press back, wait for loading, or fail with a precise reason.\n"
                + "- Do not repeat the same failed/no-op action.\n"
                + "- Do not ask for repeated verification. One clear user request is enough "
                + "authorization for the requested workflow within the current autonomy "
                + "mode; use the screen and tool results to verify progress yourself.\n"
                + "- Do not finish just because an app opened. Finish only when the current "
                + "screen visibly satisfies the user's goal and your success_criteria.\n"
                + "- For goals phrased as \"open <app/site>\", stop once that app or site is "
                + "visibly open. Do not click login, sign up, get app, install, notification, "
                + "or feed-personalization surfaces unless the user explicitly asked for that.\n"
                + sensitiveActionRule()
                + "- Do not ask the user to choose among ordinary visible options. If the user "
                + "said random, any, something, surprise me, best, or did not specify a "
                + "preference, choose a reasonable/default/top visible option yourself and "
                + "continue. Only ask when missing information blocks every concrete next "
                + "step. " + approvalResultRule() + "\n"
                + "- If the foreground screen is OpenPhone Assistant, the task is already "
                + "running; do not tap Speak, Run, or Developer. Start by opening the "
                + "target app, URL, or system surface needed for the user goal.\n\n"
                + "Long-task contract:\n"
                + "- Opening an app, site, settings surface, search page, or conversation is "
                + "usually only setup. It is completion only when the user's entire goal was "
                + "to open that surface.\n"
                + "- For in-app workflows, keep going through navigation, search, selection, "
                + "and execution until there is visible end-state evidence: requested content "
                + "is playing/open, a setting changed, an item is selected/created, a draft is "
                + workflowEndStateRule()
                + "- Prefer useful progress over asking. Explore reversible UI, use visible "
                + "top/default/random choices when appropriate, and recover from no-ops before "
                + "declaring the task blocked.\n\n"
                + "Allowed JSON schema:\n"
                + "{\"task_state\":\"what is already true and what remains\","
                + "\"next_subgoal\":\"the immediate objective for this one action\","
                + "\"success_criteria\":\"what must be visible before finish_task\","
                + "\"thought\":\"short reason\","
                + "\"tool\":\"" + ToolCatalog.get().toolNamesPipeList() + "\","
                + "\"arguments\":{...}}\n\n"
                + "Available tools:\n"
                + ToolCatalog.get().promptToolCatalog() + "\n"
                + "Recovery guidance:\n"
                + "- If the previous step has verification.screen_changed=false, assume the "
                + "last action missed or was ignored. Do not retry the same element or "
                + "coordinate unless the screen changed afterward.\n"
                + "- If a list does not show the needed item, swipe in the direction that "
                + "reveals more content, then observe again.\n"
                + "- If an app opens to an unexpected screen, use visible navigation, search, "
                + "tabs, back, or menus before giving up.\n"
                + "- If there are multiple plausible targets, choose the one whose label most "
                + "closely matches the next_subgoal.\n\n"
                + "For app downloads, prefer an already-installed app store if visible. "
                + "Use open_url for exact official download URLs instead of manually typing "
                + "into a browser. Never type an https:// URL into the address bar and then "
                + "tap the keyboard Search/Go key; use open_url in one step. "
                + "If no app store is installed, use Browser and official websites only. "
                + "If the official website only offers an app store link and that store is not "
                + "installed, finish_task with that explanation instead of continuing to scroll. "
                + "For Twitter/X, if a browser page shows X, Twitter, or 'See what’s happening', "
                + "the open task is complete; do not tap Get the app or login surfaces. "
                + installPaymentRule()
                + "Device time: " + deviceTimeContext()
                + "\n\nUser goal: " + userGoal
                + "\n\nPrevious steps:\n" + steps.toString(2)
                + "\n\nScreen metadata without image bytes:\n"
                + redactScreenshot(new JSONObject(screenJson.toString())).toString(2);

        JSONArray content = new JSONArray()
                .put(new JSONObject()
                        .put("type", "input_text")
                        .put("text", prompt));
        if (!dataUrl.isEmpty()) {
            content.put(new JSONObject()
                    .put("type", "input_image")
                    .put("image_url", dataUrl)
                    .put("detail", "low"));
        }

        JSONObject body = new JSONObject()
                .put("model", MODEL())
                .put("input", new JSONArray()
                        .put(new JSONObject()
                                .put("role", "user")
                                .put("content", content)))
                .put("metadata", requestMetadata(screenJson))
                .put("max_output_tokens", 500);

        HttpURLConnection connection = (HttpURLConnection) new URL(
                mEndpointConfig.responsesUrl()).openConnection();
        mActiveConnection = connection;
        try {
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(45000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setRequestProperty("Authorization", "Bearer "
                    + mEndpointConfig.bearerToken());
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setRequestProperty("Accept", "application/json");
            if (mEndpointConfig.isBrokerMode()) {
                connection.setRequestProperty("X-OpenPhone-Model-Provider", "openai_responses");
                connection.setRequestProperty("X-OpenPhone-Request-Shape", "responses_proxy");
            }

            byte[] bodyBytes = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(bodyBytes.length);
            try (OutputStream outputStream = connection.getOutputStream()) {
                outputStream.write(bodyBytes);
            }

            int statusCode = connection.getResponseCode();
            String responseBody = readAll(statusCode >= 200 && statusCode < 300
                    ? connection.getInputStream() : connection.getErrorStream());
            if (statusCode < 200 || statusCode >= 300) {
                throw new IOException("OpenAI HTTP " + statusCode + ": "
                        + summarizeError(responseBody));
            }
            return new JSONObject(responseBody);
        } finally {
            if (mActiveConnection == connection) {
                mActiveConnection = null;
            }
            connection.disconnect();
        }
    }

    private static JSONObject parseDecision(String outputText) throws JSONException {
        String text = outputText == null ? "" : outputText.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start < 0 || end <= start) {
            return new JSONObject()
                    .put("thought", "Model did not return JSON")
                    .put("tool", "fail_task")
                    .put("arguments", new JSONObject().put("reason", text));
        }
        JSONObject decision = new JSONObject(text.substring(start, end + 1));
        if (!decision.has("arguments") || decision.optJSONObject("arguments") == null) {
            decision.put("arguments", new JSONObject());
        }
        return decision;
    }

    private static JSONObject parseOrchestratorDecision(String outputText) throws JSONException {
        String text = outputText == null ? "" : outputText.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start < 0 || end <= start) {
            return new JSONObject()
                    .put("mode", "answer")
                    .put("reply", text.isEmpty()
                            ? "I could not decide how to handle that message." : text)
                    .put("reason", "non_json_orchestrator_output");
        }
        JSONObject decision = new JSONObject(text.substring(start, end + 1));
        if (!decision.has("mode")) {
            decision.put("mode", "answer");
        }
        return decision;
    }

    private static String deviceTimeContext() {
        java.text.SimpleDateFormat format = new java.text.SimpleDateFormat(
                "EEE yyyy-MM-dd HH:mm zzz", Locale.US);
        long now = System.currentTimeMillis();
        return format.format(new java.util.Date(now)) + " (unix_ms " + now + ")";
    }

    private static String fallbackAnswerDecision(String reply) {
        try {
            return new JSONObject()
                    .put("mode", "answer")
                    .put("reply", reply == null ? "" : reply)
                    .put("reason", "fallback")
                    .toString();
        } catch (JSONException e) {
            return "{\"mode\":\"answer\","
                    + "\"reply\":\"I could not decide how to handle that message.\"}";
        }
    }

    private static void normalizeBrowserUrlDecision(String userGoal, JSONArray steps,
            JSONObject screenJson, JSONObject decision, JSONObject arguments) throws JSONException {
        String toolName = decision.optString("tool", "");
        String url = "";
        if ("type_text".equals(toolName)) {
            String text = arguments.optString("text", "").trim();
            if (isHttpUrl(text) && isBrowserScreen(screenJson)) {
                url = text;
            }
        } else if (("tap".equals(toolName) || "press_key".equals(toolName))
                && isKeyboardSubmit(arguments)) {
            url = lastHttpUrlFromSteps(steps);
        }
        if (url.isEmpty()) {
            return;
        }
        String reason = arguments.optString("reason", "");
        if (reason.trim().isEmpty()) {
            reason = "Open the exact URL directly instead of using fragile browser keyboard input.";
        }
        decision.put("tool", "open_url");
        decision.put("arguments", new JSONObject()
                .put("url", url)
                .put("reason", reason));
        String thought = decision.optString("thought", "");
        if (!thought.toLowerCase(Locale.US).contains("open_url")) {
            decision.put("thought", thought + " Using open_url for exact URL navigation.");
        }
    }

    private static boolean isHttpUrl(String text) {
        String value = text == null ? "" : text.trim().toLowerCase(Locale.US);
        return value.startsWith("https://") || value.startsWith("http://");
    }

    private static boolean isBrowserScreen(JSONObject screenJson) throws JSONException {
        String screenText = normalizedScreenText(screenJson);
        return screenText.contains("org.lineageos.jelly")
                || screenText.contains("search or type url")
                || screenText.contains("browser");
    }

    private static boolean isKeyboardSubmit(JSONObject arguments) {
        String text = arguments == null ? "" : arguments.toString().toLowerCase(Locale.US);
        return containsAny(text, "search key", "go key", "keyboard search", "keyboard go",
                "proceed to the entered", "load the url", "navigate to the entered url");
    }

    private static String lastHttpUrlFromSteps(JSONArray steps) {
        if (steps == null) {
            return "";
        }
        for (int i = steps.length() - 1; i >= 0; i--) {
            JSONObject step = steps.optJSONObject(i);
            if (step == null) {
                continue;
            }
            JSONObject arguments = step.optJSONObject("arguments");
            if (arguments == null) {
                continue;
            }
            String text = arguments.optString("url", arguments.optString("text", "")).trim();
            if (isHttpUrl(text)) {
                return text;
            }
        }
        return "";
    }

    private static boolean isAllowedTool(String toolName) {
        return ToolCatalog.get().isAllowedTool(toolName)
                && !ToolCatalog.get().isTerminalTool(toolName);
    }

    private static JSONObject guardrailConfirmation(boolean fullYolo, String userGoal,
            JSONObject screenJson, String toolName, JSONObject arguments) throws JSONException {
        if (fullYolo) {
            return null;
        }
        if (!canChangeDeviceOrExternalState(toolName)) {
            return null;
        }
        if (isOpenPhoneControlSurface(screenJson)) {
            return null;
        }

        String screenText = normalizedScreenText(screenJson);
        String goal = userGoal == null ? "" : userGoal.toLowerCase(Locale.US);
        String risk = "";
        String summary = "";
        if (containsAny(screenText, "install", "update", "download", "get app",
                "unknown apps", "allow from this source", "permission", "allow access")) {
            risk = "High";
            summary = "The agent is about to act on an install, update, download, "
                    + "or permission screen.";
        } else if (containsAny(screenText, "buy now", "purchase", "payment",
                "subscribe", "subscription", "checkout", "credit card",
                "debit card", "place order", "confirm order")) {
            risk = "High";
            summary = "The agent is about to act on a purchase, payment, or "
                    + "subscription screen.";
        } else if (containsAny(screenText, "remove", "erase", "reset",
                "factory reset", "delete account", "delete file", "delete app")) {
            risk = "High";
            summary = "The agent is about to act on a destructive data-change screen.";
        } else if (containsAny(screenText, "send", "post", "share", "call", "message",
                "sms", "whatsapp", "email")) {
            risk = "High";
            summary = "The agent is about to communicate, share, call, message, "
                    + "or post content.";
        } else if (containsAny(screenText, "password", "sign in", "login", "log in",
                "account", "verification code", "2-step", "two-step")) {
            risk = "High";
            summary = "The agent is about to act on an account, login, password, "
                    + "or verification screen.";
        } else if (("share_text".equals(toolName) || "set_clipboard".equals(toolName)
                || "paste".equals(toolName))
                && containsAny(goal, "send", "share", "post", "message", "email")) {
            risk = "High";
            summary = "The agent is about to prepare or share user-provided content.";
        }

        if (risk.isEmpty()) {
            return null;
        }

        return new JSONObject()
                .put("summary", summary)
                .put("risk", risk)
                .put("reason", summary)
                .put("capability", capabilityForTool(toolName))
                .put("action_json", new JSONObject()
                        .put("tool", toolName)
                        .put("arguments", arguments == null ? new JSONObject() : arguments));
    }

    private static boolean canChangeDeviceOrExternalState(String toolName) {
        return ToolCatalog.get().isStateChangingTool(toolName);
    }

    private static boolean isSimpleOpenGoalSatisfied(String goal, String screenText) {
        if (goal == null || screenText == null || !goal.contains("open ")) {
            return false;
        }
        if ((goal.contains("twitter") || goal.matches(".*\\bx\\b.*"))
                && containsAny(screenText, "x. it", "twitter", "see what", "x.com")) {
            return true;
        }
        if (goal.contains("wikipedia")
                && containsAny(screenText, "wikipedia", "the free encyclopedia")) {
            return true;
        }
        return false;
    }

    private static boolean shouldAutoFinishSatisfiedOpenGoal(String userGoal, JSONObject screenJson,
            String toolName) throws JSONException {
        if (!("tap".equals(toolName) || "tap_element".equals(toolName)
                || "long_press".equals(toolName) || "long_press_element".equals(toolName)
                || "type_text".equals(toolName) || "press_key".equals(toolName))) {
            return false;
        }
        String goal = userGoal == null ? "" : userGoal.toLowerCase(Locale.US);
        return isSimpleOpenGoalSatisfied(goal, normalizedScreenText(screenJson));
    }

    private static String capabilityForTool(String toolName) {
        return ToolCatalog.get().capabilityForTool(toolName);
    }

    private static String normalizedScreenText(JSONObject screenJson) throws JSONException {
        JSONObject copy = redactScreenshot(new JSONObject(screenJson.toString()));
        return copy.toString().toLowerCase(Locale.US);
    }

    private static boolean isOpenPhoneControlSurface(JSONObject screenJson) throws JSONException {
        String screenText = normalizedScreenText(screenJson);
        return screenText.contains("org.openphone.assistant")
                && (screenText.contains("ask openphone")
                        || screenText.contains("what should i do?"));
    }

    private static void ensureToolReason(String toolName, JSONObject arguments, String thought)
            throws JSONException {
        if (!requiresReason(toolName) || !arguments.optString("reason", "").trim().isEmpty()) {
            return;
        }
        String reason = thought == null || thought.trim().isEmpty()
                ? "Continue the active user task." : thought.trim();
        arguments.put("reason", reason);
    }

    private static boolean requiresReason(String toolName) {
        return ToolCatalog.get().requiresReason(toolName);
    }

    private static boolean containsAny(String text, String... needles) {
        if (text == null || text.isEmpty()) {
            return false;
        }
        for (String needle : needles) {
            if (needle != null && !needle.isEmpty() && text.contains(needle)) {
                return true;
            }
        }
        return false;
    }

    private static String toolStatus(String toolResult) {
        if (toolResult == null || toolResult.trim().isEmpty()) {
            return "";
        }
        try {
            return new JSONObject(toolResult).optString("status", "");
        } catch (JSONException e) {
            return "";
        }
    }

    private static boolean isToolFailure(String toolStatus) {
        return "error".equals(toolStatus)
                || "task.failed".equals(toolStatus)
                || "screen_capture_failed".equals(toolStatus);
    }

    private static boolean shouldVerifyProgress(String toolName) {
        return ToolCatalog.get().drivesVisibleUi(toolName);
    }

    private static JSONObject finishEvidence(String userGoal, String successCriteria,
            JSONObject screenJson)
            throws JSONException {
        JSONArray visibleTextArray = screenArray(screenJson, "visible_text");
        String visibleText = joinedArray(visibleTextArray, 80);
        JSONArray elements = screenArray(screenJson, "interactive_elements");
        int elementCount = elements == null ? 0 : elements.length();
        JSONObject screenshot = screenJson.optJSONObject("screenshot");
        boolean hasScreenshot = screenshot != null && !screenshot.optString("data").isEmpty();
        JSONArray matchedTerms = new JSONArray();
        JSONArray requiredTerms = finishEvidenceTerms(userGoal, successCriteria);
        String haystack = visibleText.toLowerCase(Locale.US);
        String goal = userGoal == null ? "" : userGoal.toLowerCase(Locale.US);
        boolean simpleOpenGoalSatisfied = isSimpleOpenGoalSatisfied(goal, haystack);
        if (simpleOpenGoalSatisfied) {
            matchedTerms.put("simple_open_goal_visible");
        }
        for (int i = 0; i < requiredTerms.length(); i++) {
            String term = requiredTerms.optString(i);
            if (!term.isEmpty() && haystack.contains(term.toLowerCase(Locale.US))) {
                matchedTerms.put(term);
            }
        }
        boolean hasStructuredEvidence = !visibleText.isEmpty() || elementCount > 0;
        int requiredMatchCount = simpleOpenGoalSatisfied ? 1
                : Math.min(2, Math.max(1, requiredTerms.length()));
        boolean hasTermEvidence = requiredTerms.length() == 0
                || matchedTerms.length() >= requiredMatchCount;
        return new JSONObject()
                .put("has_screen_evidence", (hasStructuredEvidence || hasScreenshot)
                        && hasTermEvidence)
                .put("has_screenshot", hasScreenshot)
                .put("visible_text_count", visibleTextArray == null ? 0 : visibleTextArray.length())
                .put("interactive_element_count", elementCount)
                .put("success_criteria", successCriteria == null ? "" : successCriteria)
                .put("required_match_count", requiredMatchCount)
                .put("required_terms", requiredTerms)
                .put("matched_terms", matchedTerms);
    }

    private static JSONArray screenArray(JSONObject screenJson, String name) {
        if (screenJson == null) {
            return null;
        }
        JSONArray direct = screenJson.optJSONArray(name);
        if (direct != null) {
            return direct;
        }
        JSONObject uiTree = screenJson.optJSONObject("ui_tree");
        return uiTree == null ? null : uiTree.optJSONArray(name);
    }

    private static JSONArray finishEvidenceTerms(String... texts) {
        JSONArray terms = new JSONArray();
        if (texts == null) {
            return terms;
        }
        for (String text : texts) {
            String goal = text == null ? "" : text;
            String[] words = goal.split("[^A-Za-z0-9._-]+");
            for (String word : words) {
                String value = word == null ? "" : word.trim();
                if (value.length() < 4 || isStopword(value) || containsTerm(terms, value)) {
                    continue;
                }
                if (value.contains(".")) {
                    String[] pieces = value.split("[.]");
                    for (String piece : pieces) {
                        if (piece.length() >= 4 && !isStopword(piece)
                                && !containsTerm(terms, piece)) {
                            terms.put(piece);
                        }
                    }
                } else {
                    terms.put(value);
                }
                if (terms.length() >= 10) {
                    return terms;
                }
            }
        }
        return terms;
    }

    private static boolean containsTerm(JSONArray terms, String value) {
        if (value == null) {
            return false;
        }
        for (int i = 0; i < terms.length(); i++) {
            if (value.equalsIgnoreCase(terms.optString(i))) {
                return true;
            }
        }
        return false;
    }

    private static boolean isStopword(String word) {
        String value = word == null ? "" : word.toLowerCase(Locale.US);
        return "open".equals(value)
                || "then".equals(value)
                || "when".equals(value)
                || "only".equals(value)
                || "visible".equals(value)
                || "finish".equals(value)
                || "screen".equals(value)
                || "page".equals(value)
                || "task".equals(value)
                || "with".equals(value)
                || "from".equals(value)
                || "into".equals(value)
                || "that".equals(value)
                || "this".equals(value)
                || "play".equals(value)
                || "random".equals(value)
                || "https".equals(value)
                || "http".equals(value);
    }

    private static JSONObject progressVerification(JSONObject before, JSONObject after)
            throws JSONException {
        String beforeSignature = screenSignature(before);
        String afterSignature = screenSignature(after);
        boolean changed = !beforeSignature.equals(afterSignature);
        return new JSONObject()
                .put("screen_changed", changed)
                .put("before_activity", activityName(before))
                .put("after_activity", activityName(after))
                .put("before_foreground_app", foregroundPackage(before))
                .put("after_foreground_app", foregroundPackage(after))
                .put("before_signature", beforeSignature)
                .put("after_signature", afterSignature);
    }

    private static String screenSignature(JSONObject screen) {
        return foregroundPackage(screen) + "|"
                + activityName(screen) + "|"
                + joinedArray(screen.optJSONArray("visible_text"), 18) + "|"
                + elementSignature(screen.optJSONArray("interactive_elements"), 18);
    }

    private static String foregroundPackage(JSONObject screen) {
        JSONObject context = screen == null ? null : screen.optJSONObject("context");
        String value = context == null ? "" : context.optString("foreground_app", "");
        if (value.isEmpty()) {
            JSONObject uiTree = screen == null ? null : screen.optJSONObject("ui_tree");
            value = uiTree == null ? "" : uiTree.optString("foreground_package", "");
        }
        return value;
    }

    private static String activityName(JSONObject screen) {
        JSONObject context = screen == null ? null : screen.optJSONObject("context");
        return context == null ? "" : context.optString("activity", "");
    }

    private static String joinedArray(JSONArray array, int maxItems) {
        if (array == null || array.length() == 0) {
            return "";
        }
        StringBuilder builder = new StringBuilder();
        int count = Math.min(array.length(), maxItems);
        for (int i = 0; i < count; i++) {
            if (i > 0) {
                builder.append(" || ");
            }
            builder.append(compact(array.optString(i)));
        }
        return builder.toString();
    }

    private static String elementSignature(JSONArray elements, int maxItems) {
        if (elements == null || elements.length() == 0) {
            return "";
        }
        StringBuilder builder = new StringBuilder();
        int count = Math.min(elements.length(), maxItems);
        for (int i = 0; i < count; i++) {
            JSONObject element = elements.optJSONObject(i);
            if (element == null) {
                continue;
            }
            if (builder.length() > 0) {
                builder.append(" || ");
            }
            builder.append(compact(element.optString("kind")));
            builder.append(":");
            builder.append(compact(element.optString("label")));
        }
        return builder.toString();
    }

    private static String compact(String value) {
        if (value == null) {
            return "";
        }
        String compacted = value.replace('\n', ' ').replace('\r', ' ').trim();
        while (compacted.contains("  ")) {
            compacted = compacted.replace("  ", " ");
        }
        return compacted.length() <= 160 ? compacted : compacted.substring(0, 160);
    }

    private static boolean hasScreenshot(String screen) {
        if (screen == null || screen.trim().isEmpty()) {
            return false;
        }
        try {
            JSONObject screenshot = new JSONObject(screen).optJSONObject("screenshot");
            return screenshot != null && !screenshot.optString("data").isEmpty();
        } catch (JSONException e) {
            return false;
        }
    }

    private static void sleepAfterAction() {
        try {
            Thread.sleep(1200);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static String readAll(InputStream inputStream) throws IOException {
        if (inputStream == null) {
            return "";
        }
        StringBuilder builder = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(inputStream,
                StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                builder.append(line);
            }
        }
        return builder.toString();
    }

    private static String extractOutputText(JSONObject response) throws JSONException {
        String direct = response.optString("output_text", "");
        if (!direct.isEmpty()) {
            return direct;
        }
        StringBuilder builder = new StringBuilder();
        JSONArray output = response.optJSONArray("output");
        if (output == null) {
            return "";
        }
        for (int i = 0; i < output.length(); i++) {
            JSONObject item = output.optJSONObject(i);
            if (item == null) {
                continue;
            }
            JSONArray content = item.optJSONArray("content");
            if (content == null) {
                continue;
            }
            for (int j = 0; j < content.length(); j++) {
                JSONObject contentItem = content.optJSONObject(j);
                if (contentItem == null) {
                    continue;
                }
                String text = contentItem.optString("text", "");
                if (!text.isEmpty()) {
                    if (builder.length() > 0) {
                        builder.append('\n');
                    }
                    builder.append(text);
                }
            }
        }
        return builder.toString();
    }

    private static JSONObject requestMetadata(JSONObject screenJson) throws JSONException {
        JSONObject metadata = new JSONObject()
                .put("openphone_task", "true")
                .put("screen_source", screenJson.optString("source",
                        screenJson.optString("foreground_app", "unknown")));
        JSONArray riskFlags = screenJson.optJSONArray("risk_flags");
        if (riskFlags != null) {
            metadata.put("risk_flags", joinStrings(riskFlags));
        }
        String foregroundPackage = screenJson.optString("foreground_package", "");
        if (!foregroundPackage.isEmpty()) {
            metadata.put("foreground_package", foregroundPackage);
        }
        return metadata;
    }

    private static String joinStrings(JSONArray array) {
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < array.length(); i++) {
            String value = array.optString(i, "");
            if (value.isEmpty()) {
                continue;
            }
            if (builder.length() > 0) {
                builder.append(',');
            }
            builder.append(value);
        }
        return builder.toString();
    }

    private static JSONObject redactScreenshot(JSONObject screenJson) throws JSONException {
        JSONObject screenshot = screenJson.optJSONObject("screenshot");
        if (screenshot != null) {
            String data = screenshot.optString("data", "");
            if (!data.isEmpty()) {
                screenshot.put("data", "<base64 chars=" + data.length() + ">");
            }
        }
        return screenJson;
    }

    private static String summarizeError(String responseBody) {
        if (responseBody == null || responseBody.isEmpty()) {
            return "";
        }
        try {
            JSONObject error = new JSONObject(responseBody).optJSONObject("error");
            if (error != null) {
                return error.optString("message", responseBody);
            }
        } catch (JSONException ignored) {
        }
        return responseBody.length() > 500 ? responseBody.substring(0, 500) : responseBody;
    }

    private static String unavailable(String reason) {
        try {
            return new JSONObject()
                    .put("status", "provider_unavailable")
                    .put("provider", "openai_responses")
                    .put("reason", reason)
                    .put("next", "Configure a broker token or temporary dev API key")
                    .toString(2);
        } catch (JSONException e) {
            return "{\"status\":\"provider_unavailable\"}";
        }
    }

    private static String result(String status, String userGoal, JSONArray steps) throws JSONException {
        return new JSONObject()
                .put("status", status)
                .put("provider", "openai_responses")
                .put("model", MODEL())
                .put("goal", userGoal == null ? "" : userGoal)
                .put("steps", steps)
                .toString(2);
    }

    private static String cancelledResult(String userGoal, JSONArray steps) {
        try {
            return result("cancelled", userGoal, steps);
        } catch (JSONException e) {
            return "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
        }
    }

    private static String error(String status, String reason, JSONArray steps) {
        try {
            return new JSONObject()
                    .put("status", status)
                    .put("provider", "openai_responses")
                    .put("reason", reason == null ? "" : reason)
                    .put("steps", steps)
                    .toString(2);
        } catch (JSONException e) {
            return "{\"status\":\"error\"}";
        }
    }

    private static String errorJson(String reason) throws JSONException {
        return new JSONObject().put("status", "error").put("reason", reason).toString();
    }
}
