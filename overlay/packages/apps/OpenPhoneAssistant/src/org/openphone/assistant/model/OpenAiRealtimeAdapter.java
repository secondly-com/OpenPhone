package org.openphone.assistant.model;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import org.openphone.assistant.actions.ToolCatalog;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Locale;

import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

public final class OpenAiRealtimeAdapter implements ModelAdapter {
    public static final String DEFAULT_REALTIME_MODEL = "gpt-realtime";
    public static final String REALTIME_2_MODEL = "gpt-realtime-2";
    private static final int MAX_REALTIME_STEPS = 120;
    private static final int MAX_TEXT_ONLY_TURNS = 3;
    private static final long MAX_REALTIME_DURATION_MS = 55L * 60L * 1000L;
    private static final long EVENT_TIMEOUT_MS = 120000;
    private static final long CONNECT_TIMEOUT_MS = 20000;

    private final ModelEndpointConfig mEndpointConfig;
    private final String mRealtimeModel;
    private final boolean mFullYolo;
    private final OpenAiResponsesAgentAdapter mResponsesFallback;
    private volatile boolean mCancelled;
    private volatile RealtimeWebSocket mSocket;

    public OpenAiRealtimeAdapter(String apiKey) {
        this(ModelEndpointConfig.directOpenAi(apiKey));
    }

    public OpenAiRealtimeAdapter(ModelEndpointConfig endpointConfig) {
        this(endpointConfig, DEFAULT_REALTIME_MODEL);
    }

    public OpenAiRealtimeAdapter(ModelEndpointConfig endpointConfig, String realtimeModel) {
        this(endpointConfig, realtimeModel, false);
    }

    public OpenAiRealtimeAdapter(ModelEndpointConfig endpointConfig, String realtimeModel,
            boolean fullYolo) {
        mEndpointConfig = endpointConfig == null
                ? ModelEndpointConfig.directOpenAi("") : endpointConfig;
        mRealtimeModel = sanitizeRealtimeModel(realtimeModel);
        mFullYolo = fullYolo;
        mResponsesFallback = new OpenAiResponsesAgentAdapter(mEndpointConfig, mFullYolo);
    }

    @Override
    public String name() {
        return !mEndpointConfig.isDirectOpenAiResponses()
                ? mResponsesFallback.name() : "openai-realtime-agent-dev";
    }

    @Override
    public String providerDisplayName() {
        return !mEndpointConfig.isDirectOpenAiResponses()
                ? mResponsesFallback.providerDisplayName()
                : (isRealtime2Model() ? "OpenAI Realtime 2 agent" : "OpenAI Realtime agent");
    }

    @Override
    public String modelName() {
        return !mEndpointConfig.isDirectOpenAiResponses()
                ? mResponsesFallback.modelName() : mRealtimeModel;
    }

    @Override
    public boolean usesCloud() {
        return true;
    }

    @Override
    public String privacyDisclosure() {
        if (!mEndpointConfig.isDirectOpenAiResponses()) {
            return mEndpointConfig.privacyDisclosure()
                    + " Direct OpenAI Realtime WebSocket is not enabled for this provider; "
                    + "task execution uses the HTTP model router.";
        }
        return "Realtime task mode keeps a WebSocket session open with OpenAI while a task "
                + "is active. It sends the task goal, task-scoped screen observations, UI "
                + "metadata, and tool results so the model can continue a long-running "
                + "phone-agent session. Current direct model: " + mRealtimeModel
                + (isRealtime2Model() ? " with low reasoning effort." : ".");
    }

    @Override
    public void cancel() {
        mCancelled = true;
        mResponsesFallback.cancel();
        RealtimeWebSocket socket = mSocket;
        if (socket != null) {
            mSocket = null;
            new Thread(new Runnable() {
                @Override
                public void run() {
                    socket.closeQuietly();
                }
            }, "OpenPhoneRealtimeClose").start();
        }
    }

    @Override
    public String decideOrchestration(String userMessage, boolean hasActiveTask,
            String recentConversationJson) {
        return mResponsesFallback.decideOrchestration(userMessage, hasActiveTask,
                recentConversationJson);
    }

    @Override
    public String chat(String userMessage) {
        return mResponsesFallback.chat(userMessage);
    }

