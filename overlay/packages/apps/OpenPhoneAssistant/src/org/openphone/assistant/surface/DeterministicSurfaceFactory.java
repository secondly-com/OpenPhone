package org.openphone.assistant.surface;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.actions.ToolCatalog;

import java.util.UUID;

/**
 * Deterministic phone renderer input for trusted calendar/message/notification
 * tool results. This does not ask a model to generate layout.
 */
public final class DeterministicSurfaceFactory {
    private static final long DEFAULT_TTL_MILLIS = 30L * 60L * 1000L;

    private final SurfaceArtifactStore mArtifacts;

    public DeterministicSurfaceFactory(Context context) {
        mArtifacts = new SurfaceArtifactStore(context);
    }

    public AdaptiveSurface fromAgentResult(String agentResultJson, String sessionId,
            String runtime) {
        JSONObject result = object(agentResultJson);
        JSONArray steps = result.optJSONArray("steps");
        if (steps == null) {
            return null;
        }
        for (int i = steps.length() - 1; i >= 0; i--) {
            JSONObject step = steps.optJSONObject(i);
            if (step == null) {
                continue;
            }
            String tool = step.optString("tool", "");
            if (!isSupported(tool)) {
                continue;
            }
            JSONObject toolResult = objectValue(step.opt("tool_result"));
            AdaptiveSurface surface = fromToolResult(tool, toolResult, sessionId, runtime);
            if (surface != null) {
                return surface;
            }
        }
        return null;
    }

    public AdaptiveSurface fromToolResult(String tool, JSONObject toolResult,
            String sessionId, String runtime) {
        String cleanSession = clean(sessionId);
        String cleanRuntime = clean(runtime);
        if (cleanSession.isEmpty() || cleanRuntime.isEmpty() || toolResult == null) {
            return null;
        }
        long now = System.currentTimeMillis();
        long expiresAt = now + DEFAULT_TTL_MILLIS;
        String capability = ToolCatalog.get().capabilityForTool(tool);
        String sensitivity = tool.startsWith("calendar_") ? "personal" : "sensitive";
        String artifactId = mArtifacts.put(
                cleanSession, cleanRuntime, tool, capability, sensitivity,
                toolResult, expiresAt);
        JSONObject surface;
        if ("calendar_search".equals(tool)
                && "calendar.search.results".equals(toolResult.optString("status", ""))) {
            surface = calendarSurface(toolResult, cleanSession, cleanRuntime, now, expiresAt);
        } else if (("messages_search".equals(tool)
                && "messages.search.results".equals(toolResult.optString("status", "")))
                || ("messages_summary".equals(tool)
                && "messages.summary".equals(toolResult.optString("status", "")))) {
            surface = messageSurface(tool, toolResult, cleanSession, cleanRuntime, now, expiresAt);
        } else if (("notifications_summary".equals(tool)
                && "notifications.summary".equals(toolResult.optString("status", "")))
                || ("notifications_list".equals(tool)
                && toolResult.optString("status", "").startsWith("notifications."))) {
            surface = notificationSurface(
                    toolResult, cleanSession, cleanRuntime, now, expiresAt);
        } else {
            return null;
        }
        if (!artifactId.isEmpty()) {
            try {
                surface.put("artifacts", new JSONArray().put(new JSONObject()
                        .put("artifact_id", artifactId)
                        .put("path", "$")));
            } catch (JSONException ignored) {
            }
        }
        return AdaptiveSurface.fromJson(surface);
    }

    private static JSONObject calendarSurface(JSONObject result, String sessionId,
            String runtime, long createdAt, long expiresAt) {
        JSONArray events = result.optJSONArray("events");
        JSONArray items = new JSONArray();
        JSONObject actions = new JSONObject();
        int count = events == null ? 0 : Math.min(events.length(), 12);
        for (int i = 0; i < count; i++) {
            JSONObject event = events.optJSONObject(i);
            if (event == null) {
                continue;
            }
            String title = first(event.optString("title", ""), "Untitled event");
            String subtitle = join(
                    event.optString("start_local", ""),
                    event.optString("location", ""));
            String actionId = "calendar_event_" + i;
            try {
                items.put(new JSONObject()
                        .put("type", "list_item")
                        .put("title", title)
                        .put("subtitle", subtitle)
                        .put("icon", "calendar")
                        .put("action_id", actionId));
                actions.put(actionId, new JSONObject()
                        .put("label", "Find event")
                        .put("tool", "calendar_search")
                        .put("params", new JSONObject()
                                .put("query", title)
                                .put("limit", 8))
                        .put("reason", "User selected an event from the phone agenda"));
            } catch (JSONException ignored) {
            }
        }
        JSONObject body = column(new JSONArray()
                .put(text("headline", count == 0 ? "No matching events" : "Your agenda"))
                .put(new JSONObjectBuilder("list").array("items", items).build()));
        return root("Agenda", "personal", sessionId, runtime, createdAt, expiresAt, body, actions);
    }

