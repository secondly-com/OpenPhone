package org.openphone.assistant.model;

import org.json.JSONException;
import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Locale;

public final class LocalHeuristicModelAdapter implements ModelAdapter {
    private volatile boolean mCancelled;

    @Override
    public String name() {
        return "local-heuristic-dev";
    }

    @Override
    public String providerDisplayName() {
        return "Local heuristic";
    }

    @Override
    public String modelName() {
        return "local-heuristic";
    }

    @Override
    public boolean usesCloud() {
        return false;
    }

    @Override
    public String privacyDisclosure() {
        return "Runs on device without a cloud model request. It uses the active screen "
                + "context exposed by OpenPhone for this task.";
    }

    @Override
    public void cancel() {
        mCancelled = true;
    }

    /**
     * Offline-dev decision shim. Production routing is model-driven through
     * the cloud adapters; these keyword heuristics exist only so a device
     * without model credentials can still answer, stop, and run the
     * deterministic smoke-test tasks below.
     */
    @Override
    public String decideOrchestration(String userMessage, boolean hasActiveTask,
            String recentConversationJson) {
        String text = normalize(userMessage);
        try {
            if (isStopIntent(text)) {
                return decision("stop", "", "");
            }
            if (isScreenQuestion(text)) {
                return decision("inspect_screen", "", "");
            }
            if (isLikelyTask(text) || (hasActiveTask && isTaskFollowUp(text))) {
                return decision("act", "", userMessage);
            }
            return decision("answer", chat(userMessage), "");
        } catch (JSONException e) {
            return "{\"mode\":\"answer\",\"reply\":\"I could not route that message.\"}";
        }
    }

    @Override
    public String chat(String userMessage) {
        String message = userMessage == null ? "" : userMessage.trim();
        String lower = message.toLowerCase(Locale.US);
        if (lower.equals("hi") || lower.equals("hello") || lower.equals("hey")
                || lower.startsWith("hello ") || lower.startsWith("hi ")) {
            return "Hi. I can chat, answer questions, or help operate this phone. "
                    + "Ask a question, or use an action request like \"Open Settings\".";
        }
        if (message.endsWith("?")) {
            return "I can answer simple questions locally, but network chat is not configured. "
                    + "Open Developer settings and choose OpenAI, OpenAI-compatible, "
                    + "Ollama, Qwen Omni, or broker mode for full AI chat.";
        }
        return "I can chat here. For phone actions, phrase it as a command like "
                + "\"Open Settings\" or \"Go back\".";
    }

    @Override
    public String answerScreenQuestion(String userMessage, String screenJson) {
        try {
            JSONObject screen = new JSONObject(screenJson == null ? "{}" : screenJson);
            JSONArray visibleText = screen.optJSONArray("visible_text");
            if (visibleText != null && visibleText.length() > 0) {
                StringBuilder builder = new StringBuilder("I can see text on the screen including: ");
                for (int i = 0; i < visibleText.length() && i < 8; i++) {
                    String value = visibleText.optString(i, "").trim();
                    if (value.isEmpty()) {
                        continue;
                    }
                    if (builder.charAt(builder.length() - 1) != ' ') {
                        builder.append("; ");
                    }
                    builder.append(value);
                }
                return builder.toString();
            }
            JSONObject context = screen.optJSONObject("context");
            if (context != null) {
                String pkg = context.optString("package", context.optString("package_name", ""));
                String activity = context.optString("activity", "");
                if (!pkg.isEmpty() || !activity.isEmpty()) {
                    return "The foreground screen appears to be " + pkg + " " + activity + ".";
                }
            }
        } catch (JSONException ignored) {
        }
        return "I can inspect the current screen, but the local adapter did not receive readable "
                + "screen text. Enable the cloud model for visual screen understanding.";
    }

    public static boolean canHandleTask(String userGoal) {
        String goal = userGoal == null ? "" : userGoal.toLowerCase(Locale.US);
        return goal.contains("setting") || goal.contains("home") || goal.contains("back")
                || goal.contains("app") || goal.contains("apps")
                || goal.contains("calendar")
                || goal.contains("contact")
                || goal.contains("message") || goal.contains("messages")
                || goal.contains("sms") || goal.contains("text ")
                || goal.contains("call") || goal.contains("phone")
                || goal.contains("web search") || goal.contains("search the web")
                || extractUrl(userGoal).length() > 0
                || isNotificationSummaryGoal(goal)
                || isNotificationCommitmentGoal(goal)
                || extractNotificationOpenQuery(goal).length() > 0;
    }

    private static String normalize(String message) {
        String text = message == null ? "" : message.trim().toLowerCase(Locale.US)
                .replace("%20", " ")
                .replace('+', ' ');
        while (text.contains("  ")) {
            text = text.replace("  ", " ");
        }
        while (!text.isEmpty() && !Character.isLetterOrDigit(text.charAt(0))) {
            text = text.substring(1).trim();
        }
        return text;
    }