    @Override
    public String answerScreenQuestion(String userMessage, String screenJson) {
        return mResponsesFallback.answerScreenQuestion(userMessage, screenJson);
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
        if (!mEndpointConfig.isDirectOpenAiResponses()) {
            return mResponsesFallback.runTask(taskId, userGoal, executor);
        }

        JSONArray steps = new JSONArray();
        long startedAtMillis = System.currentTimeMillis();
        RealtimeWebSocket socket = null;
        try {
            socket = RealtimeWebSocket.connect(directRealtimeUrl(), mEndpointConfig.bearerToken());
            mSocket = socket;
            socket.send(sessionUpdateEvent());
            waitForEventType(socket, "session.updated", CONNECT_TIMEOUT_MS);
            sendUserMessage(socket, initialTaskPrompt(userGoal, mFullYolo));
            socket.send(responseCreateEvent(true));
            int textOnlyTurns = 0;

            for (int step = 1; step <= MAX_REALTIME_STEPS; step++) {
                if (mCancelled || executor.isCancelled()) {
                    return result("cancelled", userGoal, steps);
                }
                if (System.currentTimeMillis() - startedAtMillis > MAX_REALTIME_DURATION_MS) {
                    return result("duration_limit_reached", userGoal, steps);
                }

                RealtimeTurn turn = waitForTurn(socket);
                if (turn.finalText != null && !turn.finalText.trim().isEmpty()) {
                    steps.put(new JSONObject()
                            .put("step", step)
                            .put("text", turn.finalText.trim()));
                }
                if (turn.functionCalls.isEmpty()) {
                    if (turn.finalText != null && !turn.finalText.trim().isEmpty()) {
                        textOnlyTurns++;
                        if (textOnlyTurns >= MAX_TEXT_ONLY_TURNS) {
                            return result("agent.blocked", userGoal, steps, turn.finalText.trim());
                        }
                        sendUserMessage(socket, textOnlyCorrectionPrompt(turn.finalText,
                                mFullYolo));
                    }
                    socket.send(responseCreateEvent(true));
                    continue;
                }
                textOnlyTurns = 0;

                for (RealtimeFunctionCall call : turn.functionCalls) {
                    if (mCancelled || executor.isCancelled()) {
                        return result("cancelled", userGoal, steps);
                    }
                    JSONObject arguments = parseArguments(call.arguments);
                    ensureToolReason(call.name, arguments);
                    JSONObject stepJson = new JSONObject()
                            .put("step", step)
                            .put("call_id", call.callId)
                            .put("tool", call.name)
                            .put("arguments", arguments);
                    steps.put(stepJson);

                    if (!isAllowedTool(call.name)) {
                        String output = errorJson("unknown_model_tool:" + call.name);
                        stepJson.put("tool_result", output);
                        sendFunctionOutput(socket, call.callId, output);
                        return result("agent.blocked", userGoal, steps);
                    }

                    String toolResult = executor.callTool(call.name, arguments.toString());
                    stepJson.put("tool_result", redactToolResultForTrace(toolResult));
                    sendFunctionOutput(socket, call.callId, toolResult);
                    sendScreenFollowupIfUseful(socket, call.name, toolResult);

                    String status = toolStatus(toolResult);
                    if ("dry_run.preview".equals(status)) {
                        return result("dry_run.preview", userGoal, steps);
                    }
                    if ("confirmation_requested".equals(status)
                            || "confirmation_required".equals(status)) {
                        return result("confirmation_required", userGoal, steps);
                    }
                    if ("denied".equals(status)) {
                        return result("action_denied", userGoal, steps);
                    }
                    if ("task.finished".equals(status)) {
                        return result("task.finished", userGoal, steps);
                    }
                    if ("task.failed".equals(status)) {
                        return result("task.failed", userGoal, steps);
                    }
                }
                socket.send(responseCreateEvent(true));
            }
            return result("step_limit_reached", userGoal, steps);
        } catch (JSONException e) {
            return error("json_error", e.getMessage(), steps);
        } catch (IOException e) {
            if (mCancelled || executor.isCancelled()) {
                return result("cancelled", userGoal, steps);
            }
            return error("realtime_error", e.getMessage(), steps);
        } finally {
            if (mSocket == socket) {
                mSocket = null;
            }
            if (socket != null) {
                socket.closeQuietly();
            }
        }
    }

    private JSONObject sessionUpdateEvent() throws JSONException {
        JSONObject session = new JSONObject()
                .put("type", "realtime")
                .put("instructions", realtimeInstructions(mFullYolo))
                .put("output_modalities", new JSONArray().put("text"))
                .put("tool_choice", "auto")
                .put("tools", realtimeTools());
        if (isRealtime2Model()) {
            session.put("reasoning", new JSONObject().put("effort", "low"));
        }
        return new JSONObject()
                .put("type", "session.update")
                .put("session", session);
    }

    private String directRealtimeUrl() {
        return "wss://api.openai.com/v1/realtime?model=" + mRealtimeModel;
    }

    private boolean isRealtime2Model() {
        return REALTIME_2_MODEL.equals(mRealtimeModel);
    }