    private static JSONObject messageSurface(String tool, JSONObject result, String sessionId,
            String runtime, long createdAt, long expiresAt) {
        JSONArray source = "messages_summary".equals(tool)
                ? result.optJSONArray("threads") : result.optJSONArray("messages");
        JSONArray children = new JSONArray()
                .put(disclosure("messages.read", "From messages stored on this phone"));
        int count = source == null ? 0 : Math.min(source.length(), 10);
        JSONObject actions = new JSONObject();
        for (int i = 0; i < count; i++) {
            JSONObject item = source.optJSONObject(i);
            if (item == null) {
                continue;
            }
            String address = first(item.optString("address", ""), "Unknown sender");
            String body;
            if ("messages_summary".equals(tool)) {
                JSONArray samples = item.optJSONArray("samples");
                JSONObject sample = samples == null ? null : samples.optJSONObject(0);
                body = sample == null ? "" : sample.optString("body", "");
            } else {
                body = item.optString("body", "");
            }
            String actionId = "message_thread_" + i;
            try {
                children.put(new JSONObjectBuilder("card")
                        .array("children", new JSONArray()
                                .put(text("title", address))
                                .put(text("body", body))
                                .put(new JSONObjectBuilder("button")
                                        .string("label", "Find thread")
                                        .string("action_id", actionId)
                                        .string("content_description",
                                                "Find message thread with " + address)
                                        .build()))
                        .build());
                actions.put(actionId, new JSONObject()
                        .put("label", "Find thread")
                        .put("tool", "messages_search")
                        .put("params", new JSONObject()
                                .put("query", address)
                                .put("limit", 8))
                        .put("reason", "User selected a message summary item"));
            } catch (JSONException ignored) {
            }
        }
        if (count == 0) {
            children.put(text("body", first(result.optString("summary", ""),
                    "No matching messages.")));
        }
        return root("Messages", "sensitive", sessionId, runtime, createdAt, expiresAt,
                column(children), actions);
    }

    private static JSONObject notificationSurface(JSONObject result, String sessionId,
            String runtime, long createdAt, long expiresAt) {
        JSONArray groups = result.optJSONArray("groups");
        JSONArray children = new JSONArray()
                .put(disclosure("notifications.read", "From recent phone notifications"));
        JSONObject actions = new JSONObject();
        int count = groups == null ? 0 : Math.min(groups.length(), 10);
        for (int i = 0; i < count; i++) {
            JSONObject group = groups.optJSONObject(i);
            if (group == null) {
                continue;
            }
            String app = first(group.optString("app", ""), "Notification");
            String title = first(group.optString("title", ""), app);
            String sample = group.optString("sample_text", "");
            String actionId = "notification_" + i;
            try {
                children.put(new JSONObjectBuilder("list_item")
                        .string("title", title)
                        .string("subtitle", sample)
                        .string("icon", "notification")
                        .string("action_id", actionId)
                        .build());
                actions.put(actionId, new JSONObject()
                        .put("label", "Open notification")
                        .put("tool", "notifications_open")
                        .put("params", new JSONObject().put("query", title))
                        .put("reason", "User selected a notification summary item")
                        .put("requires_confirmation", true));
            } catch (JSONException ignored) {
            }
        }
        if (count == 0) {
            children.put(text("body", first(result.optString("summary", ""),
                    "No recent notifications.")));
        }
        return root("Notifications", "sensitive", sessionId, runtime, createdAt, expiresAt,
                column(children), actions);
    }

    private static JSONObject root(String title, String sensitivity, String sessionId,
            String runtime, long createdAt, long expiresAt, JSONObject body,
            JSONObject actions) {
        JSONObject root = new JSONObject();
        try {
            root.put("schema", AdaptiveSurface.SCHEMA)
                    .put("surface_id", "surface-" + UUID.randomUUID())
                    .put("revision", 1)
                    .put("session_id", sessionId)
                    .put("runtime", runtime)
                    .put("title", title)
                    .put("presentation", "full")
                    .put("expires_at", expiresAt)
                    .put("sensitivity", sensitivity)
                    .put("created_at", createdAt)
                    .put("body", body)
                    .put("actions", actions);
        } catch (JSONException ignored) {
        }
        return root;
    }

    private static JSONObject column(JSONArray children) {
        return new JSONObjectBuilder("column")
                .string("spacing", "md")
                .array("children", children)
                .build();
    }

    private static JSONObject text(String style, String value) {
        return new JSONObjectBuilder("text")
                .string("style", style)
                .string("text", truncate(value, 1000))
                .build();
    }

    private static JSONObject disclosure(String capability, String value) {
        return new JSONObjectBuilder("capability_disclosure")
                .string("capability", capability)
                .string("text", value)
                .build();
    }

    private static String join(String first, String second) {
        String left = clean(first);
        String right = clean(second);
        if (left.isEmpty()) return right;
        if (right.isEmpty()) return left;
        return left + " · " + right;
    }

    private static String first(String value, String fallback) {
        String clean = clean(value);
        return clean.isEmpty() ? fallback : clean;
    }

    private static String truncate(String value, int max) {
        String clean = clean(value);
        return clean.length() <= max ? clean : clean.substring(0, max - 1) + "…";
    }

    private static boolean isSupported(String tool) {
        return "calendar_search".equals(tool)
                || "messages_search".equals(tool)
                || "messages_summary".equals(tool)
                || "notifications_list".equals(tool)
                || "notifications_summary".equals(tool);
    }

    private static JSONObject object(String raw) {
        try {
            return new JSONObject(raw == null || raw.trim().isEmpty() ? "{}" : raw);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static JSONObject objectValue(Object value) {
        if (value instanceof JSONObject) {
            return SurfaceComponent.copy((JSONObject) value);
        }
        return object(value instanceof String ? (String) value : "");
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    private static final class JSONObjectBuilder {
        private final JSONObject mObject = new JSONObject();

        JSONObjectBuilder(String type) {
            string("type", type);
        }

        JSONObjectBuilder string(String key, String value) {
            try {
                mObject.put(key, truncate(value, 1000));
            } catch (JSONException ignored) {
            }
            return this;
        }

        JSONObjectBuilder array(String key, JSONArray value) {
            try {
                mObject.put(key, value == null ? new JSONArray() : value);
            } catch (JSONException ignored) {
            }
            return this;
        }

        JSONObject build() {
            return mObject;
        }
    }
}