    private static boolean isScreenQuestion(String text) {
        return containsAny(text, "what's on my screen", "what is on my screen",
                "what am i looking at", "describe my screen", "describe the screen",
                "summarize this page", "summarise this page", "summarize this screen",
                "summarise this screen", "what is visible", "what's visible")
                || (text.endsWith("?") && containsAny(text, "screen", "visible",
                        "this page", "current page", "this app", "current app"));
    }

    private static boolean isLikelyTask(String text) {
        return startsWithAny(text, "open ", "launch ", "go to ", "navigate to ",
                "tap ", "click ", "press ", "swipe ", "scroll ", "type ", "enter ",
                "turn on ", "turn off ", "enable ",
                "disable ", "set ", "send ", "share ", "call ", "install ", "watch ",
                "monitor ",
                "notify me when ", "tell me when ",
                "phone ", "dial ", "download ", "create ", "add ", "schedule ", "start ", "stop ",
                "draft ", "compose ",
                "show ", "list ", "search ", "find ", "fetch ", "summarize ", "summarise ",
                "read ",
                "please open ", "please launch ",
                "can you open ", "can you launch ", "could you open ",
                "could you launch ", "go back", "go home", "press back", "press home")
                || containsAny(text, " on my phone", " on this phone", " in this app",
                "using this app", "calendar event", "my calendar",
                "my contacts", "contact list", "my messages",
                "message history", "sms history", "recent calls",
                "call history", "missed calls", "missed notifications",
                "what did i miss", "this url", "this link");
    }

    private static boolean isStopIntent(String text) {
        return text.equals("stop") || text.equals("cancel") || text.equals("abort")
                || text.equals("stop agent") || text.equals("cancel task")
                || text.equals("stop task");
    }