    private static String sanitizeRealtimeModel(String realtimeModel) {
        if (REALTIME_2_MODEL.equals(realtimeModel)) {
            return REALTIME_2_MODEL;
        }
        return DEFAULT_REALTIME_MODEL;
    }

    private static JSONObject responseCreateEvent(boolean requireTool) throws JSONException {
        JSONObject response = new JSONObject()
                .put("output_modalities", new JSONArray().put("text"));
        if (requireTool) {
            response.put("tool_choice", "required");
        }
        return new JSONObject()
                .put("type", "response.create")
                .put("response", response);
    }

    private static void sendUserMessage(RealtimeWebSocket socket, String text)
            throws IOException, JSONException {
        socket.send(new JSONObject()
                .put("type", "conversation.item.create")
                .put("item", new JSONObject()
                        .put("type", "message")
                        .put("role", "user")
                        .put("content", new JSONArray()
                                .put(new JSONObject()
                                        .put("type", "input_text")
                                        .put("text", text)))));
    }

    private static void sendFunctionOutput(RealtimeWebSocket socket, String callId, String output)
            throws IOException, JSONException {
        socket.send(new JSONObject()
                .put("type", "conversation.item.create")
                .put("item", new JSONObject()
                        .put("type", "function_call_output")
                        .put("call_id", callId)
                        .put("output", output == null ? "" : output)));
    }

    private static void sendScreenFollowupIfUseful(RealtimeWebSocket socket, String toolName,
            String toolResult) throws IOException, JSONException {
        if (!"get_screen".equals(toolName) && !"watch_screen".equals(toolName)) {
            return;
        }
        JSONObject screen = new JSONObject(toolResult == null ? "{}" : toolResult);
        JSONObject redacted = redactScreenshot(new JSONObject(screen.toString()));
        socket.send(new JSONObject()
                .put("type", "conversation.item.create")
                .put("item", new JSONObject()
                        .put("type", "message")
                        .put("role", "user")
                        .put("content", new JSONArray()
                                .put(new JSONObject()
                                        .put("type", "input_text")
                                        .put("text", "Latest phone screen observation for "
                                                + "the active task:\n" + redacted.toString(2))))));
    }

    private static RealtimeTurn waitForTurn(RealtimeWebSocket socket)
            throws IOException, JSONException {
        RealtimeTurn turn = new RealtimeTurn();
        long deadline = System.currentTimeMillis() + EVENT_TIMEOUT_MS;
        while (System.currentTimeMillis() < deadline) {
            JSONObject event = socket.readJson(deadline - System.currentTimeMillis());
            String type = event.optString("type");
            if ("error".equals(type)) {
                throw new IOException(event.optJSONObject("error") == null
                        ? event.toString() : event.optJSONObject("error").toString());
            }
            RealtimeFunctionCall call = functionCallFromEvent(event);
            if (call != null && !call.name.isEmpty() && !call.callId.isEmpty()) {
                addOrUpgradeCall(turn.functionCalls, call);
            }
            if ("response.output_text.done".equals(type)
                    || "response.text.done".equals(type)) {
                String text = event.optString("text", event.optString("content", ""));
                if (!text.isEmpty()) {
                    turn.finalText = text;
                }
            }
            if ("response.done".equals(type)) {
                JSONObject response = event.optJSONObject("response");
                if (response != null) {
                    collectResponseDone(response, turn);
                }
                return turn;
            }
        }
        throw new IOException("Timed out waiting for Realtime response.");
    }

    private static void waitForEventType(RealtimeWebSocket socket, String expectedType,
            long timeoutMs) throws IOException, JSONException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            JSONObject event = socket.readJson(deadline - System.currentTimeMillis());
            String type = event.optString("type");
            if (expectedType.equals(type)) {
                return;
            }
            if ("error".equals(type)) {
                throw new IOException(event.optJSONObject("error") == null
                        ? event.toString() : event.optJSONObject("error").toString());
            }
        }
        throw new IOException("Timed out waiting for " + expectedType + ".");
    }

    private static RealtimeFunctionCall functionCallFromEvent(JSONObject event)
            throws JSONException {
        String type = event.optString("type");
        if ("response.function_call_arguments.done".equals(type)) {
            return new RealtimeFunctionCall(
                    event.optString("call_id"),
                    event.optString("name"),
                    event.optString("arguments"));
        }
        if ("response.output_item.done".equals(type)) {
            JSONObject item = event.optJSONObject("item");
            if (item != null && "function_call".equals(item.optString("type"))) {
                return new RealtimeFunctionCall(
                        item.optString("call_id"),
                        item.optString("name"),
                        item.optString("arguments"));
            }
        }
        return null;
    }

    private static void collectResponseDone(JSONObject response, RealtimeTurn turn)
            throws JSONException {
        JSONArray output = response.optJSONArray("output");
        if (output == null) {
            return;
        }
        for (int i = 0; i < output.length(); i++) {
            JSONObject item = output.optJSONObject(i);
            if (item == null) {
                continue;
            }
            if ("function_call".equals(item.optString("type"))) {
                RealtimeFunctionCall call = new RealtimeFunctionCall(
                        item.optString("call_id"),
                        item.optString("name"),
                        item.optString("arguments"));
                if (!call.callId.isEmpty() && !call.name.isEmpty()) {
                    addOrUpgradeCall(turn.functionCalls, call);
                }
            } else if ("message".equals(item.optString("type"))) {
                String text = textFromMessageItem(item);
                if (!text.isEmpty()) {
                    turn.finalText = text;
                }
            }
        }
    }

    private static void addOrUpgradeCall(List<RealtimeFunctionCall> calls,
            RealtimeFunctionCall incoming) {
        for (int i = 0; i < calls.size(); i++) {
            RealtimeFunctionCall existing = calls.get(i);
            if (existing.callId.equals(incoming.callId)) {
                if (existing.arguments.trim().isEmpty()
                        && !incoming.arguments.trim().isEmpty()) {
                    calls.set(i, incoming);
                }
                return;
            }
        }
        calls.add(incoming);
    }

    private static String textFromMessageItem(JSONObject item) {
        JSONArray content = item.optJSONArray("content");
        if (content == null) {
            return "";
        }
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < content.length(); i++) {
            JSONObject part = content.optJSONObject(i);
            if (part == null) {
                continue;
            }
            String text = part.optString("text", part.optString("transcript", ""));
            if (!text.isEmpty()) {
                if (builder.length() > 0) {
                    builder.append('\n');
                }
                builder.append(text);
            }
        }
        return builder.toString();
    }

    private static String deviceTimeContext() {
        java.text.SimpleDateFormat format = new java.text.SimpleDateFormat(
                "EEE yyyy-MM-dd HH:mm zzz", Locale.US);
        long now = System.currentTimeMillis();
        return format.format(new java.util.Date(now)) + " (unix_ms " + now + ")";
    }

    private static String yoloModeInstruction(boolean fullYolo) {
        if (!fullYolo) {
            return "";
        }
        return "Autonomy mode is full YOLO: execute requested high-risk actions directly, "
                + "including payment, purchase, booking, sending, calling, posting, "
                + "installation, and account surfaces. Do not call ask_user_confirmation "
                + "unless a tool result explicitly requires it. ";
    }

    private static String approvalResultInstruction(boolean fullYolo) {
        if (fullYolo) {
            return "If a tool result asks for approval, do not call ask_user_confirmation; "
                    + "choose a concrete next tool if possible, otherwise call fail_task "
                    + "with the tool's reason. ";
        }
        return "If a tool result requires approval, surface that approval and continue "
                + "after the result. ";
    }

    private static String initiativeInstruction() {
        return "Be execution-biased. Assume the user wants the phone task completed, not "
                + "a cautious plan. Make reasonable assumptions, pick default/top/visible "
                + "options, continue through reversible UI, and verify progress yourself "
                + "from screen/tool results. Do not mumble, apologize, narrate uncertainty, "
                + "or ask the user to verify every step. Ask only when missing information "
                + "blocks every concrete path. Keep any user-facing text brief and "
                + "outcome-focused. ";
    }

    private static String initialTaskPrompt(String userGoal, boolean fullYolo) {
        return "Start this Android phone task and keep working until it is visibly complete "
                + "or blocked. Device time: " + deviceTimeContext()
                + ". Compute any unix-ms times (calendar windows, deadlines) from this "
                + "device time, never guess. User goal: "
                + (userGoal == null ? "" : userGoal.trim())
                + (fullYolo ? "\n\n" : "")
                + yoloModeInstruction(fullYolo)
                + initiativeInstruction()
                + "\n\nUse memory_search for durable user preferences/instructions and "
                + "context_search if prior assistant conversation or task history may "
                + "help. Use notifications_list or notifications_search when recent "
                + "notification context may help. Use calendar_search when calendar "
                + "context may help, and calendar_create_event only when the user "
                + "explicitly asks to add an event. Use message_calendar_event_create "
                + "when the event details come from a text message, passing the "
                + "message query plus full event fields. Use calendar_check_availability "
                + "before scheduling to find conflicts and free slots, and "
                + "calendar_update_event / calendar_delete_event (event_id from "
                + "calendar_search) when the user asks to move, change, or cancel an "
                + "existing event. Use contacts_search when contact "
                + "context may help. Use messages_search for SMS context, messages_draft "
                + "to prepare a text, and messages_send only when the user explicitly "
                + "asked to send an SMS. Use calls_search for call history context "
                + "(type=missed filters missed calls; names join from contacts) and "
                + "calls_place only when the user explicitly asks you to place a call. "
                + "Use phone_context for who-is-this/call-prep questions; it includes "
                + "missed calls not yet returned. "
                + "For app-internal tasks, opening the app is only the first step. If the "
                + "user asks to play media, search, choose content, change a setting, book, "
                + "buy, post, send, or otherwise operate inside an app, continue through "
                + "the visible workflow until the requested result is visible or a tool "
                + "result reports a real block. For media playback, finish only when "
                + "visible playback evidence exists, such as a now-playing screen, pause "
                + "button, media title/source, or mini-player; never tell the user to choose "
                + "the content themselves. Do not ask the user to choose among ordinary visible "
                + "options. For random, any, something, surprise me, best, or unspecified "
                + "preference requests, choose a reasonable/default/top visible option "
                + "yourself and continue. Ask only when missing information blocks every "
                + "concrete next step. "
                + approvalResultInstruction(fullYolo)
                + "Use browser_fetch_page when the user asks to summarize or answer "
                + "questions about a specific URL; its result includes headings and "
                + "links, so follow a returned link with another browser_fetch_page "
                + "call when the answer lives on a linked page. "
                + "Use memory_save only for explicit durable facts/preferences the "
                + "user asked you to remember. Use commitment_create for explicit follow-up "
                + "or reminder requests. Use watcher_create when the user asks to monitor "
                + "something and alert or react later. If the user wants an action when the "
                + "trigger happens, put it in delivery.tool plus delivery.arguments, or "
                + "delivery.prompt for a background agent job; delivery arguments can use "
                + "event templates such as {{event.number}}, {{event.address}}, "
                + "{{event.title}}, and {{event.text}}. For \"tell me if X replies\" or \"remind me "
                + "if X does not reply\" use source=message with the contact's number as "
                + "address (plus deadline_at and notify_on=no_reply for the no-reply case); "
                + "for \"tell me when X calls\" or \"remind me to call X back\" use "
                + "source=call with the number (plus deadline_at and notify_on=no_call to "
                + "remind only if no call happened in time). "
                + "First call get_screen with include_ui_tree=true, include_activity=true, and "
                + "include_screenshot=true before operating visible UI. Treat the screenshot "
                + "as the rendered full-screen view and the accessibility tree as supplemental "
                + "metadata. When the UI tree is sparse, custom-rendered, or missing labels, "
                + "do not claim you can only see a limited accessibility view; use the "
                + "screenshot and raw coordinates when needed. Then choose one phone tool at "
                + "a time. Continue after each tool result. Call finish_task only when the "
                + "visible screen satisfies the goal.";
    }

    private static String textOnlyCorrectionPrompt(String modelText, boolean fullYolo) {
        return "You replied with text instead of taking a phone-agent step: "
                + (modelText == null ? "" : modelText.trim())
                + "\n\nDo not ask for review, ask a preference question, or narrate. Choose "
                + "exactly one tool call now. "
                + "If you have not observed the phone yet, call get_screen. If the task is "
                + "already visibly complete, call finish_task. "
                + (fullYolo
                        ? "Do not call ask_user_confirmation in full YOLO; if no concrete "
                                + "step exists, call fail_task. "
                        : "If a tool result requires approval, call ask_user_confirmation "
                                + "with action_json; if no concrete step exists, call fail_task. ")
                + "For random, any, or unspecified "
                + "preference requests, choose a reasonable option yourself.";
    }

    private static String realtimeInstructions(boolean fullYolo) {
        return "You are OpenPhone Agent, a persistent mobile GUI agent running inside Android. "
                + "You can control the phone only through the provided function tools. "
                + yoloModeInstruction(fullYolo)
                + initiativeInstruction()
                + "Work on long-horizon tasks: observe, decide one action, inspect the result, "
                + "recover from no-ops, and continue until the task is visibly complete. "
                + "You are capable of operating apps end to end; do not narrate doubts, "
                + "ask for preferences, or ask for review when a concrete next step exists. "
                + "Use memory_search for durable user preferences and instructions. Use "
                + "context_search for relevant prior assistant conversation or task "
                + "history. Use notifications_list or notifications_search for recent "
                + "notification context. Use calendar_search when calendar context may "
                + "help, and calendar_create_event when the user explicitly asks to add "
                + "an event. Prefer message_calendar_event_create when the event comes "
                + "from a text message: include the message query and complete event "
                + "fields in one call. Check calendar_check_availability before "
                + "scheduling when conflicts matter, and use calendar_update_event or "
                + "calendar_delete_event with an event_id from calendar_search when the "
                + "user asks to move, change, or cancel an existing event. "
                + "Use contacts_search when contact context may help. "
                + "Use messages_search, messages_draft, and messages_send for SMS tasks "
                + "instead of driving the Messages UI when possible. Use calls_search "
                + "and calls_place for phone tasks instead of driving the Dialer UI "
                + "when possible. Use browser_fetch_page for URL/page questions before "
                + "falling back to visible browser UI; it returns headings and links, "
                + "and you may chain another browser_fetch_page on a returned link to "
                + "reach the page that actually answers the question. "
                + "For app-internal tasks, opening the app is only the first step. If the "
                + "user asks to play media, search, choose content, change a setting, book, "
                + "buy, post, send, or otherwise operate inside an app, continue through "
                + "the visible workflow until the requested result is visible or a tool "
                + "result reports a real block. For media playback, finish only when "
                + "visible playback evidence exists, such as a now-playing screen, pause "
                + "button, media title/source, or mini-player; never tell the user to choose "
                + "the content themselves. Do not ask the user to choose among ordinary visible "
                + "options. For random, any, something, surprise me, best, or unspecified "
                + "preference requests, choose a reasonable/default/top visible option "
                + "yourself and continue. Ask only when missing information blocks every "
                + "concrete next step. "
                + approvalResultInstruction(fullYolo)
                + "Use memory_save only when the user explicitly asks you to "
                + "remember durable information. Use commitment_create for explicit open "
                + "loops and follow-up requests. Use watcher_create for durable background "
                + "monitoring requests that may alert or react later. Put requested trigger "
                + "reactions in delivery.tool plus delivery.arguments, or delivery.prompt "
                + "for a background agent job; delivery arguments can use event templates "
                + "such as {{event.number}}, {{event.address}}, {{event.title}}, and "
                + "{{event.text}}. If the user asks to monitor SMS/messages and then "
                + "check, research, classify, summarize, or otherwise reason "
                + "about each message, create a message watcher with match_any=true and "
                + "recurring=true, then put the requested work in delivery.prompt so the "
                + "fired watcher starts a background agent job. That prompt should include "
                + "{{event.text}} and may instruct the agent to use browser_search or "
                + "browser_fetch_page for internet context before notifying the user. "
                + "This includes message replies (source=message with "
                + "address; add deadline_at and notify_on=no_reply to remind only when "
                + "no reply arrives in time) and calls (source=call with the number; "
                + "notify_on=call alerts on a call, notify_on=no_call plus deadline_at "
                + "reminds only if no call happened in time). Use get_screen often. Prefer tap_element over raw tap when an "
                + "element id is available. Do not repeat a failed action. If a page is loading, wait then "
                + "observe. For open-app or open-site goals, finish once the app/site is "
                + "visible; for anything more specific, keep operating the app. "
                + approvalResultInstruction(fullYolo)
                + "Otherwise keep using tools. Do not answer with plain text instead of "
                + "using tools unless no tool can make progress. "
                + "Never say Done unless finish_task has been called.";
    }

    private static JSONArray realtimeTools() throws JSONException {
        return ToolCatalog.get().realtimeToolDefinitions();
    }

    private static JSONObject parseArguments(String arguments) {
        try {
            return new JSONObject(arguments == null || arguments.trim().isEmpty()
                    ? "{}" : arguments);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static void ensureToolReason(String toolName, JSONObject arguments)
            throws JSONException {
        if (!requiresReason(toolName) || !arguments.optString("reason", "").trim().isEmpty()) {
            return;
        }
        arguments.put("reason", "Continue the active phone task.");
    }

    private static boolean requiresReason(String toolName) {
        return ToolCatalog.get().requiresReason(toolName);
    }

    private static boolean isAllowedTool(String toolName) {
        return ToolCatalog.get().isAllowedTool(toolName);
    }

    private static String toolStatus(String toolResult) {
        try {
            JSONObject json = new JSONObject(toolResult == null ? "{}" : toolResult);
            return json.optString("status", json.optString("error"));
        } catch (JSONException e) {
            return "";
        }
    }

    private static String redactToolResultForTrace(String toolResult) {
        try {
            return redactScreenshot(new JSONObject(toolResult == null ? "{}" : toolResult))
                    .toString();
        } catch (JSONException e) {
            return toolResult == null ? "" : toolResult;
        }
    }

    private static JSONObject redactScreenshot(JSONObject object) throws JSONException {
        JSONObject screenshot = object.optJSONObject("screenshot");
        if (screenshot != null && screenshot.has("data")) {
            screenshot.put("data", "[redacted:" + screenshot.optString("mime_type", "image")
                    + "]");
        }
        return object;
    }

    private String result(String status, String userGoal, JSONArray steps) {
        return result(status, userGoal, steps, null);
    }

    private String result(String status, String userGoal, JSONArray steps, String modelText) {
        try {
            JSONObject result = new JSONObject()
                    .put("status", status)
                    .put("provider", "openai-realtime-agent-dev")
                    .put("model", mRealtimeModel)
                    .put("goal", userGoal == null ? "" : userGoal)
                    .put("steps", steps);
            if (modelText != null && !modelText.trim().isEmpty()) {
                result.put("model_text", modelText.trim());
            }
            return result.toString(2);
        } catch (JSONException e) {
            return "{\"status\":\"" + status + "\"}";
        }
    }

    private String error(String status, String message, JSONArray steps) {
        try {
            return new JSONObject()
                    .put("status", status)
                    .put("provider", "openai-realtime-agent-dev")
                    .put("model", mRealtimeModel)
                    .put("message", message == null ? "" : message)
                    .put("steps", steps)
                    .toString(2);
        } catch (JSONException e) {
            return "{\"status\":\"" + status + "\"}";
        }
    }

    private static String unavailable(String reason) {
        try {
            return new JSONObject()
                    .put("status", "unavailable")
                    .put("provider", "openai-realtime-agent-dev")
                    .put("reason", reason == null ? "" : reason)
                    .toString(2);
        } catch (JSONException e) {
            return "{\"status\":\"unavailable\"}";
        }
    }

    private static String errorJson(String reason) {
        try {
            return new JSONObject().put("status", "error").put("reason", reason).toString();
        } catch (JSONException e) {
            return "{\"status\":\"error\"}";
        }
    }

    private static String escapeForJson(String text) {
        return text == null ? "" : text.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static final class RealtimeTurn {
        final List<RealtimeFunctionCall> functionCalls = new ArrayList<>();
        String finalText;
    }

    private static final class RealtimeFunctionCall {
        final String callId;
        final String name;
        final String arguments;

        RealtimeFunctionCall(String callId, String name, String arguments) {
            this.callId = callId == null ? "" : callId;
            this.name = name == null ? "" : name;
            this.arguments = arguments == null ? "" : arguments;
        }
    }

    private static final class RealtimeWebSocket {
        private static final String WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        private final SSLSocket mSocket;
        private final InputStream mInput;
        private final OutputStream mOutput;
        private final SecureRandom mRandom = new SecureRandom();

        private RealtimeWebSocket(SSLSocket socket) throws IOException {
            mSocket = socket;
            mInput = socket.getInputStream();
            mOutput = socket.getOutputStream();
        }

        static RealtimeWebSocket connect(String url, String bearerToken) throws IOException {
            URI uri = URI.create(url);
            String host = uri.getHost();
            int port = uri.getPort() > 0 ? uri.getPort() : 443;
            String path = uri.getRawPath();
            if (uri.getRawQuery() != null && !uri.getRawQuery().isEmpty()) {
                path += "?" + uri.getRawQuery();
            }
            SSLSocket socket = (SSLSocket) SSLSocketFactory.getDefault()
                    .createSocket(host, port);
            socket.setSoTimeout((int) CONNECT_TIMEOUT_MS);
            socket.startHandshake();

            byte[] nonce = new byte[16];
            new SecureRandom().nextBytes(nonce);
            String key = Base64.getEncoder().encodeToString(nonce);
            String request = "GET " + path + " HTTP/1.1\r\n"
                    + "Host: " + host + "\r\n"
                    + "Upgrade: websocket\r\n"
                    + "Connection: Upgrade\r\n"
                    + "Sec-WebSocket-Key: " + key + "\r\n"
                    + "Sec-WebSocket-Version: 13\r\n"
                    + "Authorization: Bearer " + bearerToken + "\r\n"
                    + "\r\n";
            OutputStream output = socket.getOutputStream();
            output.write(request.getBytes(StandardCharsets.US_ASCII));
            output.flush();

            BufferedReader reader = new BufferedReader(new InputStreamReader(
                    socket.getInputStream(), StandardCharsets.US_ASCII));
            String status = reader.readLine();
            if (status == null || !status.contains(" 101 ")) {
                throw new IOException("Realtime WebSocket upgrade failed: " + status);
            }
            String accept = "";
            String line;
            while ((line = reader.readLine()) != null && !line.isEmpty()) {
                int colon = line.indexOf(':');
                if (colon > 0 && "sec-websocket-accept".equals(
                        line.substring(0, colon).trim().toLowerCase(Locale.US))) {
                    accept = line.substring(colon + 1).trim();
                }
            }
            String expected = websocketAccept(key);
            if (!expected.equals(accept)) {
                throw new IOException("Realtime WebSocket accept mismatch.");
            }
            socket.setSoTimeout((int) EVENT_TIMEOUT_MS);
            return new RealtimeWebSocket(socket);
        }

        void send(JSONObject event) throws IOException {
            sendText(event.toString());
        }

        JSONObject readJson(long timeoutMs) throws IOException, JSONException {
            mSocket.setSoTimeout((int) Math.max(1, Math.min(timeoutMs, EVENT_TIMEOUT_MS)));
            String text = readText();
            return new JSONObject(text);
        }

        void closeQuietly() {
            try {
                sendFrame(0x8, new byte[0]);
            } catch (IOException ignored) {
            }
            closeSocketQuietly();
        }

        void closeSocketQuietly() {
            try {
                mSocket.close();
            } catch (IOException ignored) {
            }
        }

        private void sendText(String text) throws IOException {
            sendFrame(0x1, text.getBytes(StandardCharsets.UTF_8));
        }

        private void sendFrame(int opcode, byte[] payload) throws IOException {
            ByteArrayOutputStream frame = new ByteArrayOutputStream();
            frame.write(0x80 | (opcode & 0x0f));
            int length = payload.length;
            if (length <= 125) {
                frame.write(0x80 | length);
            } else if (length <= 65535) {
                frame.write(0x80 | 126);
                frame.write((length >>> 8) & 0xff);
                frame.write(length & 0xff);
            } else {
                frame.write(0x80 | 127);
                for (int i = 7; i >= 0; i--) {
                    frame.write((int) ((long) length >>> (8 * i)) & 0xff);
                }
            }
            byte[] mask = new byte[4];
            mRandom.nextBytes(mask);
            frame.write(mask);
            for (int i = 0; i < payload.length; i++) {
                frame.write(payload[i] ^ mask[i % 4]);
            }
            mOutput.write(frame.toByteArray());
            mOutput.flush();
        }

        private String readText() throws IOException {
            ByteArrayOutputStream message = new ByteArrayOutputStream();
            while (true) {
                int b0 = readByte();
                int b1 = readByte();
                boolean fin = (b0 & 0x80) != 0;
                int opcode = b0 & 0x0f;
                boolean masked = (b1 & 0x80) != 0;
                long length = b1 & 0x7f;
                if (length == 126) {
                    length = ((long) readByte() << 8) | readByte();
                } else if (length == 127) {
                    length = 0;
                    for (int i = 0; i < 8; i++) {
                        length = (length << 8) | readByte();
                    }
                }
                byte[] mask = null;
                if (masked) {
                    mask = new byte[] {
                            (byte) readByte(), (byte) readByte(),
                            (byte) readByte(), (byte) readByte()
                    };
                }
                if (length > 16L * 1024L * 1024L) {
                    throw new IOException("Realtime frame too large: " + length);
                }
                byte[] payload = readBytes((int) length);
                if (masked && mask != null) {
                    for (int i = 0; i < payload.length; i++) {
                        payload[i] = (byte) (payload[i] ^ mask[i % 4]);
                    }
                }
                if (opcode == 0x8) {
                    throw new IOException("Realtime WebSocket closed.");
                }
                if (opcode == 0x9) {
                    sendFrame(0xA, payload);
                    continue;
                }
                if (opcode == 0xA) {
                    continue;
                }
                if (opcode == 0x1 || opcode == 0x0) {
                    message.write(payload);
                    if (fin) {
                        return message.toString(StandardCharsets.UTF_8.name());
                    }
                }
            }
        }

        private int readByte() throws IOException {
            int value = mInput.read();
            if (value < 0) {
                throw new IOException("Realtime WebSocket EOF.");
            }
            return value;
        }

        private byte[] readBytes(int length) throws IOException {
            ByteBuffer buffer = ByteBuffer.allocate(length);
            byte[] chunk = new byte[Math.min(8192, Math.max(1, length))];
            while (buffer.position() < length) {
                int count = mInput.read(chunk, 0, Math.min(chunk.length,
                        length - buffer.position()));
                if (count < 0) {
                    throw new IOException("Realtime WebSocket EOF.");
                }
                buffer.put(chunk, 0, count);
            }
            return buffer.array();
        }

        private static String websocketAccept(String key) throws IOException {
            try {
                MessageDigest sha1 = MessageDigest.getInstance("SHA-1");
                byte[] digest = sha1.digest((key + WS_GUID).getBytes(StandardCharsets.US_ASCII));
                return Base64.getEncoder().encodeToString(digest);
            } catch (java.security.NoSuchAlgorithmException e) {
                throw new IOException(e);
            }
        }
    }
}