    private static boolean isTaskFollowUp(String text) {
        return startsWithAny(text, "continue", "try again", "do it", "run it",
                "keep going", "next", "that one", "the first one", "the second one");
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

    private static boolean startsWithAny(String text, String... prefixes) {
        if (text == null || text.isEmpty()) {
            return false;
        }
        for (String prefix : prefixes) {
            if (prefix != null && !prefix.isEmpty() && text.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }

    private static String decision(String mode, String reply, String taskGoal)
            throws JSONException {
        return new JSONObject()
                .put("mode", mode)
                .put("reply", reply == null ? "" : reply)
                .put("task_goal", taskGoal == null ? "" : taskGoal)
                .put("reason", "local_heuristic_offline_shim")
                .toString();
    }

    @Override
    public String runTask(String taskId, String userGoal, ToolExecutor executor) {
        mCancelled = false;
        String goal = userGoal == null ? "" : userGoal.toLowerCase(Locale.US);
        JSONArray steps = new JSONArray();
        if (mCancelled || executor.isCancelled()) {
            return cancelled();
        }
        String screenRequest = "{\"reason\":\"observe current screen for local heuristic task\"}";
        String screen = executor.callTool("get_screen", screenRequest);
        recordStep(steps, "get_screen", screenRequest, screen);
        if (mCancelled || executor.isCancelled()) {
            return cancelled();
        }
        try {
            String notificationQuery = extractNotificationOpenQuery(goal);
            if (isNotificationSummaryGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("limit", 20)
                        .put("reason", "User asked what notifications they missed");
                String toolResult = executor.callTool("notifications_summary", arguments.toString());
                recordStep(steps, "notifications_summary", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                JSONObject result = new JSONObject(toolResult == null ? "{}" : toolResult);
                if ("notifications.summary".equals(result.optString("status", ""))) {
                    return result("task.finished", userGoal,
                            result.optString("summary",
                                    "Summarized recent notifications through the local adapter."),
                            steps);
                }
                return error("task.failed",
                        result.optString("status", "notifications_summary_failed"), steps);
            } else if (isNotificationCommitmentGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", notificationCommitmentQuery(userGoal))
                        .put("reason", "User asked to create a commitment from a notification");
                String toolResult = executor.callTool("notification_commitment_create",
                        arguments.toString());
                recordStep(steps, "notification_commitment_create",
                        arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                JSONObject result = new JSONObject(toolResult == null ? "{}" : toolResult);
                if ("notification.commitment_created".equals(result.optString("status", ""))) {
                    return result("task.finished", userGoal,
                            "Created a commitment from the matching notification.",
                            steps);
                }
                return error("task.failed",
                        result.optString("status", "notification_commitment_failed"), steps);
            } else if (!notificationQuery.isEmpty()) {
                JSONObject arguments = new JSONObject()
                        .put("query", notificationQuery)
                        .put("reason", "User asked to open a matching notification");
                String toolResult = executor.callTool("notifications_open", arguments.toString());
                recordStep(steps, "notifications_open", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("notification.opened".equals(status)) {
                    return result("task.finished", userGoal,
                            "Opened the matching notification.", steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "notification_open_failed" : status,
                        steps);
            } else if (goal.contains("calendar")
                    && containsAny(goal, "show", "list", "search", "what")) {
                JSONObject arguments = new JSONObject()
                        .put("query", calendarSearchQuery(userGoal))
                        .put("limit", 8)
                        .put("reason", "User asked for calendar events");
                String toolResult = executor.callTool("calendar_search", arguments.toString());
                recordStep(steps, "calendar_search", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("calendar.search.results".equals(status)) {
                    return result("task.finished", userGoal,
                            "Read calendar events through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "calendar_search_failed" : status,
                        steps);
            } else if (isMessageCalendarEventGoal(goal)) {
                long startAt = System.currentTimeMillis() + 60L * 60L * 1000L;
                JSONObject arguments = new JSONObject()
                        .put("query", messageCalendarEventQuery(userGoal))
                        .put("title", calendarEventTitle(userGoal))
                        .put("start_at", startAt)
                        .put("duration_minutes", 30)
                        .put("reason", "User asked to create a calendar event from an SMS message");
                String toolResult = executor.callTool("message_calendar_event_create",
                        arguments.toString());
                recordStep(steps, "message_calendar_event_create",
                        arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("calendar.event_created_from_message".equals(status)) {
                    return result("task.finished", userGoal,
                            "Created the calendar event from the matching message.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "message_calendar_create_failed" : status,
                        steps);
            } else if (goal.contains("calendar")
                    && containsAny(goal, "create", "add", "schedule")) {
                long startAt = System.currentTimeMillis() + 60L * 60L * 1000L;
                JSONObject arguments = new JSONObject()
                        .put("title", calendarEventTitle(userGoal))
                        .put("start_at", startAt)
                        .put("duration_minutes", 30)
                        .put("reason", "User asked to create a calendar event");
                String toolResult = executor.callTool("calendar_create_event",
                        arguments.toString());
                recordStep(steps, "calendar_create_event", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("calendar.event_created".equals(status)) {
                    return result("task.finished", userGoal,
                            "Created the calendar event through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "calendar_create_failed" : status,
                        steps);
            } else if (goal.contains("contact")
                    && containsAny(goal, "show", "list", "search", "find", "lookup",
                            "look up", "who")) {
                JSONObject arguments = new JSONObject()
                        .put("query", contactSearchQuery(userGoal))
                        .put("limit", 8)
                        .put("include_details", true)
                        .put("reason", "User asked for contacts");
                String toolResult = executor.callTool("contacts_search", arguments.toString());
                recordStep(steps, "contacts_search", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("contacts.search.results".equals(status)) {
                    return result("task.finished", userGoal,
                            "Read contacts through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "contacts_search_failed" : status,
                        steps);
            } else if (isMessageCommitmentGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", messageCommitmentQuery(userGoal))
                        .put("reason", "User asked to create a commitment from an SMS message");
                String toolResult = executor.callTool("message_commitment_create",
                        arguments.toString());
                recordStep(steps, "message_commitment_create", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                JSONObject result = new JSONObject(toolResult == null ? "{}" : toolResult);
                if ("message.commitment_created".equals(result.optString("status", ""))) {
                    return result("task.finished", userGoal,
                            "Created a commitment from the matching message.",
                            steps);
                }
                return error("task.failed",
                        result.optString("status", "message_commitment_failed"), steps);
            } else if (isMessageSummaryGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", messageSearchQuery(userGoal))
                        .put("limit", 30)
                        .put("reason", "User asked for a summary of SMS messages");
                String toolResult = executor.callTool("messages_summary", arguments.toString());
                recordStep(steps, "messages_summary", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                JSONObject result = new JSONObject(toolResult == null ? "{}" : toolResult);
                if ("messages.summary".equals(result.optString("status", ""))) {
                    return result("task.finished", userGoal,
                            result.optString("summary",
                                    "Summarized messages through the local development adapter."),
                            steps);
                }
                return error("task.failed",
                        result.optString("status", "messages_summary_failed"), steps);
            } else if (isMessageSearchGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", messageSearchQuery(userGoal))
                        .put("limit", 8)
                        .put("reason", "User asked for SMS message history");
                String toolResult = executor.callTool("messages_search", arguments.toString());
                recordStep(steps, "messages_search", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("messages.search.results".equals(status)) {
                    return result("task.finished", userGoal,
                            "Read messages through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "messages_search_failed" : status,
                        steps);
            } else if (isMessageDraftGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("contact_query", messageRecipientQuery(userGoal))
                        .put("body", messageBody(userGoal))
                        .put("reason", "User asked to draft an SMS message");
                String toolResult = executor.callTool("messages_draft", arguments.toString());
                recordStep(steps, "messages_draft", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("messages.draft_ready".equals(status)) {
                    return result("task.finished", userGoal,
                            "Prepared an SMS draft through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "messages_draft_failed" : status,
                        steps);
            } else if (isMessageSendGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("to", messageRecipientQuery(userGoal))
                        .put("body", messageBody(userGoal))
                        .put("reason", "User explicitly asked to send an SMS message");
                String toolResult = executor.callTool("messages_send", arguments.toString());
                recordStep(steps, "messages_send", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("messages.sent".equals(status)) {
                    return result("task.finished", userGoal,
                            "Sent the SMS through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "messages_send_failed" : status,
                        steps);
            } else if (isBrowserSearchGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", browserSearchQuery(userGoal))
                        .put("engine", "duckduckgo")
                        .put("reason", "User asked to search the web");
                String toolResult = executor.callTool("browser_search", arguments.toString());
                recordStep(steps, "browser_search", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("action.executed".equals(status) || "ok".equals(status)
                        || "task.finished".equals(status)) {
                    return result("task.finished", userGoal,
                            "Opened the web search through the local development adapter.",
                            steps);
                }
                return result("task.finished", userGoal,
                        "Requested the browser search through the local development adapter.",
                        steps);
            } else if (isPhoneContextGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", phoneContextQuery(userGoal))
                        .put("number", callNumber(userGoal))
                        .put("limit", 5)
                        .put("reason", "User asked for phone call context");
                String toolResult = executor.callTool("phone_context", arguments.toString());
                recordStep(steps, "phone_context", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                JSONObject result = new JSONObject(toolResult == null ? "{}" : toolResult);
                if ("phone.context".equals(result.optString("status", ""))) {
                    return result("task.finished", userGoal,
                            result.optString("summary",
                                    "Gathered phone context through the local adapter."),
                            steps);
                }
                return error("task.failed",
                        result.optString("status", "phone_context_failed"), steps);
            } else if (isCallSearchGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", callSearchQuery(userGoal))
                        .put("limit", 8)
                        .put("reason", "User asked for phone call history");
                String toolResult = executor.callTool("calls_search", arguments.toString());
                recordStep(steps, "calls_search", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("calls.search.results".equals(status)) {
                    return result("task.finished", userGoal,
                            "Read call history through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "calls_search_failed" : status,
                        steps);
            } else if (isCallPlaceGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("number", callNumber(userGoal))
                        .put("contact_query", callContactQuery(userGoal))
                        .put("reason", "User explicitly asked to place a phone call");
                String toolResult = executor.callTool("calls_place", arguments.toString());
                recordStep(steps, "calls_place", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("calls.placed".equals(status)) {
                    return result("task.finished", userGoal,
                            "Placed the call through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "calls_place_failed" : status,
                        steps);
            } else if (isAppsSearchGoal(goal)) {
                JSONObject arguments = new JSONObject()
                        .put("query", appsSearchQuery(userGoal))
                        .put("limit", 12)
                        .put("include_system", true)
                        .put("reason", "User asked to search installed apps");
                String toolResult = executor.callTool("apps_search", arguments.toString());
                recordStep(steps, "apps_search", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("apps.search.results".equals(status)) {
                    return result("task.finished", userGoal,
                            "Searched installed apps through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "apps_search_failed" : status,
                        steps);
            } else if (isGenericWebWatchGoal(userGoal)) {
                String url = extractUrl(userGoal);
                String query = webWatchQuery(userGoal, url);
                JSONObject condition = new JSONObject()
                        .put("source", "web")
                        .put("url", url)
                        .put("evaluator", query.isEmpty() ? "hash_change" : "text_contains");
                if (!query.isEmpty()) {
                    condition.put("query", query)
                            .put("condition_text", query);
                }
                JSONObject schedule = new JSONObject()
                        .put("interval_ms", 15_000L)
                        .put("next_run_at", System.currentTimeMillis() + 15_000L);
                JSONObject arguments = new JSONObject()
                        .put("source", "web")
                        .put("title", query.isEmpty()
                                ? "Watch page: " + url
                                : "Watch page for " + query)
                        .put("condition", condition)
                        .put("schedule", schedule)
                        .put("delivery", new JSONObject().put("surface", "notification"))
                        .put("reason", "User asked to watch a web page condition");
                String toolResult = executor.callTool("watcher_create", arguments.toString());
                recordStep(steps, "watcher_create", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("watcher.created".equals(status)) {
                    return result("task.finished", userGoal,
                            "Created the web watcher through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "watcher_create_failed" : status,
                        steps);
            } else if (isBrowserFetchGoal(userGoal)) {
                JSONObject arguments = new JSONObject()
                        .put("url", extractUrl(userGoal))
                        .put("max_chars", 4000)
                        .put("reason", "User asked for web page context");
                String toolResult = executor.callTool("browser_fetch_page", arguments.toString());
                recordStep(steps, "browser_fetch_page", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                String status = new JSONObject(toolResult == null ? "{}" : toolResult)
                        .optString("status", "");
                if ("browser.page_fetched".equals(status)) {
                    return result("task.finished", userGoal,
                            "Fetched the page through the local development adapter.",
                            steps);
                }
                return error("task.failed",
                        status.isEmpty() ? "browser_fetch_failed" : status,
                        steps);
            } else if (goal.contains("setting")) {
                JSONObject arguments = new JSONObject().put("package_or_label", "Settings")
                        .put("reason", "User asked for Settings");
                String toolResult = executor.callTool("open_app", arguments.toString());
                recordStep(steps, "open_app", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                return result("task.finished", userGoal,
                        "Opened Settings through the local development adapter.", steps);
            } else if (goal.contains("home")) {
                JSONObject arguments = new JSONObject().put("key", "home")
                        .put("reason", "User asked to go home");
                String toolResult = executor.callTool("press_key", arguments.toString());
                recordStep(steps, "press_key", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                return result("task.finished", userGoal,
                        "Went home through the local development adapter.", steps);
            } else if (goal.contains("back")) {
                JSONObject arguments = new JSONObject().put("key", "back")
                        .put("reason", "User asked to go back");
                String toolResult = executor.callTool("press_key", arguments.toString());
                recordStep(steps, "press_key", arguments.toString(), toolResult);
                String terminal = terminalToolResult(toolResult, userGoal, steps);
                if (terminal != null) {
                    return terminal;
                }
                return result("task.finished", userGoal,
                        "Went back through the local development adapter.", steps);
            }
            return error("task.failed",
                    "The local development adapter cannot complete this phone task. "
                            + "Enable OpenAI, OpenAI-compatible, Ollama, Qwen Omni, or broker mode "
                            + "for full phone-agent tasks.",
                    steps);
        } catch (JSONException e) {
            return error("json_error", e.getMessage(), steps);
        }
    }

    private static String terminalToolResult(String toolResult, String userGoal,
            JSONArray steps) {
        try {
            JSONObject result = new JSONObject(toolResult == null ? "{}" : toolResult);
            String status = result.optString("status", "");
            if ("dry_run.preview".equals(status)) {
                return new JSONObject()
                        .put("status", "dry_run.preview")
                        .put("provider", "local_heuristic")
                        .put("goal", userGoal == null ? "" : userGoal)
                        .put("answer", "Dry run previewed the next action without executing it.")
                        .put("preview", result)
                        .put("steps", steps)
                        .toString(2);
            }
            if ("confirmation_required".equals(status)
                    || "action_denied".equals(status)
                    || "agent.blocked".equals(status)
                    || "cancelled".equals(status)
                    || "error".equals(status)) {
                return new JSONObject()
                        .put("status", status.isEmpty() ? "tool.stopped" : status)
                        .put("provider", "local_heuristic")
                        .put("goal", userGoal == null ? "" : userGoal)
                        .put("reason", result.optString("reason", status))
                        .put("tool_result", result)
                        .put("steps", steps)
                        .toString(2);
            }
        } catch (JSONException ignored) {
        }
        return null;
    }

    private static String calendarSearchQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "show calendar",
                "show my calendar",
                "list calendar",
                "list my calendar",
                "search calendar",
                "search my calendar",
                "what is on my calendar",
                "what's on my calendar"
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String suffix = original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
                return stripCalendarFiller(suffix);
            }
        }
        return "";
    }

    private static String calendarEventTitle(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "create calendar event",
                "create a calendar event",
                "add calendar event",
                "add a calendar event",
                "schedule calendar event",
                "schedule a calendar event"
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String suffix = original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
                suffix = stripCalendarFiller(suffix);
                return suffix.isEmpty() ? "OpenPhone event" : suffix;
            }
        }
        return "OpenPhone event";
    }

    private static String stripCalendarFiller(String text) {
        String clean = text == null ? "" : text.trim();
        String normalized = normalize(clean);
        String[] prefixes = new String[] {"called ", "named ", "for ", "about "};
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return clean.length() >= prefix.length()
                        ? clean.substring(prefix.length()).trim() : "";
            }
        }
        return clean;
    }

    private static boolean isMessageCalendarEventGoal(String goal) {
        return containsAny(goal, "message", "messages", "sms", "text")
                && containsAny(goal, "calendar event", "calendar", "schedule event",
                        "schedule an event", "create event", "create an event",
                        "add event", "add an event")
                && containsAny(goal, "from message", "from the message",
                        "from a message", "from sms", "from the sms", "from text",
                        "from the text", "message about", "sms about", "text about",
                        "message matching", "sms matching", "text matching");
    }

    private static String messageCalendarEventQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] markers = new String[] {
                "from message about",
                "from the message about",
                "from a message about",
                "from sms about",
                "from the sms about",
                "from text about",
                "from the text about",
                "message about",
                "sms about",
                "text about",
                "message matching",
                "sms matching",
                "text matching",
                "from message",
                "from the message",
                "from a message",
                "from sms",
                "from the sms",
                "from text",
                "from the text"
        };
        for (String marker : markers) {
            int index = normalized.indexOf(marker);
            if (index >= 0) {
                int start = index + marker.length();
                return original.length() > start
                        ? stripCalendarFiller(original.substring(start).trim()) : "";
            }
        }
        return "";
    }

    private static String contactSearchQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "show contacts",
                "show my contacts",
                "list contacts",
                "list my contacts",
                "search contacts",
                "search my contacts",
                "find contact",
                "find contacts",
                "lookup contact",
                "look up contact",
                "who is in my contacts for "
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String suffix = original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
                return stripContactFiller(suffix);
            }
        }
        return "";
    }

    private static String stripContactFiller(String text) {
        String clean = text == null ? "" : text.trim();
        String normalized = normalize(clean);
        String[] prefixes = new String[] {"named ", "called ", "for ", "matching ", "about "};
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return clean.length() >= prefix.length()
                        ? clean.substring(prefix.length()).trim() : "";
            }
        }
        return clean;
    }

    private static boolean isMessageSearchGoal(String goal) {
        return containsAny(goal, "message", "messages", "sms", "texts", "text history")
                && containsAny(goal, "show", "list", "search", "find", "what");
    }

    private static boolean isMessageSummaryGoal(String goal) {
        return containsAny(goal, "message", "messages", "sms", "texts", "text history")
                && containsAny(goal, "summarize", "summarise", "summary",
                        "what did they say", "what did i miss", "catch me up");
    }

    private static boolean isMessageCommitmentGoal(String goal) {
        return containsAny(goal, "message", "messages", "sms", "text")
                && containsAny(goal, "remind me", "remember to", "follow up",
                        "create reminder", "create a reminder", "create commitment",
                        "make commitment", "add reminder", "add to commitments");
    }

    private static String messageCommitmentQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] markers = new String[] {
                "about message",
                "about the message",
                "for message",
                "for the message",
                "from message",
                "from the message",
                "about sms",
                "from sms",
                "about text",
                "from text",
                "matching message",
                "message about",
                "message matching",
                "sms about",
                "text about"
        };
        for (String marker : markers) {
            int index = normalized.indexOf(marker);
            if (index >= 0) {
                int start = index + marker.length();
                return original.length() > start
                        ? stripMessageFiller(original.substring(start).trim()) : "";
            }
        }
        return "";
    }

    private static boolean isNotificationSummaryGoal(String goal) {
        return containsAny(goal, "what did i miss", "what have i missed",
                "missed notifications", "notification summary", "summarize notifications",
                "summarise notifications", "summarize my notifications",
                "summarise my notifications")
                || (containsAny(goal, "notifications", "notification")
                        && containsAny(goal, "summary", "summarize", "summarise", "missed"));
    }

    private static boolean isNotificationCommitmentGoal(String goal) {
        return containsAny(goal, "notification")
                && containsAny(goal, "remind me", "remember to", "follow up",
                        "create reminder", "create a reminder", "create commitment",
                        "make commitment", "add reminder", "add to commitments");
    }

    private static String notificationCommitmentQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] markers = new String[] {
                "about notification",
                "about the notification",
                "for notification",
                "for the notification",
                "from notification",
                "from the notification",
                "matching notification",
                "notification about",
                "notification matching"
        };
        for (String marker : markers) {
            int index = normalized.indexOf(marker);
            if (index >= 0) {
                int start = index + marker.length();
                return original.length() > start ? stripNotificationFiller(
                        original.substring(start).trim()) : "";
            }
        }
        return "";
    }

    private static boolean isMessageDraftGoal(String goal) {
        return containsAny(goal, "draft message", "draft a message", "draft text",
                "draft a text", "compose message", "compose a message",
                "compose text", "compose a text");
    }

    private static boolean isMessageSendGoal(String goal) {
        return startsWithAny(goal, "send message", "send a message", "send sms",
                "send an sms", "send text", "send a text", "text ");
    }

    private static String messageSearchQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "show messages",
                "show my messages",
                "list messages",
                "list my messages",
                "search messages",
                "search my messages",
                "find messages",
                "find message",
                "summarize messages",
                "summarize my messages",
                "summarise messages",
                "summarise my messages",
                "message summary",
                "messages summary",
                "show sms",
                "search sms",
                "find sms",
                "summarize sms",
                "summarise sms"
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String suffix = original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
                return stripMessageFiller(suffix);
            }
        }
        return "";
    }

    private static String messageRecipientQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        int toIndex = normalized.indexOf(" to ");
        if (toIndex < 0) {
            return "";
        }
        String afterTo = original.substring(Math.min(original.length(), toIndex + 4)).trim();
        String afterToNormalized = normalize(afterTo);
        int saying = afterToNormalized.indexOf(" saying ");
        int bodyMarker = saying >= 0 ? saying : afterToNormalized.indexOf(" that ");
        if (bodyMarker >= 0) {
            return afterTo.substring(0, Math.min(afterTo.length(), bodyMarker)).trim();
        }
        return afterTo;
    }

    private static String messageBody(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] markers = new String[] {" saying ", " that ", ": "};
        for (String marker : markers) {
            int index = normalized.indexOf(marker);
            if (index >= 0) {
                String body = original.substring(Math.min(original.length(),
                        index + marker.length())).trim();
                return stripQuotes(body.isEmpty() ? "Hello" : body);
            }
        }
        return "Hello";
    }

    private static String stripMessageFiller(String text) {
        String clean = text == null ? "" : text.trim();
        String normalized = normalize(clean);
        String[] prefixes = new String[] {"from ", "with ", "about ", "matching ", "for "};
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return clean.length() >= prefix.length()
                        ? clean.substring(prefix.length()).trim() : "";
            }
        }
        return clean;
    }

    private static String stripQuotes(String text) {
        String clean = text == null ? "" : text.trim();
        while (clean.length() >= 2
                && ((clean.startsWith("\"") && clean.endsWith("\""))
                        || (clean.startsWith("'") && clean.endsWith("'")))) {
            clean = clean.substring(1, clean.length() - 1).trim();
        }
        return clean;
    }

    private static String stripTrailingPunctuation(String text) {
        String clean = text == null ? "" : text.trim();
        while (!clean.isEmpty() && ".,;:!?".indexOf(clean.charAt(clean.length() - 1)) >= 0) {
            clean = clean.substring(0, clean.length() - 1).trim();
        }
        return clean;
    }

    private static boolean isCallSearchGoal(String goal) {
        return containsAny(goal, "call", "calls", "phone")
                && containsAny(goal, "show", "list", "search", "find", "recent",
                        "missed", "history", "what");
    }

    private static boolean isPhoneContextGoal(String goal) {
        return containsAny(goal, "phone context", "call context", "context for call",
                "context before call", "confirmation code", "confirmation number",
                "booking code", "reservation code")
                || (containsAny(goal, "call", "phone")
                        && containsAny(goal, "context", "confirmation", "booking",
                                "reservation", "code"));
    }

    private static String phoneContextQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "show phone context",
                "show call context",
                "phone context",
                "call context",
                "context for call",
                "context before call",
                "find confirmation code",
                "find confirmation number",
                "show confirmation code",
                "show confirmation number"
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String suffix = original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
                return stripCallFiller(suffix);
            }
        }
        return callSearchQuery(userGoal);
    }

    private static boolean isCallPlaceGoal(String goal) {
        return startsWithAny(goal, "call ", "phone ", "dial ", "place a call ",
                "place call ", "make a call ");
    }

    private static String callSearchQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "show recent calls",
                "show calls",
                "show my calls",
                "list calls",
                "list my calls",
                "search calls",
                "search my calls",
                "find calls",
                "show call history",
                "show my call history",
                "show missed calls",
                "list missed calls"
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String suffix = original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
                return stripCallFiller(suffix);
            }
        }
        return "";
    }

    private static String callNumber(String userGoal) {
        String target = callTarget(userGoal);
        String digits = target.replaceAll("[^0-9+*#]", "");
        return digits.matches(".*[0-9].*") ? digits : "";
    }

    private static String callContactQuery(String userGoal) {
        String target = callTarget(userGoal);
        return callNumber(userGoal).isEmpty() ? target : "";
    }

    private static String callTarget(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "call ",
                "phone ",
                "dial ",
                "place a call to ",
                "place call to ",
                "make a call to "
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
            }
        }
        return "";
    }

    private static String stripCallFiller(String text) {
        String clean = text == null ? "" : text.trim();
        String normalized = normalize(clean);
        String[] prefixes = new String[] {"from ", "with ", "about ", "matching ", "for "};
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return clean.length() >= prefix.length()
                        ? clean.substring(prefix.length()).trim() : "";
            }
        }
        return clean;
    }

    private static boolean isBrowserFetchGoal(String userGoal) {
        String normalized = normalize(userGoal);
        return extractUrl(userGoal).length() > 0
                && containsAny(normalized, "summarize", "summarise", "fetch", "read",
                        "what is", "what's", "explain", "open page", "web page",
                        "this url", "this link");
    }

    private static boolean isBrowserSearchGoal(String goal) {
        return startsWithAny(goal, "search web ", "search the web ",
                "search the internet ", "web search ", "browser search ")
                || containsAny(goal, " search the web for ", " web search for ");
    }

    private static String browserSearchQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "search the web for ",
                "search web for ",
                "search the internet for ",
                "web search for ",
                "browser search for ",
                "search web ",
                "search the web ",
                "search the internet ",
                "web search ",
                "browser search "
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return stripTrailingPunctuation(original.substring(Math.min(original.length(),
                        prefix.length())).trim());
            }
        }
        int marker = normalized.indexOf(" search the web for ");
        if (marker >= 0) {
            return stripTrailingPunctuation(original.substring(Math.min(original.length(),
                    marker + " search the web for ".length())).trim());
        }
        marker = normalized.indexOf(" web search for ");
        if (marker >= 0) {
            return stripTrailingPunctuation(original.substring(Math.min(original.length(),
                    marker + " web search for ".length())).trim());
        }
        return original;
    }

    private static boolean isAppsSearchGoal(String goal) {
        return containsAny(goal, "app", "apps", "installed applications",
                "installed packages")
                && containsAny(goal, "show", "list", "search", "find", "what");
    }

    private static String appsSearchQuery(String userGoal) {
        String original = userGoal == null ? "" : userGoal.trim();
        String normalized = normalize(original);
        String[] prefixes = new String[] {
                "show apps",
                "show my apps",
                "show installed apps",
                "list apps",
                "list my apps",
                "list installed apps",
                "search apps",
                "search installed apps",
                "find app",
                "find apps"
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String suffix = original.length() >= prefix.length()
                        ? original.substring(prefix.length()).trim() : "";
                return stripAppsFiller(suffix);
            }
        }
        return "";
    }

    private static String stripAppsFiller(String text) {
        String clean = text == null ? "" : text.trim();
        String normalized = normalize(clean);
        String[] prefixes = new String[] {"for ", "named ", "called ", "matching ", "about "};
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return clean.length() >= prefix.length()
                        ? clean.substring(prefix.length()).trim() : "";
            }
        }
        return clean;
    }

    private static boolean isGenericWebWatchGoal(String userGoal) {
        String normalized = normalize(userGoal);
        return extractUrl(userGoal).length() > 0
                && startsWithAny(normalized, "watch ", "watch page ", "watch website ",
                        "watch url ", "notify me when ", "tell me when ",
                        "create watcher ", "create web watcher ",
                        "set up monitoring ", "setup monitoring ", "monitor ");
    }

    private static String webWatchQuery(String userGoal, String url) {
        String original = userGoal == null ? "" : userGoal.trim();
        String afterUrl = "";
        String urlValue = url == null ? "" : url;
        int urlIndex = urlValue.isEmpty() ? -1 : original.indexOf(urlValue);
        if (urlIndex >= 0) {
            afterUrl = original.substring(Math.min(original.length(),
                    urlIndex + urlValue.length())).trim();
        }
        String afterUrlNormalized = normalize(afterUrl);
        String[] afterUrlPrefixes = new String[] {"for ", "contains ", "mentions ", "says ",
                "includes ", "has "};
        for (String prefix : afterUrlPrefixes) {
            if (afterUrlNormalized.startsWith(prefix)) {
                String value = afterUrl.length() >= prefix.length()
                        ? afterUrl.substring(prefix.length()).trim() : "";
                return stripQuotes(stripTrailingPunctuation(value));
            }
        }
        String withoutUrl = original.replace(urlValue, " ").trim();
        String normalized = normalize(withoutUrl);
        String[] prefixes = new String[] {"watch page ", "watch website ", "watch url ",
                "watch ", "notify me when ", "tell me when ", "create watcher ",
                "create web watcher ", "set up monitoring ", "setup monitoring ",
                "monitor "};
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                String value = withoutUrl.length() >= prefix.length()
                        ? withoutUrl.substring(prefix.length()).trim() : "";
                value = stripTrailingPunctuation(value);
                if (!value.isEmpty()
                        && !containsAny(normalize(value), "change", "changes", "updated",
                                "update")) {
                    return stripQuotes(value);
                }
            }
        }
        return "";
    }

    private static String extractUrl(String text) {
        if (text == null || text.trim().isEmpty()) {
            return "";
        }
        String[] parts = text.trim().split("\\s+");
        for (String part : parts) {
            String candidate = stripUrlPunctuation(part);
            String lower = candidate.toLowerCase(Locale.US);
            if (lower.startsWith("http://") || lower.startsWith("https://")) {
                return candidate;
            }
            if (lower.startsWith("www.") && lower.indexOf('.') > 0) {
                return "https://" + candidate;
            }
        }
        return "";
    }

    private static String stripUrlPunctuation(String value) {
        String clean = value == null ? "" : value.trim();
        while (!clean.isEmpty()
                && ".,;:)]}\"'".indexOf(clean.charAt(clean.length() - 1)) >= 0) {
            clean = clean.substring(0, clean.length() - 1);
        }
        while (!clean.isEmpty() && "([{\"'".indexOf(clean.charAt(0)) >= 0) {
            clean = clean.substring(1);
        }
        return clean;
    }

    private static String stripNotificationFiller(String text) {
        String clean = text == null ? "" : text.trim();
        String normalized = normalize(clean);
        String[] prefixes = new String[] {"about ", "matching ", "for ", "from ", "that "};
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return clean.length() >= prefix.length()
                        ? clean.substring(prefix.length()).trim() : "";
            }
        }
        return clean;
    }

    private static String extractNotificationOpenQuery(String text) {
        String normalized = normalize(text);
        String[] prefixes = new String[] {
                "open notification about ",
                "open notification matching ",
                "open notification for ",
                "open the notification about ",
                "open the notification matching ",
                "open the notification for ",
                "please open notification about ",
                "please open notification matching ",
                "please open notification for ",
                "please open the notification about ",
                "please open the notification matching ",
                "please open the notification for "
        };
        for (String prefix : prefixes) {
            if (normalized.startsWith(prefix)) {
                return normalized.substring(prefix.length()).trim();
            }
        }
        return "";
    }

    private static String cancelled() {
        return "{\"status\":\"cancelled\",\"reason\":\"user_stopped\"}";
    }

    private static void recordStep(JSONArray steps, String tool, String arguments,
            String toolResult) {
        try {
            steps.put(new JSONObject()
                    .put("tool", tool)
                    .put("arguments", arguments == null ? "" : arguments)
                    .put("tool_result", toolResult == null ? "" : toolResult));
        } catch (JSONException ignored) {
        }
    }

    private static String result(String status, String userGoal, String answer, JSONArray steps) {
        try {
            return new JSONObject()
                    .put("status", status)
                    .put("provider", "local_heuristic")
                    .put("goal", userGoal == null ? "" : userGoal)
                    .put("answer", answer)
                    .put("steps", steps)
                    .toString(2);
        } catch (JSONException e) {
            return "{\"status\":\"task.finished\"}";
        }
    }

    private static String error(String status, String reason, JSONArray steps) {
        try {
            return new JSONObject()
                    .put("status", status)
                    .put("provider", "local_heuristic")
                    .put("reason", reason == null ? "" : reason)
                    .put("steps", steps)
                    .toString(2);
        } catch (JSONException e) {
            return "{\"status\":\"error\"}";
        }
    }
}
