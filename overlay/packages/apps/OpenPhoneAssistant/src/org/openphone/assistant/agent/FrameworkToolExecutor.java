package org.openphone.assistant.agent;

import android.Manifest;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.database.Cursor;
import android.openphone.OpenPhoneAgentManager;
import android.net.Uri;
import android.provider.CalendarContract;
import android.provider.CallLog;
import android.provider.ContactsContract;
import android.provider.Settings;
import android.provider.Telephony;
import android.telephony.SmsManager;
import android.telecom.TelecomManager;

import org.json.JSONException;
import org.json.JSONArray;
import org.json.JSONObject;
import org.openphone.assistant.OpenPhoneAccessibilityService;
import org.openphone.assistant.OpenPhoneNotificationListenerService;
import org.openphone.assistant.actions.ActionRegistry;
import org.openphone.assistant.actions.ToolCatalog;
import org.openphone.assistant.commitments.CommitmentStore;
import org.openphone.assistant.context.ContextEvent;
import org.openphone.assistant.context.ContextIndexStore;
import org.openphone.assistant.jobs.AgentJobStore;
import org.openphone.assistant.jobs.OpenPhoneAgentJobScheduler;
import org.openphone.assistant.memory.MemoryStore;
import org.openphone.assistant.watchers.OpenPhoneWatcherScheduler;
import org.openphone.assistant.watchers.WatcherRecord;
import org.openphone.assistant.watchers.WatcherStore;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Locale;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class FrameworkToolExecutor {
    private static final String SECURE_AUTONOMY_MODE = "openphone_autonomy_mode";

    private final Context mContext;
    private final OpenPhoneAgentManager mAgentManager;
    private final CommitmentStore mCommitmentStore;
    private final ContextIndexStore mContextIndexStore;
    private final AgentJobStore mAgentJobStore;
    private final MemoryStore mMemoryStore;
    private final WatcherStore mWatcherStore;
    private final ActionRegistry mActionRegistry;
    private JSONObject mLastScreenJson;

    public FrameworkToolExecutor(Context context, OpenPhoneAgentManager agentManager) {
        mContext = context;
        mAgentManager = agentManager;
        mCommitmentStore = new CommitmentStore(context);
        mContextIndexStore = new ContextIndexStore(context);
        mAgentJobStore = new AgentJobStore(context);
        mMemoryStore = new MemoryStore(context);
        mWatcherStore = new WatcherStore(context);
        mActionRegistry = ActionRegistry.load();
    }

    public String execute(String taskId, String toolName, JSONObject arguments) {
        if (mAgentManager == null) {
            return error("framework_unavailable");
        }
        if (taskId == null || taskId.isEmpty()) {
            return error("no_active_task");
        }
        if (requiresModelReason(toolName) && arguments.optString("reason", "").trim().isEmpty()) {
            return error("missing_reason:" + toolName);
        }
        if (mActionRegistry.isLoaded() && !mActionRegistry.hasTool(toolName)) {
            return error("action_registry_missing_tool:" + toolName);
        }
        try {
            switch (toolName) {
                case "context_search":
                    return contextSearch(arguments);
                case "notifications_list":
                case "notifications_search":
                    return notificationsSearch(arguments);
                case "notifications_summary":
                    return notificationsSummary(arguments);
                case "notifications_open":
                    return notificationsOpen(arguments);
                case "calendar_search":
                    return calendarSearch(arguments);
                case "calendar_create_event":
                    return calendarCreateEvent(arguments);
                case "message_calendar_event_create":
                    return messageCalendarEventCreate(arguments);
                case "calendar_update_event":
                    return calendarUpdateEvent(arguments);
                case "calendar_delete_event":
                    return calendarDeleteEvent(arguments);
                case "calendar_check_availability":
                    return calendarCheckAvailability(arguments);
                case "contacts_search":
                    return contactsSearch(arguments);
                case "messages_search":
                    return messagesSearch(arguments);
                case "messages_summary":
                    return messagesSummary(arguments);
                case "messages_draft":
                    return messagesDraft(arguments);
                case "messages_send":
                    return messagesSend(arguments);
                case "calls_search":
                    return callsSearch(arguments);
                case "phone_context":
                    return phoneContext(arguments);
                case "calls_place":
                    return callsPlace(arguments);
                case "apps_search":
                    return appsSearch(arguments);
                case "memory_search":
                    return memorySearch(arguments);
                case "memory_save":
                    return memorySave(arguments);
                case "commitment_search":
                    return commitmentSearch(arguments);
                case "commitment_create":
                    return commitmentCreate(arguments);
                case "notification_commitment_create":
                    return notificationCommitmentCreate(arguments);
                case "message_commitment_create":
                    return messageCommitmentCreate(arguments);
                case "commitment_update_status":
                    return commitmentUpdateStatus(arguments);
                case "watcher_create":
                    return watcherCreate(arguments);
                case "watcher_list":
                    return watcherList(arguments);
                case "watcher_stop":
                    return watcherStop(arguments);
                case "background_job_create":
                    return backgroundJobCreate(arguments);
                case "background_job_list":
                    return backgroundJobList(arguments);
                case "background_job_stop":
                    return backgroundJobStop(arguments);
                case "get_screen":
                    return getScreen(taskId, arguments);
                case "local_screen_understanding":
                    return localScreenUnderstanding(taskId, arguments);
                case "watch_screen":
                    return watchScreen(taskId, arguments);
                case "open_app":
                    String requestedPackage = resolvePackageOrLabel(arguments.optString("package",
                            arguments.optString("package_or_label")));
                    return mAgentManager.executeAction(taskId, action("open_app")
                            .put("package", requestedPackage)
                            .put("label", arguments.optString("label",
                                    arguments.optString("package_or_label")))
                            .put("reason", arguments.optString("reason")).toString());
                case "open_url":
                    return mAgentManager.executeAction(taskId, action("open_url")
                            .put("url", normalizedUrl(arguments.optString("url")))
                            .put("reason", arguments.optString("reason")).toString());
                case "browser_search":
                    return browserSearch(taskId, arguments);
                case "browser_fetch_page":
                    return browserFetchPage(arguments);
                case "tap":
                    return mAgentManager.executeAction(taskId, action("tap")
                            .put("target", point(arguments.optDouble("x"), arguments.optDouble("y")))
                            .put("reason", arguments.optString("reason")).toString());
                case "tap_element":
                    return mAgentManager.executeAction(taskId, action("tap")
                            .put("target", elementCenter(arguments))
                            .put("reason", arguments.optString("reason")).toString());
                case "long_press":
                    return mAgentManager.executeAction(taskId, action("long_press")
                            .put("target", point(arguments.optDouble("x"), arguments.optDouble("y")))
                            .put("duration_ms", arguments.optLong("duration_ms", 650))
                            .put("reason", arguments.optString("reason")).toString());
                case "long_press_element":
                    return mAgentManager.executeAction(taskId, action("long_press")
                            .put("target", elementCenter(arguments))
                            .put("duration_ms", arguments.optLong("duration_ms", 650))
                            .put("reason", arguments.optString("reason")).toString());
                case "swipe":
                    return mAgentManager.executeAction(taskId, action("scroll")
                            .put("target", new JSONObject()
                                    .put("start_x", arguments.optDouble("start_x"))
                                    .put("start_y", arguments.optDouble("start_y"))
                                    .put("end_x", arguments.optDouble("end_x"))
                                    .put("end_y", arguments.optDouble("end_y")))
                            .put("reason", arguments.optString("reason")).toString());
                case "type_text":
                    return mAgentManager.executeAction(taskId, action("type_text")
                            .put("text", arguments.optString("text"))
                            .put("reason", arguments.optString("reason")).toString());
                case "press_key":
                    return pressKey(taskId, arguments);
                case "set_clipboard":
                    return mAgentManager.executeAction(taskId, action("copy")
                            .put("text", arguments.optString("text"))
                            .put("reason", arguments.optString("reason")).toString());
                case "paste":
                    return mAgentManager.executeAction(taskId, action("paste")
                            .put("reason", arguments.optString("reason")).toString());
                case "share_text":
                    return mAgentManager.executeAction(taskId, action("share")
                            .put("text", arguments.optString("text"))
                            .put("chooser_title", arguments.optString("chooser_title"))
                            .put("reason", arguments.optString("reason")).toString());
                case "wait":
                    return waitFor(arguments.optLong("duration_ms", 1000),
                            arguments.optString("reason"));
                case "ask_user_confirmation":
                    return new JSONObject()
                            .put("status", "confirmation_requested")
                            .put("summary", arguments.optString("summary"))
                            .put("risk", arguments.optString("risk"))
                            .put("reason", arguments.optString("reason"))
                            .put("action", arguments.optJSONObject("action_json") == null
                                    ? new JSONObject() : arguments.optJSONObject("action_json"))
                            .toString();
                case "finish_task":
                    return status("task.finished", arguments.optString("summary"));
                case "fail_task":
                    return status("task.failed", arguments.optString("reason"));
                default:
                    return error("unknown_tool:" + toolName);
            }
        } catch (JSONException e) {
            return error("json_error:" + e.getMessage());
        }
    }

    private static boolean requiresModelReason(String toolName) {
        return ToolCatalog.get().requiresReason(toolName);
    }

    private String contextSearch(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        JSONObject result = new JSONObject(mContextIndexStore.searchJson(query, limit));
        result.put("status", "context.search.results")
                .put("query", query)
                .put("limit", limit);
        return result.toString();
    }

    private String notificationsSearch(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        JSONObject result = new JSONObject(mContextIndexStore.notificationsJson(query, limit));
        result.put("status", "notification.search.results")
                .put("query", query)
                .put("limit", limit);
        return result.toString();
    }

    private String notificationsSummary(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 20), 50));
        long since = arguments.optLong("since", 0L);
        List<ContextEvent> events = mContextIndexStore.notifications(query, limit);
        Map<String, NotificationGroup> groupsByKey = new LinkedHashMap<>();
        for (ContextEvent event : events) {
            if (since > 0L && event.observedAtMillis < since) {
                continue;
            }
            String title = cleanNotificationField(event.title);
            String text = cleanNotificationField(event.text);
            String app = cleanNotificationField(event.sourceApp);
            if (title.isEmpty() && text.isEmpty()) {
                continue;
            }
            String key = app + "\n" + title;
            NotificationGroup group = groupsByKey.get(key);
            if (group == null) {
                group = new NotificationGroup(app, title);
                groupsByKey.put(key, group);
            }
            group.count++;
            group.latestAt = Math.max(group.latestAt, event.observedAtMillis);
            if (group.sampleText.isEmpty() && !text.isEmpty()) {
                group.sampleText = text;
            }
        }
        JSONArray groups = new JSONArray();
        StringBuilder summary = new StringBuilder();
        int emitted = 0;
        for (NotificationGroup group : groupsByKey.values()) {
            if (emitted >= 8) {
                break;
            }
            groups.put(group.toJson());
            if (summary.length() > 0) {
                summary.append("; ");
            }
            summary.append(group.app.isEmpty() ? "Unknown app" : group.app);
            if (!group.title.isEmpty()) {
                summary.append(": ").append(group.title);
            }
            if (group.count > 1) {
                summary.append(" (").append(group.count).append(" updates)");
            }
            if (!group.sampleText.isEmpty()) {
                summary.append(" - ").append(group.sampleText);
            }
            emitted++;
        }
        if (summary.length() == 0) {
            summary.append(query.trim().isEmpty()
                    ? "No recent indexed notifications."
                    : "No recent indexed notifications matched \"" + query.trim() + "\".");
        }
        return new JSONObject()
                .put("status", "notifications.summary")
                .put("summary", summary.toString())
                .put("groups", groups)
                .put("query", query)
                .put("limit", limit)
                .put("since", since)
                .toString();
    }

    private String notificationsOpen(JSONObject arguments) throws JSONException {
        String key = arguments.optString("notification_key",
                arguments.optString("key", ""));
        String packageName = arguments.optString("package",
                arguments.optString("package_name", ""));
        String query = arguments.optString("query", "");
        if (key.trim().isEmpty() && packageName.trim().isEmpty() && query.trim().isEmpty()) {
            return error("empty_notification_selector");
        }
        String status = OpenPhoneNotificationListenerService.openMatchingNotification(
                key, packageName, query);
        return new JSONObject()
                .put("status", status)
                .put("notification_key", key)
                .put("package", packageName)
                .put("query", query)
                .toString();
    }

    private String calendarSearch(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_CALENDAR)) {
            return error("calendar_permission_denied:read");
        }
        long now = System.currentTimeMillis();
        long startAt = arguments.optLong("start_at", 0L);
        long endAt = arguments.optLong("end_at", 0L);
        if (startAt <= 0) {
            startAt = now - 24L * 60L * 60L * 1000L;
        }
        if (endAt <= startAt) {
            endAt = now + 90L * 24L * 60L * 60L * 1000L;
        }
        long maxWindowMs = 366L * 24L * 60L * 60L * 1000L;
        if (endAt - startAt > maxWindowMs) {
            endAt = startAt + maxWindowMs;
        }
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        String query = arguments.optString("query", "").trim().toLowerCase(Locale.US);
        JSONArray events = new JSONArray();
        Uri.Builder builder = CalendarContract.Instances.CONTENT_URI.buildUpon();
        ContentUris.appendId(builder, startAt);
        ContentUris.appendId(builder, endAt);
        String[] projection = new String[] {
                CalendarContract.Instances.EVENT_ID,
                CalendarContract.Instances.BEGIN,
                CalendarContract.Instances.END,
                CalendarContract.Instances.TITLE,
                CalendarContract.Instances.DESCRIPTION,
                CalendarContract.Instances.EVENT_LOCATION,
                CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
                CalendarContract.Instances.ALL_DAY
        };
        try (Cursor cursor = mContext.getContentResolver().query(builder.build(), projection,
                null, null, CalendarContract.Instances.BEGIN + " ASC")) {
            if (cursor == null) {
                return error("calendar_query_failed");
            }
            while (cursor.moveToNext() && events.length() < limit) {
                long eventId = cursor.getLong(0);
                long begin = cursor.getLong(1);
                long end = cursor.getLong(2);
                String title = stringAt(cursor, 3);
                String description = stringAt(cursor, 4);
                String location = stringAt(cursor, 5);
                String calendarName = stringAt(cursor, 6);
                boolean allDay = cursor.getInt(7) != 0;
                if (!query.isEmpty()) {
                    String haystack = (title + " " + description + " " + location + " "
                            + calendarName).toLowerCase(Locale.US);
                    if (!haystack.contains(query)) {
                        continue;
                    }
                }
                events.put(new JSONObject()
                        .put("event_id", eventId)
                        .put("start_at", begin)
                        .put("start_local", localTime(begin))
                        .put("end_at", end)
                        .put("end_local", localTime(end))
                        .put("title", title)
                        .put("description", description)
                        .put("location", location)
                        .put("calendar", calendarName)
                        .put("all_day", allDay));
            }
        } catch (SecurityException e) {
            return error("calendar_permission_denied:read");
        } catch (RuntimeException e) {
            return error("calendar_query_failed:" + e.getClass().getSimpleName());
        }
        return new JSONObject()
                .put("status", "calendar.search.results")
                .put("query", query)
                .put("start_at", startAt)
                .put("end_at", endAt)
                .put("limit", limit)
                .put("events", events)
                .toString();
    }

    private String calendarCreateEvent(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.WRITE_CALENDAR)) {
            return error("calendar_permission_denied:write");
        }
        String title = arguments.optString("title", "").trim();
        long startAt = arguments.optLong("start_at", 0L);
        if (title.isEmpty()) {
            return error("empty_calendar_title");
        }
        if (startAt <= 0) {
            return error("missing_calendar_start_at");
        }
        long endAt = arguments.optLong("end_at", 0L);
        int durationMinutes = Math.max(1, Math.min(arguments.optInt("duration_minutes", 60),
                24 * 60));
        if (endAt <= startAt) {
            endAt = startAt + durationMinutes * 60L * 1000L;
        }
        long calendarId = arguments.optLong("calendar_id", -1L);
        if (calendarId <= 0) {
            calendarId = firstWritableCalendarId();
        }
        if (calendarId <= 0) {
            return error("no_writable_calendar");
        }
        ContentValues values = new ContentValues();
        values.put(CalendarContract.Events.CALENDAR_ID, calendarId);
        values.put(CalendarContract.Events.TITLE, title);
        values.put(CalendarContract.Events.DESCRIPTION, arguments.optString("description", ""));
        values.put(CalendarContract.Events.EVENT_LOCATION, arguments.optString("location", ""));
        values.put(CalendarContract.Events.DTSTART, startAt);
        values.put(CalendarContract.Events.DTEND, endAt);
        values.put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().getID());
        values.put(CalendarContract.Events.ALL_DAY, arguments.optBoolean("all_day", false) ? 1 : 0);
        try {
            Uri uri = mContext.getContentResolver().insert(CalendarContract.Events.CONTENT_URI,
                    values);
            long eventId = uri == null ? -1L : ContentUris.parseId(uri);
            return new JSONObject()
                    .put("status", eventId >= 0 ? "calendar.event_created"
                            : "calendar.create_failed")
                    .put("event_id", eventId)
                    .put("calendar_id", calendarId)
                    .put("title", title)
                    .put("start_at", startAt)
                    .put("end_at", endAt)
                    .toString();
        } catch (SecurityException e) {
            return error("calendar_permission_denied:write");
        } catch (RuntimeException e) {
            return error("calendar_create_failed:" + e.getClass().getSimpleName());
        }
    }

    private String messageCalendarEventCreate(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_SMS)) {
            return error("messages_permission_denied:read");
        }
        if (!hasPermission(Manifest.permission.WRITE_CALENDAR)) {
            return error("calendar_permission_denied:write");
        }
        JSONObject message = firstMatchingSms(arguments.optString("query", "").trim(),
                arguments.optLong("thread_id", 0L));
        if (message == null) {
            return error(arguments.optString("query", "").trim().isEmpty()
                    && arguments.optLong("thread_id", 0L) <= 0
                    ? "no_sms_messages" : "no_matching_sms_message");
        }
        JSONObject create = new JSONObject(arguments.toString());
        String originalDescription = create.optString("description", "").trim();
        StringBuilder description = new StringBuilder();
        if (!originalDescription.isEmpty()) {
            description.append(originalDescription).append("\n\n");
        }
        description.append("Source message: ")
                .append(message.optString("body", ""))
                .append("\nFrom: ")
                .append(message.optString("address", ""))
                .append("\nMessage id: ")
                .append(message.optLong("message_id", 0L))
                .append("\nThread id: ")
                .append(message.optLong("thread_id", 0L))
                .append("\nMessage date: ")
                .append(message.optLong("date", 0L));
        create.put("description", description.toString());
        JSONObject result = new JSONObject(calendarCreateEvent(create));
        if ("calendar.event_created".equals(result.optString("status", ""))) {
            result.put("status", "calendar.event_created_from_message")
                    .put("message", messageEvidence(message));
        }
        return result.toString();
    }

    private String calendarUpdateEvent(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.WRITE_CALENDAR)) {
            return error("calendar_permission_denied:write");
        }
        long eventId = arguments.optLong("event_id", 0L);
        if (eventId <= 0) {
            return error("missing_calendar_event_id");
        }
        JSONObject before = eventById(eventId);
        if (before == null) {
            return error("calendar_event_not_found:" + eventId);
        }
        ContentValues values = new ContentValues();
        if (arguments.has("title")) {
            String title = arguments.optString("title", "").trim();
            if (title.isEmpty()) {
                return error("empty_calendar_title");
            }
            values.put(CalendarContract.Events.TITLE, title);
        }
        if (arguments.has("description")) {
            values.put(CalendarContract.Events.DESCRIPTION,
                    arguments.optString("description", ""));
        }
        if (arguments.has("location")) {
            values.put(CalendarContract.Events.EVENT_LOCATION,
                    arguments.optString("location", ""));
        }
        long startAt = arguments.optLong("start_at", 0L);
        long endAt = arguments.optLong("end_at", 0L);
        if (startAt > 0 || endAt > 0 || arguments.has("duration_minutes")) {
            long newStart = startAt > 0 ? startAt : before.optLong("start_at", 0L);
            long newEnd = endAt;
            if (newEnd <= newStart) {
                if (arguments.has("duration_minutes") || startAt > 0) {
                    int durationMinutes = Math.max(1, Math.min(
                            arguments.optInt("duration_minutes", 60), 24 * 60));
                    long beforeDuration = before.optLong("end_at", 0L)
                            - before.optLong("start_at", 0L);
                    newEnd = newStart + (arguments.has("duration_minutes")
                            ? durationMinutes * 60L * 1000L
                            : (beforeDuration > 0 ? beforeDuration
                                    : durationMinutes * 60L * 1000L));
                } else {
                    return error("calendar_end_before_start");
                }
            }
            values.put(CalendarContract.Events.DTSTART, newStart);
            values.put(CalendarContract.Events.DTEND, newEnd);
        }
        if (arguments.has("all_day")) {
            values.put(CalendarContract.Events.ALL_DAY,
                    arguments.optBoolean("all_day", false) ? 1 : 0);
        }
        if (values.size() == 0) {
            return error("no_calendar_fields_to_update");
        }
        try {
            Uri uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId);
            int updated = mContext.getContentResolver().update(uri, values, null, null);
            if (updated <= 0) {
                return error("calendar_update_failed");
            }
            JSONObject after = eventById(eventId);
            return new JSONObject()
                    .put("status", "calendar.event_updated")
                    .put("event_id", eventId)
                    .put("before", before)
                    .put("after", after == null ? new JSONObject() : after)
                    .toString();
        } catch (SecurityException e) {
            return error("calendar_permission_denied:write");
        } catch (RuntimeException e) {
            return error("calendar_update_failed:" + e.getClass().getSimpleName());
        }
    }

    private String calendarDeleteEvent(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.WRITE_CALENDAR)) {
            return error("calendar_permission_denied:write");
        }
        long eventId = arguments.optLong("event_id", 0L);
        if (eventId <= 0) {
            return error("missing_calendar_event_id");
        }
        JSONObject deleted = eventById(eventId);
        if (deleted == null) {
            return error("calendar_event_not_found:" + eventId);
        }
        try {
            Uri uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId);
            int count = mContext.getContentResolver().delete(uri, null, null);
            if (count <= 0) {
                return error("calendar_delete_failed");
            }
            return new JSONObject()
                    .put("status", "calendar.event_deleted")
                    .put("event_id", eventId)
                    .put("deleted", deleted)
                    .toString();
        } catch (SecurityException e) {
            return error("calendar_permission_denied:write");
        } catch (RuntimeException e) {
            return error("calendar_delete_failed:" + e.getClass().getSimpleName());
        }
    }

    private String calendarCheckAvailability(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_CALENDAR)) {
            return error("calendar_permission_denied:read");
        }
        long now = System.currentTimeMillis();
        long startAt = arguments.optLong("start_at", 0L);
        long endAt = arguments.optLong("end_at", 0L);
        if (startAt <= 0) {
            startAt = now;
        }
        if (endAt <= startAt) {
            endAt = startAt + 7L * 24L * 60L * 60L * 1000L;
        }
        long maxWindowMs = 31L * 24L * 60L * 60L * 1000L;
        if (endAt - startAt > maxWindowMs) {
            endAt = startAt + maxWindowMs;
        }
        long slotMs = Math.max(5, Math.min(arguments.optInt("duration_minutes", 30),
                24 * 60)) * 60L * 1000L;
        ArrayList<long[]> busyRaw = new ArrayList<>();
        Uri.Builder builder = CalendarContract.Instances.CONTENT_URI.buildUpon();
        ContentUris.appendId(builder, startAt);
        ContentUris.appendId(builder, endAt);
        String[] projection = new String[] {
                CalendarContract.Instances.BEGIN,
                CalendarContract.Instances.END,
                CalendarContract.Instances.TITLE,
                CalendarContract.Instances.ALL_DAY,
                CalendarContract.Instances.AVAILABILITY
        };
        try (Cursor cursor = mContext.getContentResolver().query(builder.build(), projection,
                null, null, CalendarContract.Instances.BEGIN + " ASC")) {
            if (cursor == null) {
                return error("calendar_query_failed");
            }
            while (cursor.moveToNext()) {
                if (cursor.getInt(4) == CalendarContract.Events.AVAILABILITY_FREE) {
                    continue;
                }
                long begin = Math.max(cursor.getLong(0), startAt);
                long end = Math.min(cursor.getLong(1), endAt);
                if (end > begin) {
                    busyRaw.add(new long[] {begin, end});
                }
            }
        } catch (SecurityException e) {
            return error("calendar_permission_denied:read");
        } catch (RuntimeException e) {
            return error("calendar_query_failed:" + e.getClass().getSimpleName());
        }
        busyRaw.sort((a, b) -> Long.compare(a[0], b[0]));
        ArrayList<long[]> busy = new ArrayList<>();
        for (long[] interval : busyRaw) {
            if (!busy.isEmpty() && interval[0] <= busy.get(busy.size() - 1)[1]) {
                long[] last = busy.get(busy.size() - 1);
                last[1] = Math.max(last[1], interval[1]);
            } else {
                busy.add(new long[] {interval[0], interval[1]});
            }
        }
        JSONArray busyJson = new JSONArray();
        for (long[] interval : busy) {
            busyJson.put(new JSONObject()
                    .put("start_at", interval[0])
                    .put("start_local", localTime(interval[0]))
                    .put("end_at", interval[1])
                    .put("end_local", localTime(interval[1])));
        }
        JSONArray freeJson = new JSONArray();
        long cursorMs = startAt;
        for (long[] interval : busy) {
            if (interval[0] - cursorMs >= slotMs && freeJson.length() < 20) {
                freeJson.put(new JSONObject()
                        .put("start_at", cursorMs)
                        .put("start_local", localTime(cursorMs))
                        .put("end_at", interval[0])
                        .put("end_local", localTime(interval[0])));
            }
            cursorMs = Math.max(cursorMs, interval[1]);
        }
        if (endAt - cursorMs >= slotMs && freeJson.length() < 20) {
            freeJson.put(new JSONObject()
                    .put("start_at", cursorMs)
                    .put("start_local", localTime(cursorMs))
                    .put("end_at", endAt)
                    .put("end_local", localTime(endAt)));
        }
        return new JSONObject()
                .put("status", "calendar.availability")
                .put("start_at", startAt)
                .put("start_local", localTime(startAt))
                .put("end_at", endAt)
                .put("end_local", localTime(endAt))
                .put("slot_minutes", slotMs / 60000L)
                .put("busy", busyJson)
                .put("free", freeJson)
                .toString();
    }

    private static String localTime(long epochMillis) {
        if (epochMillis <= 0) {
            return "";
        }
        java.text.SimpleDateFormat format =
                new java.text.SimpleDateFormat("EEE yyyy-MM-dd HH:mm zzz", Locale.US);
        format.setTimeZone(TimeZone.getDefault());
        return format.format(new java.util.Date(epochMillis));
    }

    private JSONObject eventById(long eventId) throws JSONException {
        String[] projection = new String[] {
                CalendarContract.Events.TITLE,
                CalendarContract.Events.DESCRIPTION,
                CalendarContract.Events.EVENT_LOCATION,
                CalendarContract.Events.DTSTART,
                CalendarContract.Events.DTEND,
                CalendarContract.Events.ALL_DAY,
                CalendarContract.Events.CALENDAR_ID,
                CalendarContract.Events.DELETED
        };
        Uri uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId);
        try (Cursor cursor = mContext.getContentResolver().query(uri, projection,
                null, null, null)) {
            if (cursor == null || !cursor.moveToFirst() || cursor.getInt(7) != 0) {
                return null;
            }
            return new JSONObject()
                    .put("event_id", eventId)
                    .put("title", stringAt(cursor, 0))
                    .put("description", stringAt(cursor, 1))
                    .put("location", stringAt(cursor, 2))
                    .put("start_at", cursor.getLong(3))
                    .put("start_local", localTime(cursor.getLong(3)))
                    .put("end_at", cursor.getLong(4))
                    .put("end_local", localTime(cursor.getLong(4)))
                    .put("all_day", cursor.getInt(5) != 0)
                    .put("calendar_id", cursor.getLong(6));
        } catch (RuntimeException e) {
            return null;
        }
    }

    private long firstWritableCalendarId() {
        if (!hasPermission(Manifest.permission.READ_CALENDAR)) {
            return -1L;
        }
        String[] projection = new String[] {
                CalendarContract.Calendars._ID,
                CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
                CalendarContract.Calendars.VISIBLE
        };
        String selection = CalendarContract.Calendars.VISIBLE + "!=0 AND "
                + CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL + ">="
                + CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR;
        try (Cursor cursor = mContext.getContentResolver().query(
                CalendarContract.Calendars.CONTENT_URI, projection, selection, null,
                CalendarContract.Calendars.IS_PRIMARY + " DESC, "
                        + CalendarContract.Calendars._ID + " ASC")) {
            if (cursor != null && cursor.moveToFirst()) {
                return cursor.getLong(0);
            }
        } catch (SecurityException ignored) {
        } catch (RuntimeException ignored) {
        }
        return -1L;
    }

    private boolean hasPermission(String permission) {
        return mContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    private static String stringAt(Cursor cursor, int index) {
        return cursor.isNull(index) ? "" : cursor.getString(index);
    }

    private String contactsSearch(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
            return error("contacts_permission_denied:read");
        }
        String query = arguments.optString("query", "").trim();
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        boolean includeDetails = arguments.optBoolean("include_details", true);
        JSONArray contacts = new JSONArray();
        Uri uri = query.isEmpty()
                ? ContactsContract.Contacts.CONTENT_URI
                : Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI,
                        Uri.encode(query));
        String[] projection = new String[] {
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.LOOKUP_KEY,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
                ContactsContract.Contacts.HAS_PHONE_NUMBER,
                ContactsContract.Contacts.STARRED
        };
        try (Cursor cursor = mContext.getContentResolver().query(uri, projection, null, null,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY + " ASC")) {
            if (cursor == null) {
                return error("contacts_query_failed");
            }
            while (cursor.moveToNext() && contacts.length() < limit) {
                long contactId = cursor.getLong(0);
                String lookupKey = stringAt(cursor, 1);
                String displayName = stringAt(cursor, 2);
                boolean hasPhone = cursor.getInt(3) != 0;
                JSONObject contact = new JSONObject()
                        .put("contact_id", contactId)
                        .put("lookup_key", lookupKey)
                        .put("display_name", displayName)
                        .put("starred", cursor.getInt(4) != 0);
                if (includeDetails) {
                    contact.put("phones", hasPhone ? contactPhones(contactId) : new JSONArray())
                            .put("emails", contactEmails(contactId));
                } else {
                    contact.put("has_phone", hasPhone);
                }
                contacts.put(contact);
            }
        } catch (SecurityException e) {
            return error("contacts_permission_denied:read");
        } catch (RuntimeException e) {
            return error("contacts_query_failed:" + e.getClass().getSimpleName());
        }
        return new JSONObject()
                .put("status", "contacts.search.results")
                .put("query", query)
                .put("limit", limit)
                .put("contacts", contacts)
                .toString();
    }

    private String messagesSearch(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_SMS)) {
            return error("messages_permission_denied:read");
        }
        String query = arguments.optString("query", "").trim();
        long threadId = arguments.optLong("thread_id", 0L);
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        JSONArray messages = new JSONArray();
        String[] projection = new String[] {
                Telephony.Sms._ID,
                Telephony.Sms.THREAD_ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.TYPE,
                Telephony.Sms.READ
        };
        SmsSelection smsSelection = smsSelection(query, threadId);
        try (Cursor cursor = mContext.getContentResolver().query(
                Telephony.Sms.CONTENT_URI, projection,
                smsSelection.selection, smsSelection.selectionArgs,
                Telephony.Sms.DATE + " DESC")) {
            if (cursor == null) {
                return error("messages_query_failed");
            }
            while (cursor.moveToNext() && messages.length() < limit) {
                messages.put(new JSONObject()
                        .put("message_id", cursor.getLong(0))
                        .put("thread_id", cursor.getLong(1))
                        .put("address", stringAt(cursor, 2))
                        .put("body", stringAt(cursor, 3))
                        .put("date", cursor.getLong(4))
                        .put("type", smsTypeLabel(cursor.getInt(5)))
                        .put("read", cursor.getInt(6) != 0));
            }
        } catch (SecurityException e) {
            return error("messages_permission_denied:read");
        } catch (RuntimeException e) {
            return error("messages_query_failed:" + e.getClass().getSimpleName());
        }
        return new JSONObject()
                .put("status", "messages.search.results")
                .put("query", query)
                .put("thread_id", threadId)
                .put("limit", limit)
                .put("messages", messages)
                .toString();
    }

    private String messagesSummary(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_SMS)) {
            return error("messages_permission_denied:read");
        }
        String query = arguments.optString("query", "").trim();
        long threadId = arguments.optLong("thread_id", 0L);
        long since = arguments.optLong("since", 0L);
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 30), 80));
        String[] projection = new String[] {
                Telephony.Sms._ID,
                Telephony.Sms.THREAD_ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.TYPE,
                Telephony.Sms.READ
        };
        SmsSelection smsSelection = smsSelection(query, threadId);
        Map<Long, MessageThreadGroup> groupsByThread = new LinkedHashMap<>();
        try (Cursor cursor = mContext.getContentResolver().query(
                Telephony.Sms.CONTENT_URI, projection,
                smsSelection.selection, smsSelection.selectionArgs,
                Telephony.Sms.DATE + " DESC")) {
            if (cursor == null) {
                return error("messages_query_failed");
            }
            int seen = 0;
            while (cursor.moveToNext() && seen < limit) {
                long date = cursor.getLong(4);
                if (since > 0L && date < since) {
                    continue;
                }
                long currentThreadId = cursor.getLong(1);
                MessageThreadGroup group = groupsByThread.get(currentThreadId);
                if (group == null) {
                    group = new MessageThreadGroup(currentThreadId, stringAt(cursor, 2));
                    groupsByThread.put(currentThreadId, group);
                }
                String body = stringAt(cursor, 3);
                int type = cursor.getInt(5);
                group.count++;
                group.latestAt = Math.max(group.latestAt, date);
                if (Telephony.Sms.MESSAGE_TYPE_INBOX == type) {
                    group.inboxCount++;
                } else if (Telephony.Sms.MESSAGE_TYPE_SENT == type) {
                    group.sentCount++;
                }
                if (cursor.getInt(6) == 0) {
                    group.unreadCount++;
                }
                if (group.samples.length() < 3 && !body.trim().isEmpty()) {
                    group.samples.put(new JSONObject()
                            .put("message_id", cursor.getLong(0))
                            .put("date", date)
                            .put("type", smsTypeLabel(type))
                            .put("body", body));
                }
                seen++;
            }
        } catch (SecurityException e) {
            return error("messages_permission_denied:read");
        } catch (RuntimeException e) {
            return error("messages_query_failed:" + e.getClass().getSimpleName());
        }
        JSONArray threads = new JSONArray();
        StringBuilder summary = new StringBuilder();
        int emitted = 0;
        for (MessageThreadGroup group : groupsByThread.values()) {
            if (emitted >= 8) {
                break;
            }
            threads.put(group.toJson());
            if (summary.length() > 0) {
                summary.append("; ");
            }
            summary.append(group.address.isEmpty() ? "Unknown sender" : group.address)
                    .append(": ").append(group.count).append(" message");
            if (group.count != 1) {
                summary.append("s");
            }
            if (group.unreadCount > 0) {
                summary.append(", ").append(group.unreadCount).append(" unread");
            }
            JSONObject sample = group.samples.optJSONObject(0);
            if (sample != null) {
                summary.append(" - ").append(sample.optString("body", ""));
            }
            emitted++;
        }
        if (summary.length() == 0) {
            summary.append(query.isEmpty()
                    ? "No recent SMS messages were available."
                    : "No recent SMS messages matched \"" + query + "\".");
        }
        return new JSONObject()
                .put("status", "messages.summary")
                .put("query", query)
                .put("thread_id", threadId)
                .put("limit", limit)
                .put("summary", summary.toString())
                .put("threads", threads)
                .toString();
    }

    private String messagesDraft(JSONObject arguments) throws JSONException {
        String body = arguments.optString("body", "").trim();
        String to = arguments.optString("to", "").trim();
        String contactQuery = arguments.optString("contact_query", "").trim();
        if (body.isEmpty()) {
            return error("empty_message_body");
        }
        if (to.isEmpty() && !contactQuery.isEmpty()) {
            to = firstPhoneForContactQuery(contactQuery);
        }
        JSONObject draft = new JSONObject()
                .put("to", to)
                .put("body", body)
                .put("contact_query", contactQuery);
        return new JSONObject()
                .put("status", "messages.draft_ready")
                .put("draft", draft)
                .put("requires_review_before_send", true)
                .toString();
    }

    private String messagesSend(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.SEND_SMS)) {
            return error("messages_permission_denied:send");
        }
        String to = arguments.optString("to", "").trim();
        String contactQuery = arguments.optString("contact_query", "").trim();
        String body = arguments.optString("body", "").trim();
        String resolvedFrom = "";
        if (!to.isEmpty() && !looksLikeSmsAddress(to)) {
            resolvedFrom = to;
            String resolved = firstPhoneForContactQuery(to);
            if (!resolved.isEmpty()) {
                to = resolved;
            }
        }
        if ((to.isEmpty() || !looksLikeSmsAddress(to)) && !contactQuery.isEmpty()) {
            resolvedFrom = contactQuery;
            String resolved = firstPhoneForContactQuery(contactQuery);
            if (!resolved.isEmpty()) {
                to = resolved;
            }
        }
        if (to.isEmpty()) {
            return error("empty_message_recipient");
        }
        if (!looksLikeSmsAddress(to)) {
            return error("message_recipient_not_resolved:" + to);
        }
        if (body.isEmpty()) {
            return error("empty_message_body");
        }
        try {
            SmsManager.getDefault().sendTextMessage(to, null, body, null, null);
            JSONObject result = new JSONObject()
                    .put("status", "messages.sent")
                    .put("to", to)
                    .put("body_length", body.length());
            if (!resolvedFrom.isEmpty()) {
                result.put("resolved_from", resolvedFrom);
            }
            return result.toString();
        } catch (SecurityException e) {
            return error("messages_permission_denied:send");
        } catch (RuntimeException e) {
            return error("messages_send_failed:" + e.getClass().getSimpleName());
        }
    }

    private static boolean looksLikeSmsAddress(String value) {
        if (value == null) {
            return false;
        }
        boolean hasDigit = false;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (Character.isDigit(c)) {
                hasDigit = true;
            } else if (Character.isLetter(c)) {
                return false;
            }
        }
        return hasDigit;
    }

    private static final class SmsSelection {
        final String selection;
        final String[] selectionArgs;

        SmsSelection(String selection, String[] selectionArgs) {
            this.selection = selection;
            this.selectionArgs = selectionArgs;
        }
    }

    /**
     * Matches each whitespace-separated query token against address or body
     * so natural phrases ("team dinner Luigi Trattoria") still match messages
     * with extra words in between ("Team dinner at Luigi Trattoria").
     */
    private static SmsSelection smsSelection(String query, long threadId) {
        StringBuilder selection = new StringBuilder();
        List<String> args = new ArrayList<>();
        if (threadId > 0) {
            selection.append(Telephony.Sms.THREAD_ID).append("=?");
            args.add(Long.toString(threadId));
        }
        if (!query.isEmpty()) {
            for (String token : query.split("\\s+")) {
                if (token.isEmpty()) {
                    continue;
                }
                if (selection.length() > 0) {
                    selection.append(" AND ");
                }
                selection.append('(')
                        .append(Telephony.Sms.ADDRESS).append(" LIKE ? OR ")
                        .append(Telephony.Sms.BODY).append(" LIKE ?)");
                String like = "%" + token + "%";
                args.add(like);
                args.add(like);
            }
        }
        if (selection.length() == 0) {
            return new SmsSelection(null, null);
        }
        return new SmsSelection(selection.toString(),
                args.toArray(new String[0]));
    }

    private JSONObject firstMatchingSms(String query, long threadId) throws JSONException {
        String[] projection = new String[] {
                Telephony.Sms._ID,
                Telephony.Sms.THREAD_ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.TYPE,
                Telephony.Sms.READ
        };
        SmsSelection smsSelection = smsSelection(query, threadId);
        try (Cursor cursor = mContext.getContentResolver().query(
                Telephony.Sms.CONTENT_URI, projection,
                smsSelection.selection, smsSelection.selectionArgs,
                Telephony.Sms.DATE + " DESC")) {
            if (cursor == null) {
                return null;
            }
            while (cursor.moveToNext()) {
                String body = stringAt(cursor, 3);
                String address = stringAt(cursor, 2);
                if (body.trim().isEmpty() && address.trim().isEmpty()) {
                    continue;
                }
                return new JSONObject()
                        .put("message_id", cursor.getLong(0))
                        .put("thread_id", cursor.getLong(1))
                        .put("address", address)
                        .put("body", body)
                        .put("date", cursor.getLong(4))
                        .put("type", smsTypeLabel(cursor.getInt(5)))
                        .put("read", cursor.getInt(6) != 0);
            }
        } catch (SecurityException e) {
            throw e;
        } catch (RuntimeException ignored) {
        }
        return null;
    }

    private String callsSearch(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_CALL_LOG)) {
            return error("calls_permission_denied:read");
        }
        String query = arguments.optString("query", "").trim();
        String typeFilter = arguments.optString("type", "").trim().toLowerCase(Locale.US);
        long since = arguments.optLong("since", 0L);
        long until = arguments.optLong("until", 0L);
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        int typeCode = callTypeForLabel(typeFilter);
        if (!typeFilter.isEmpty() && typeCode == 0) {
            return error("unknown_call_type:" + typeFilter);
        }
        JSONArray calls = new JSONArray();
        String[] projection = new String[] {
                CallLog.Calls._ID,
                CallLog.Calls.NUMBER,
                CallLog.Calls.CACHED_NAME,
                CallLog.Calls.TYPE,
                CallLog.Calls.DATE,
                CallLog.Calls.DURATION,
                CallLog.Calls.PHONE_ACCOUNT_COMPONENT_NAME
        };
        StringBuilder selection = new StringBuilder();
        java.util.ArrayList<String> selectionArgs = new java.util.ArrayList<>();
        if (typeCode > 0) {
            selection.append(CallLog.Calls.TYPE).append("=?");
            selectionArgs.add(Integer.toString(typeCode));
        }
        if (since > 0) {
            appendAnd(selection);
            selection.append(CallLog.Calls.DATE).append(">=?");
            selectionArgs.add(Long.toString(since));
        }
        if (until > 0) {
            appendAnd(selection);
            selection.append(CallLog.Calls.DATE).append("<=?");
            selectionArgs.add(Long.toString(until));
        }
        // The query post-filters in Java instead of SQL LIKE so contact names join
        // even when the call-log cached name is empty (e.g. contact saved after the
        // call) and numbers match across formatting/country-code variants.
        JSONArray queryNumbers = query.isEmpty()
                ? new JSONArray() : contactNumbersForQuery(query, 5);
        java.util.HashMap<String, String> nameCache = new java.util.HashMap<>();
        try (Cursor cursor = mContext.getContentResolver().query(
                CallLog.Calls.CONTENT_URI, projection,
                selection.length() == 0 ? null : selection.toString(),
                selectionArgs.isEmpty() ? null : selectionArgs.toArray(new String[0]),
                CallLog.Calls.DATE + " DESC")) {
            if (cursor == null) {
                return error("calls_query_failed");
            }
            int scanned = 0;
            while (cursor.moveToNext() && calls.length() < limit && scanned < 200) {
                scanned++;
                String number = stringAt(cursor, 1);
                String cachedName = stringAt(cursor, 2);
                String name = cachedName.isEmpty()
                        ? contactNameForNumber(number, nameCache) : cachedName;
                if (!query.isEmpty()
                        && !callMatchesQuery(number, cachedName, name, query, queryNumbers)) {
                    continue;
                }
                long date = cursor.getLong(4);
                calls.put(new JSONObject()
                        .put("call_id", cursor.getLong(0))
                        .put("number", number)
                        .put("name", name)
                        .put("type", callTypeLabel(cursor.getInt(3)))
                        .put("date", date)
                        .put("date_local", localTime(date))
                        .put("duration_seconds", cursor.getLong(5))
                        .put("phone_account", stringAt(cursor, 6)));
            }
        } catch (SecurityException e) {
            return error("calls_permission_denied:read");
        } catch (RuntimeException e) {
            return error("calls_query_failed:" + e.getClass().getSimpleName());
        }
        return new JSONObject()
                .put("status", "calls.search.results")
                .put("query", query)
                .put("type", typeFilter)
                .put("since", since)
                .put("until", until)
                .put("limit", limit)
                .put("calls", calls)
                .toString();
    }

    private static boolean callMatchesQuery(String number, String cachedName, String joinedName,
            String query, JSONArray queryNumbers) {
        String needle = query.toLowerCase(Locale.US);
        if (number.toLowerCase(Locale.US).contains(needle)
                || cachedName.toLowerCase(Locale.US).contains(needle)
                || joinedName.toLowerCase(Locale.US).contains(needle)) {
            return true;
        }
        for (int i = 0; i < queryNumbers.length(); i++) {
            String candidate = queryNumbers.optString(i, "");
            if (!candidate.isEmpty()
                    && android.telephony.PhoneNumberUtils.compare(number, candidate)) {
                return true;
            }
        }
        return false;
    }

    private String contactNameForNumber(String number, java.util.HashMap<String, String> cache) {
        if (number == null || number.trim().isEmpty()) {
            return "";
        }
        String cached = cache.get(number);
        if (cached != null) {
            return cached;
        }
        String name = "";
        if (hasPermission(Manifest.permission.READ_CONTACTS)) {
            Uri uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                    Uri.encode(number));
            try (Cursor cursor = mContext.getContentResolver().query(uri,
                    new String[] { ContactsContract.PhoneLookup.DISPLAY_NAME },
                    null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    String value = cursor.getString(0);
                    name = value == null ? "" : value;
                }
            } catch (RuntimeException ignored) {
            }
        }
        cache.put(number, name);
        return name;
    }

    private JSONArray contactNumbersForQuery(String query, int maxNumbers) {
        JSONArray numbers = new JSONArray();
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
            return numbers;
        }
        Uri uri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI,
                Uri.encode(query));
        String[] projection = new String[] {
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.HAS_PHONE_NUMBER
        };
        try (Cursor cursor = mContext.getContentResolver().query(uri, projection, null, null,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY + " ASC")) {
            if (cursor == null) {
                return numbers;
            }
            while (cursor.moveToNext() && numbers.length() < maxNumbers) {
                if (cursor.getInt(1) == 0) {
                    continue;
                }
                JSONArray phones = contactPhones(cursor.getLong(0));
                for (int i = 0; i < phones.length() && numbers.length() < maxNumbers; i++) {
                    JSONObject phone = phones.optJSONObject(i);
                    String value = phone == null ? "" : phone.optString("number", "");
                    if (!value.isEmpty()) {
                        numbers.put(value);
                    }
                }
            }
        } catch (RuntimeException ignored) {
        }
        return numbers;
    }

    private String phoneContext(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "").trim();
        String number = arguments.optString("number", "").trim();
        String search = number.isEmpty() ? query : number;
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 5), 10));

        JSONObject calls = new JSONObject(callsSearch(new JSONObject()
                .put("query", search)
                .put("limit", limit)
                .put("reason", arguments.optString("reason", ""))));
        JSONObject contacts = new JSONObject(contactsSearch(new JSONObject()
                .put("query", search)
                .put("limit", Math.min(limit, 5))
                .put("include_details", true)
                .put("reason", arguments.optString("reason", ""))));
        JSONObject messages = new JSONObject(messagesSearch(new JSONObject()
                .put("query", search)
                .put("limit", Math.min(limit * 2, 12))
                .put("reason", arguments.optString("reason", ""))));
        JSONObject calendar = new JSONObject(calendarSearch(new JSONObject()
                .put("query", search)
                .put("limit", Math.min(limit, 5))
                .put("reason", arguments.optString("reason", ""))));

        JSONArray messageRows = messages.optJSONArray("messages");
        JSONArray eventRows = calendar.optJSONArray("events");
        JSONArray codes = new JSONArray();
        collectConfirmationCodes(codes, "message", messageRows, "body");
        collectConfirmationCodes(codes, "calendar", eventRows, "description");
        collectConfirmationCodes(codes, "calendar", eventRows, "title");
        // Missed-call follow-ups scan the recent log unfiltered: the free-text query
        // ("missed calls", a person, a trip) rarely matches call-log rows directly.
        JSONObject recentCalls = new JSONObject(callsSearch(new JSONObject()
                .put("limit", 20)
                .put("reason", arguments.optString("reason", ""))));
        JSONObject recentSent = new JSONObject(messagesSearch(new JSONObject()
                .put("limit", 20)
                .put("reason", arguments.optString("reason", ""))));
        JSONArray missedFollowUps = missedCallFollowUps(
                recentCalls.optJSONArray("calls"), recentSent.optJSONArray("messages"));

        StringBuilder summary = new StringBuilder();
        int callCount = calls.optJSONArray("calls") == null ? 0 : calls.optJSONArray("calls").length();
        int contactCount = contacts.optJSONArray("contacts") == null
                ? 0 : contacts.optJSONArray("contacts").length();
        int messageCount = messageRows == null ? 0 : messageRows.length();
        int eventCount = eventRows == null ? 0 : eventRows.length();
        summary.append("Found ").append(callCount).append(" calls, ")
                .append(contactCount).append(" contacts, ")
                .append(messageCount).append(" messages, and ")
                .append(eventCount).append(" calendar events");
        if (!search.isEmpty()) {
            summary.append(" matching ").append(search);
        }
        if (codes.length() > 0) {
            summary.append(". Possible confirmation code: ")
                    .append(codes.optJSONObject(0).optString("code", ""));
        }
        if (missedFollowUps.length() > 0) {
            summary.append(". ").append(missedFollowUps.length())
                    .append(" missed call(s) not yet returned");
        }

        return new JSONObject()
                .put("status", "phone.context")
                .put("query", query)
                .put("number", number)
                .put("summary", summary.toString())
                .put("missed_call_follow_ups", missedFollowUps)
                .put("calls", calls.optJSONArray("calls") == null
                        ? new JSONArray() : calls.optJSONArray("calls"))
                .put("contacts", contacts.optJSONArray("contacts") == null
                        ? new JSONArray() : contacts.optJSONArray("contacts"))
                .put("messages", messageRows == null ? new JSONArray() : messageRows)
                .put("calendar", eventRows == null ? new JSONArray() : eventRows)
                .put("confirmation_codes", codes)
                .put("sources", new JSONObject()
                        .put("calls_status", calls.optString("status", ""))
                        .put("contacts_status", contacts.optString("status", ""))
                        .put("messages_status", messages.optString("status", ""))
                        .put("calendar_status", calendar.optString("status", "")))
                .toString();
    }

    private static JSONArray missedCallFollowUps(JSONArray calls, JSONArray messageRows)
            throws JSONException {
        JSONArray followUps = new JSONArray();
        if (calls == null) {
            return followUps;
        }
        for (int i = 0; i < calls.length() && followUps.length() < 5; i++) {
            JSONObject call = calls.optJSONObject(i);
            if (call == null || !"missed".equals(call.optString("type", ""))) {
                continue;
            }
            String number = call.optString("number", "");
            long missedAt = call.optLong("date", 0L);
            if (number.isEmpty() || missedAt <= 0) {
                continue;
            }
            boolean returned = false;
            for (int j = 0; j < calls.length() && !returned; j++) {
                JSONObject other = calls.optJSONObject(j);
                if (other == null || other.optLong("date", 0L) <= missedAt) {
                    continue;
                }
                String otherType = other.optString("type", "");
                if (!"outgoing".equals(otherType) && !"incoming".equals(otherType)) {
                    continue;
                }
                returned = android.telephony.PhoneNumberUtils.compare(
                        other.optString("number", ""), number);
            }
            for (int j = 0; messageRows != null && j < messageRows.length() && !returned; j++) {
                JSONObject message = messageRows.optJSONObject(j);
                if (message == null || message.optLong("date", 0L) <= missedAt
                        || !"sent".equals(message.optString("type", ""))) {
                    continue;
                }
                returned = android.telephony.PhoneNumberUtils.compare(
                        message.optString("address", ""), number);
            }
            if (!returned) {
                followUps.put(new JSONObject()
                        .put("number", number)
                        .put("name", call.optString("name", ""))
                        .put("missed_at", missedAt)
                        .put("missed_at_local", call.optString("date_local", "")));
            }
        }
        return followUps;
    }

    private String callsPlace(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.CALL_PHONE)) {
            return error("calls_permission_denied:place");
        }
        String number = arguments.optString("number", "").trim();
        String contactQuery = arguments.optString("contact_query", "").trim();
        if (number.isEmpty() && !contactQuery.isEmpty()) {
            number = firstPhoneForContactQuery(contactQuery);
        }
        if (number.isEmpty()) {
            return error("empty_call_number");
        }
        TelecomManager telecomManager = mContext.getSystemService(TelecomManager.class);
        if (telecomManager == null) {
            return error("telecom_unavailable");
        }
        try {
            telecomManager.placeCall(Uri.fromParts("tel", number, null), null);
            return new JSONObject()
                    .put("status", "calls.placed")
                    .put("number", number)
                    .put("contact_query", contactQuery)
                    .toString();
        } catch (SecurityException e) {
            return error("calls_permission_denied:place");
        } catch (RuntimeException e) {
            return error("calls_place_failed:" + e.getClass().getSimpleName());
        }
    }

    private String appsSearch(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "").trim();
        String normalizedQuery = query.toLowerCase(Locale.US);
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 12), 50));
        boolean includeSystem = arguments.optBoolean("include_system", true);
        PackageManager packageManager = mContext.getPackageManager();
        Intent launcherIntent = new Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> launchables = packageManager.queryIntentActivities(launcherIntent, 0);
        JSONArray apps = new JSONArray();
        for (ResolveInfo resolveInfo : launchables) {
            if (resolveInfo == null || resolveInfo.activityInfo == null) {
                continue;
            }
            String packageName = resolveInfo.activityInfo.packageName == null
                    ? "" : resolveInfo.activityInfo.packageName;
            if (packageName.isEmpty()) {
                continue;
            }
            ApplicationInfo appInfo = resolveInfo.activityInfo.applicationInfo;
            boolean systemApp = appInfo != null
                    && (appInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
            if (!includeSystem && systemApp) {
                continue;
            }
            CharSequence labelSeq = resolveInfo.loadLabel(packageManager);
            String label = labelSeq == null ? packageName : labelSeq.toString();
            String activityName = resolveInfo.activityInfo.name == null
                    ? "" : resolveInfo.activityInfo.name;
            String haystack = (label + " " + packageName + " " + activityName)
                    .toLowerCase(Locale.US);
            if (!normalizedQuery.isEmpty() && !haystack.contains(normalizedQuery)) {
                continue;
            }
            apps.put(new JSONObject()
                    .put("label", label)
                    .put("package", packageName)
                    .put("activity", activityName)
                    .put("system", systemApp)
                    .put("launchable", true));
            if (apps.length() >= limit) {
                break;
            }
        }
        return new JSONObject()
                .put("status", "apps.search.results")
                .put("query", query)
                .put("limit", limit)
                .put("include_system", includeSystem)
                .put("apps", apps)
                .toString();
    }

    private static void appendAnd(StringBuilder selection) {
        if (selection.length() > 0) {
            selection.append(" AND ");
        }
    }

    private static String callTypeLabel(int type) {
        switch (type) {
            case CallLog.Calls.INCOMING_TYPE:
                return "incoming";
            case CallLog.Calls.OUTGOING_TYPE:
                return "outgoing";
            case CallLog.Calls.MISSED_TYPE:
                return "missed";
            case CallLog.Calls.VOICEMAIL_TYPE:
                return "voicemail";
            case CallLog.Calls.REJECTED_TYPE:
                return "rejected";
            case CallLog.Calls.BLOCKED_TYPE:
                return "blocked";
            case CallLog.Calls.ANSWERED_EXTERNALLY_TYPE:
                return "answered_externally";
            default:
                return "unknown";
        }
    }

    private static int callTypeForLabel(String label) {
        switch (label) {
            case "":
                return 0;
            case "incoming":
                return CallLog.Calls.INCOMING_TYPE;
            case "outgoing":
                return CallLog.Calls.OUTGOING_TYPE;
            case "missed":
                return CallLog.Calls.MISSED_TYPE;
            case "voicemail":
                return CallLog.Calls.VOICEMAIL_TYPE;
            case "rejected":
                return CallLog.Calls.REJECTED_TYPE;
            case "blocked":
                return CallLog.Calls.BLOCKED_TYPE;
            case "answered_externally":
                return CallLog.Calls.ANSWERED_EXTERNALLY_TYPE;
            default:
                return 0;
        }
    }

    private String firstPhoneForContactQuery(String query) {
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
            return "";
        }
        Uri uri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI,
                Uri.encode(query));
        String[] projection = new String[] {
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.HAS_PHONE_NUMBER
        };
        try (Cursor cursor = mContext.getContentResolver().query(uri, projection, null, null,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY + " ASC")) {
            if (cursor == null) {
                return "";
            }
            while (cursor.moveToNext()) {
                if (cursor.getInt(1) == 0) {
                    continue;
                }
                JSONArray phones = contactPhones(cursor.getLong(0));
                if (phones.length() > 0) {
                    return phones.optJSONObject(0) == null ? ""
                            : phones.optJSONObject(0).optString("number", "");
                }
            }
        } catch (RuntimeException ignored) {
        }
        return "";
    }

    private static String smsTypeLabel(int type) {
        switch (type) {
            case Telephony.Sms.MESSAGE_TYPE_INBOX:
                return "inbox";
            case Telephony.Sms.MESSAGE_TYPE_SENT:
                return "sent";
            case Telephony.Sms.MESSAGE_TYPE_DRAFT:
                return "draft";
            case Telephony.Sms.MESSAGE_TYPE_OUTBOX:
                return "outbox";
            case Telephony.Sms.MESSAGE_TYPE_FAILED:
                return "failed";
            case Telephony.Sms.MESSAGE_TYPE_QUEUED:
                return "queued";
            default:
                return "unknown";
        }
    }

    private JSONArray contactPhones(long contactId) {
        JSONArray phones = new JSONArray();
        String[] projection = new String[] {
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.TYPE,
                ContactsContract.CommonDataKinds.Phone.LABEL
        };
        String selection = ContactsContract.CommonDataKinds.Phone.CONTACT_ID + "=?";
        String[] selectionArgs = new String[] { Long.toString(contactId) };
        try (Cursor cursor = mContext.getContentResolver().query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI, projection, selection,
                selectionArgs, null)) {
            if (cursor == null) {
                return phones;
            }
            while (cursor.moveToNext() && phones.length() < 5) {
                phones.put(new JSONObject()
                        .put("number", stringAt(cursor, 0))
                        .put("type", ContactsContract.CommonDataKinds.Phone.getTypeLabel(
                                mContext.getResources(), cursor.getInt(1), stringAt(cursor, 2))
                                .toString()));
            }
        } catch (JSONException | RuntimeException ignored) {
        }
        return phones;
    }

    private JSONArray contactEmails(long contactId) {
        JSONArray emails = new JSONArray();
        String[] projection = new String[] {
                ContactsContract.CommonDataKinds.Email.ADDRESS,
                ContactsContract.CommonDataKinds.Email.TYPE,
                ContactsContract.CommonDataKinds.Email.LABEL
        };
        String selection = ContactsContract.CommonDataKinds.Email.CONTACT_ID + "=?";
        String[] selectionArgs = new String[] { Long.toString(contactId) };
        try (Cursor cursor = mContext.getContentResolver().query(
                ContactsContract.CommonDataKinds.Email.CONTENT_URI, projection, selection,
                selectionArgs, null)) {
            if (cursor == null) {
                return emails;
            }
            while (cursor.moveToNext() && emails.length() < 5) {
                emails.put(new JSONObject()
                        .put("address", stringAt(cursor, 0))
                        .put("type", ContactsContract.CommonDataKinds.Email.getTypeLabel(
                                mContext.getResources(), cursor.getInt(1), stringAt(cursor, 2))
                                .toString()));
            }
        } catch (JSONException | RuntimeException ignored) {
        }
        return emails;
    }

    private String memorySearch(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        JSONObject result = new JSONObject(mMemoryStore.searchJson(query, limit));
        result.put("status", "memory.search.results")
                .put("query", query)
                .put("limit", limit);
        return result.toString();
    }

    private String memorySave(JSONObject arguments) throws JSONException {
        String text = arguments.optString("text", "").trim();
        if (text.isEmpty()) {
            return error("empty_memory");
        }
        JSONObject evidence = new JSONObject()
                .put("source", "model_tool")
                .put("reason", arguments.optString("reason", ""))
                .put("type", arguments.optString("type", "fact"))
                .put("subject", arguments.optString("subject", "user"));
        long id = mMemoryStore.saveMemory(arguments.optString("type", "fact"),
                arguments.optString("subject", "user"), text,
                (float) arguments.optDouble("confidence", 0.8), evidence.toString());
        return new JSONObject()
                .put("status", id >= 0 ? "memory.saved" : "memory.save_failed")
                .put("memory_id", id)
                .put("text", text)
                .toString();
    }

    private String commitmentSearch(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        JSONObject result = new JSONObject(mCommitmentStore.searchJson(query, limit));
        result.put("status", "commitment.search.results")
                .put("query", query)
                .put("limit", limit);
        return result.toString();
    }

    private String commitmentCreate(JSONObject arguments) throws JSONException {
        String title = arguments.optString("title", "").trim();
        if (title.isEmpty()) {
            return error("empty_commitment");
        }
        JSONObject evidence = new JSONObject()
                .put("source", "model_tool")
                .put("reason", arguments.optString("reason", ""));
        long id = mCommitmentStore.createCommitment(title,
                arguments.optString("description", title),
                arguments.optString("trigger_type", "manual"),
                arguments.optJSONObject("trigger_spec") == null
                        ? "{}" : arguments.optJSONObject("trigger_spec").toString(),
                arguments.optLong("due_at", 0L),
                arguments.optLong("expires_at", 0L),
                (float) arguments.optDouble("confidence", 0.8),
                evidence.toString());
        return new JSONObject()
                .put("status", id >= 0 ? "commitment.created" : "commitment.create_failed")
                .put("commitment_id", id)
                .put("title", title)
                .toString();
    }

    private String notificationCommitmentCreate(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        List<ContextEvent> notifications = mContextIndexStore.notifications(query, 10);
        ContextEvent source = null;
        for (ContextEvent event : notifications) {
            if (!cleanNotificationField(event.title).isEmpty()
                    || !cleanNotificationField(event.text).isEmpty()) {
                source = event;
                break;
            }
        }
        if (source == null) {
            return error(query.trim().isEmpty()
                    ? "no_indexed_notifications" : "no_matching_notification");
        }
        String sourceTitle = cleanNotificationField(source.title);
        String sourceText = cleanNotificationField(source.text);
        String title = arguments.optString("title", "").trim();
        if (title.isEmpty()) {
            title = sourceTitle.isEmpty()
                    ? "Follow up on notification"
                    : "Follow up: " + sourceTitle;
        }
        String description = arguments.optString("description", "").trim();
        if (description.isEmpty()) {
            description = sourceText.isEmpty() ? sourceTitle : sourceText;
        }
        JSONObject trigger = new JSONObject()
                .put("source", "notification")
                .put("notification_key", source.sourceRecordId)
                .put("package", source.sourceApp)
                .put("observed_at", source.observedAtMillis);
        JSONObject evidence = new JSONObject()
                .put("source", "notification")
                .put("reason", arguments.optString("reason", ""))
                .put("notification", notificationEvidence(source));
        long id = mCommitmentStore.createCommitment(title,
                description,
                arguments.optLong("due_at", 0L) > 0 ? "time" : "manual",
                trigger.toString(),
                arguments.optLong("due_at", 0L),
                0L,
                0.75f,
                evidence.toString());
        return new JSONObject()
                .put("status", id >= 0 ? "notification.commitment_created"
                        : "notification.commitment_create_failed")
                .put("commitment_id", id)
                .put("title", title)
                .put("notification", notificationEvidence(source))
                .toString();
    }

    private String messageCommitmentCreate(JSONObject arguments) throws JSONException {
        if (!hasPermission(Manifest.permission.READ_SMS)) {
            return error("messages_permission_denied:read");
        }
        String query = arguments.optString("query", "").trim();
        long threadId = arguments.optLong("thread_id", 0L);
        JSONObject message = firstMatchingSms(query, threadId);
        if (message == null) {
            return error(query.isEmpty() && threadId <= 0
                    ? "no_sms_messages" : "no_matching_sms_message");
        }
        String address = message.optString("address", "");
        String body = message.optString("body", "");
        String title = arguments.optString("title", "").trim();
        if (title.isEmpty()) {
            title = address.isEmpty() ? "Follow up on message" : "Follow up: " + address;
        }
        String description = arguments.optString("description", "").trim();
        if (description.isEmpty()) {
            description = body.isEmpty() ? title : body;
        }
        JSONObject trigger = new JSONObject()
                .put("source", "message")
                .put("message_id", message.optLong("message_id", 0L))
                .put("thread_id", message.optLong("thread_id", 0L))
                .put("address", address)
                .put("date", message.optLong("date", 0L));
        JSONObject evidence = new JSONObject()
                .put("source", "message")
                .put("reason", arguments.optString("reason", ""))
                .put("message", messageEvidence(message));
        long id = mCommitmentStore.createCommitment(title,
                description,
                arguments.optLong("due_at", 0L) > 0 ? "time" : "manual",
                trigger.toString(),
                arguments.optLong("due_at", 0L),
                0L,
                0.75f,
                evidence.toString());
        return new JSONObject()
                .put("status", id >= 0 ? "message.commitment_created"
                        : "message.commitment_create_failed")
                .put("commitment_id", id)
                .put("title", title)
                .put("message", messageEvidence(message))
                .toString();
    }

    private String commitmentUpdateStatus(JSONObject arguments) throws JSONException {
        long id = arguments.optLong("commitment_id", -1L);
        String status = arguments.optString("status", "").trim();
        if (id <= 0 || status.isEmpty()) {
            return error("bad_commitment_update");
        }
        boolean updated = mCommitmentStore.updateStatus(id, status);
        return new JSONObject()
                .put("status", updated ? "commitment.updated" : "commitment.not_found")
                .put("commitment_id", id)
                .put("new_status", status)
                .toString();
    }

    private String watcherCreate(JSONObject arguments) throws JSONException {
        JSONObject normalized = normalizeWatcherArguments(arguments);
        String title = normalized.optString("title", "").trim();
        if (title.isEmpty()) {
            return error("empty_watcher");
        }
        JSONObject condition = normalized.optJSONObject("condition");
        JSONObject schedule = normalized.optJSONObject("schedule");
        JSONObject delivery = normalized.optJSONObject("delivery");
        long nextRunAt = normalized.optLong("next_run_at", 0L);
        if (nextRunAt <= 0 && schedule != null) {
            nextRunAt = schedule.optLong("next_run_at", 0L);
        }
        long id = mWatcherStore.createWatcher(
                normalized.optString("type", "time"),
                title,
                condition == null ? "{}" : condition.toString(),
                schedule == null ? "{}" : schedule.toString(),
                normalized.optString("session_target", ""),
                delivery == null ? "{\"surface\":\"notification\"}" : delivery.toString(),
                nextRunAt);
        if (id >= 0) {
            OpenPhoneWatcherScheduler.scheduleNext(mContext);
        }
        return new JSONObject()
                .put("status", id >= 0 ? "watcher.created" : "watcher.create_failed")
                .put("watcher_id", id)
                .put("title", title)
                .put("type", normalized.optString("type", "time"))
                .put("condition", condition == null ? new JSONObject() : condition)
                .put("delivery", delivery == null ? new JSONObject() : delivery)
                .put("next_run_at", nextRunAt)
                .toString();
    }

    private static JSONObject normalizeWatcherArguments(JSONObject arguments) throws JSONException {
        JSONObject out = new JSONObject(arguments == null ? "{}" : arguments.toString());
        JSONObject condition = out.optJSONObject("condition");
        if (condition == null) {
            condition = new JSONObject();
        }
        JSONObject schedule = out.optJSONObject("schedule");
        if (schedule == null) {
            schedule = new JSONObject();
        }
        JSONObject delivery = out.optJSONObject("delivery");
        if (delivery == null) {
            delivery = new JSONObject();
        }
        normalizeWatcherDeliveryShortcuts(out, delivery);

        String source = firstNonEmpty(out.optString("source", ""),
                condition.optString("source", ""));
        String url = firstNonEmpty(out.optString("url", ""),
                condition.optString("url", ""),
                condition.optString("uri", ""));
        String evaluator = firstNonEmpty(out.optString("evaluator", ""),
                condition.optString("evaluator", ""),
                condition.optString("operator", ""));
        String query = firstNonEmpty(out.optString("query", ""),
                out.optString("condition_text", ""),
                condition.optString("query", ""),
                condition.optString("condition_text", ""),
                condition.optString("text", ""),
                condition.optString("contains", ""),
                condition.optString("needle", ""));

        String type = firstNonEmpty(out.optString("type", ""), "time");
        if (!url.isEmpty()) {
            source = "web";
            type = "web_change";
            condition.put("url", normalizedUrl(url));
        } else if ("web".equals(source)) {
            type = "web_change";
        } else if ("notification".equals(source) || "notifications".equals(source)) {
            source = "notification";
            type = "notification";
        } else if ("message".equals(source) || "messages".equals(source)
                || "sms".equals(source) || "text".equals(source)) {
            source = "message";
            type = "message_reply";
        } else if ("call".equals(source) || "calls".equals(source) || "phone".equals(source)) {
            source = "call";
            type = "call_back";
        } else if ("time".equals(source)) {
            type = "time";
        }
        if ("message".equals(type) || "sms".equals(type) || "message_reply".equals(type)) {
            type = "message_reply";
            if (source.isEmpty()) {
                source = "message";
            }
        }
        if ("call".equals(type) || "calls".equals(type) || "call_back".equals(type)
                || "callback".equals(type)) {
            type = "call_back";
            if (source.isEmpty()) {
                source = "call";
            }
        }

        if (!source.isEmpty()) {
            condition.put("source", source);
        }
        if ("message_reply".equals(type)) {
            String address = firstNonEmpty(out.optString("address", ""),
                    out.optString("phone", ""),
                    out.optString("phone_number", ""),
                    out.optString("sender", ""),
                    out.optString("from", ""),
                    condition.optString("address", ""),
                    condition.optString("phone", ""),
                    condition.optString("phone_number", ""),
                    condition.optString("sender", ""),
                    condition.optString("from", ""));
            boolean matchAny = out.optBoolean("match_any", false)
                    || condition.optBoolean("match_any", false)
                    || isAnyNumberToken(address);
            if (!address.isEmpty() && !matchAny) {
                condition.put("address", address);
            }
            long threadId = firstPositive(out.optLong("thread_id", 0L),
                    condition.optLong("thread_id", 0L));
            if (threadId > 0) {
                condition.put("thread_id", threadId);
            }
            long baseline = firstPositive(condition.optLong("baseline_ms", 0L),
                    condition.optLong("since", 0L),
                    out.optLong("since", 0L));
            condition.put("baseline_ms",
                    baseline > 0 ? baseline : System.currentTimeMillis());
            long deadline = firstPositive(out.optLong("deadline_at", 0L),
                    out.optLong("due_at", 0L),
                    condition.optLong("deadline_at", 0L),
                    condition.optLong("due_at", 0L));
            if (deadline > 0) {
                condition.put("deadline_at", deadline);
            }
            String notifyOn = firstNonEmpty(out.optString("notify_on", ""),
                    condition.optString("notify_on", ""));
            if (!notifyOn.isEmpty()) {
                condition.put("notify_on", notifyOn.toLowerCase(Locale.US));
            }
            boolean hasReaction = hasWatcherReaction(delivery);
            if (matchAny || (address.isEmpty() && threadId <= 0 && hasReaction)) {
                condition.put("match_any", true);
            }
            if (hasReaction && condition.optBoolean("match_any", false)
                    && !condition.has("recurring")) {
                condition.put("recurring", true);
            }
        }
        if ("call_back".equals(type)) {
            String number = firstNonEmpty(out.optString("number", ""),
                    out.optString("address", ""),
                    out.optString("phone", ""),
                    out.optString("phone_number", ""),
                    condition.optString("number", ""),
                    condition.optString("address", ""),
                    condition.optString("phone", ""),
                    condition.optString("phone_number", ""));
            boolean matchAny = out.optBoolean("match_any", false)
                    || condition.optBoolean("match_any", false)
                    || isAnyNumberToken(number);
            if (!number.isEmpty()) {
                condition.put("number", number);
            }
            long baseline = firstPositive(condition.optLong("baseline_ms", 0L),
                    condition.optLong("since", 0L),
                    out.optLong("since", 0L));
            condition.put("baseline_ms",
                    baseline > 0 ? baseline : System.currentTimeMillis());
            long deadline = firstPositive(out.optLong("deadline_at", 0L),
                    out.optLong("due_at", 0L),
                    condition.optLong("deadline_at", 0L),
                    condition.optLong("due_at", 0L));
            if (deadline > 0) {
                condition.put("deadline_at", deadline);
            }
            String notifyOn = firstNonEmpty(out.optString("notify_on", ""),
                    condition.optString("notify_on", ""));
            if (!notifyOn.isEmpty()) {
                condition.put("notify_on", notifyOn.toLowerCase(Locale.US));
            }
            String direction = firstNonEmpty(out.optString("direction", ""),
                    condition.optString("direction", ""));
            if (!direction.isEmpty()) {
                condition.put("direction", direction.toLowerCase(Locale.US));
            }
            boolean hasReaction = hasWatcherReaction(delivery);
            if (matchAny || (number.isEmpty() && hasReaction)) {
                condition.put("match_any", true);
            }
            if (hasReaction && condition.optBoolean("match_any", false)
                    && !condition.has("recurring")) {
                condition.put("recurring", true);
            }
        }
        if (evaluator.isEmpty() && "web_change".equals(type)) {
            evaluator = query.isEmpty() ? "hash_change" : "text_contains";
        }
        if (!evaluator.isEmpty()) {
            condition.put("evaluator", normalizeWatcherEvaluator(evaluator));
        }
        if (!query.isEmpty()) {
            condition.put("query", query);
            condition.put("condition_text", query);
        }

        long intervalMs = firstPositive(out.optLong("interval_ms", 0L),
                out.optLong("interval_millis", 0L),
                condition.optLong("interval_ms", 0L),
                condition.optLong("interval_millis", 0L));
        if (intervalMs > 0) {
            condition.put("interval_ms", intervalMs);
            schedule.put("interval_ms", intervalMs);
        }

        long nextRunAt = firstPositive(out.optLong("next_run_at", 0L),
                schedule.optLong("next_run_at", 0L));
        if (nextRunAt <= 0
                && ("web_change".equals(type) || "message_reply".equals(type)
                        || "call_back".equals(type))) {
            nextRunAt = System.currentTimeMillis() + 15_000L;
            schedule.put("next_run_at", nextRunAt);
        }
        if (nextRunAt > 0) {
            out.put("next_run_at", nextRunAt);
        }

        out.put("type", type);
        out.put("condition", condition);
        out.put("schedule", schedule);
        out.put("delivery", delivery);
        return out;
    }

    private static void normalizeWatcherDeliveryShortcuts(JSONObject arguments,
            JSONObject delivery) throws JSONException {
        String tool = firstNonEmpty(arguments.optString("tool", ""),
                arguments.optString("action_tool", ""),
                arguments.optString("model_tool", ""),
                delivery.optString("tool", ""),
                delivery.optString("action_tool", ""),
                delivery.optString("model_tool", ""));
        String action = firstNonEmpty(arguments.optString("action", ""),
                arguments.optString("on_match_action", ""),
                delivery.optString("action", ""));
        if (tool.isEmpty() && !action.isEmpty() && !isPassiveDeliveryAction(action)
                && !isSendSmsDelivery(action)) {
            tool = action;
        }
        JSONObject toolArguments = arguments.optJSONObject("arguments");
        if (toolArguments == null) {
            toolArguments = arguments.optJSONObject("tool_arguments");
        }
        if (toolArguments != null && delivery.optJSONObject("arguments") == null) {
            delivery.put("arguments", toolArguments);
        }
        String prompt = firstNonEmpty(arguments.optString("prompt", ""),
                arguments.optString("task_goal", ""),
                arguments.optString("goal", ""),
                delivery.optString("prompt", ""),
                delivery.optString("task_goal", ""),
                delivery.optString("goal", ""),
                delivery.optString("task", ""));
        if (!prompt.isEmpty() && delivery.optString("prompt", "").trim().isEmpty()) {
            delivery.put("prompt", prompt);
        }

        String smsBody = firstNonEmpty(arguments.optString("sms_body", ""),
                arguments.optString("message_body", ""),
                arguments.optString("text_body", ""),
                delivery.optString("sms_body", ""),
                delivery.optString("message_body", ""),
                delivery.optString("body", ""));
        boolean legacySms = isSendSmsDelivery(action)
                || isSendSmsDelivery(delivery.optString("mode", ""))
                || !smsBody.isEmpty();
        if (tool.isEmpty() && legacySms) {
            tool = "messages_send";
            JSONObject legacyArguments = delivery.optJSONObject("arguments");
            if (legacyArguments == null) {
                legacyArguments = new JSONObject();
            }
            if (legacyArguments.optString("to", "").trim().isEmpty()) {
                legacyArguments.put("to", "{{event.number}}");
            }
            if (legacyArguments.optString("body", "").trim().isEmpty()
                    && !smsBody.isEmpty()) {
                legacyArguments.put("body", smsBody);
            }
            delivery.put("arguments", legacyArguments);
        }
        if (!tool.isEmpty()) {
            delivery.put("tool", tool);
        }
    }

    private static boolean hasWatcherReaction(JSONObject delivery) {
        if (delivery == null) {
            return false;
        }
        String tool = firstNonEmpty(delivery.optString("tool", ""),
                delivery.optString("action_tool", ""),
                delivery.optString("model_tool", ""));
        if (!tool.isEmpty()) {
            return true;
        }
        String prompt = firstNonEmpty(delivery.optString("prompt", ""),
                delivery.optString("task_goal", ""),
                delivery.optString("goal", ""),
                delivery.optString("task", ""));
        if (!prompt.isEmpty()) {
            return true;
        }
        String mode = delivery.optString("mode", "").trim().toLowerCase(Locale.US);
        return "tool".equals(mode) || "agent".equals(mode)
                || "agent_job".equals(mode) || "background_job".equals(mode);
    }

    private static boolean isPassiveDeliveryAction(String value) {
        String clean = value == null ? "" : value.trim().toLowerCase(Locale.US);
        return clean.isEmpty() || "notification".equals(clean) || "notify".equals(clean)
                || "alert".equals(clean) || "none".equals(clean) || "silent".equals(clean)
                || "tool".equals(clean) || "agent".equals(clean)
                || "agent_job".equals(clean) || "background_job".equals(clean);
    }

    private static String normalizeWatcherEvaluator(String evaluator) {
        String clean = evaluator == null ? "" : evaluator.trim().toLowerCase(Locale.US);
        if ("contains".equals(clean) || "text".equals(clean) || "text_match".equals(clean)) {
            return "text_contains";
        }
        if ("semantic".equals(clean) || "semantic_contains".equals(clean)) {
            return "semantic_match";
        }
        if ("change".equals(clean) || "hash".equals(clean)) {
            return "hash_change";
        }
        return clean;
    }

    private static String firstNonEmpty(String... values) {
        if (values == null) {
            return "";
        }
        for (String value : values) {
            if (value != null && !value.trim().isEmpty()) {
                return value.trim();
            }
        }
        return "";
    }

    private static long firstPositive(long... values) {
        if (values == null) {
            return 0L;
        }
        for (long value : values) {
            if (value > 0L) {
                return value;
            }
        }
        return 0L;
    }

    private static boolean isAnyNumberToken(String value) {
        String clean = value == null ? "" : value.trim().toLowerCase(Locale.US);
        return "*".equals(clean) || "any".equals(clean) || "all".equals(clean)
                || "anyone".equals(clean) || "everyone".equals(clean)
                || "everybody".equals(clean);
    }

    private static boolean isSendSmsDelivery(String value) {
        String clean = value == null ? "" : value.trim().toLowerCase(Locale.US);
        return "send_sms".equals(clean) || "sms".equals(clean)
                || "send_message".equals(clean) || "message".equals(clean);
    }

    private String watcherList(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        JSONObject result = new JSONObject(mWatcherStore.listJson(query, limit));
        result.put("status", "watcher.list.results")
                .put("query", query)
                .put("limit", limit);
        return result.toString();
    }

    private String watcherStop(JSONObject arguments) throws JSONException {
        long id = arguments.optLong("watcher_id", -1L);
        String scope = arguments.optString("scope", "").trim().toLowerCase(Locale.US);
        String query = arguments.optString("query", "").trim();
        boolean all = arguments.optBoolean("all", false) || "all".equals(scope);
        List<Long> targetIds = new ArrayList<>();
        if (id > 0) {
            targetIds.add(id);
        } else if (all) {
            for (WatcherRecord watcher : mWatcherStore.active(50)) {
                if (watcher != null && watcher.id > 0) {
                    targetIds.add(watcher.id);
                }
            }
        } else if (!query.isEmpty()) {
            for (WatcherRecord watcher : mWatcherStore.search(query, 50)) {
                if (watcher != null && watcher.id > 0) {
                    targetIds.add(watcher.id);
                }
            }
        } else {
            return error("bad_watcher_stop");
        }
        JSONArray stoppedIds = new JSONArray();
        int stopped = 0;
        for (Long watcherId : targetIds) {
            if (watcherId == null || watcherId <= 0) {
                continue;
            }
            if (mWatcherStore.stop(watcherId)) {
                stopped++;
                stoppedIds.put(watcherId);
            }
        }
        if (stopped > 0) {
            OpenPhoneWatcherScheduler.scheduleNext(mContext);
        }
        return new JSONObject()
                .put("status", stopped > 0 ? "watcher.stopped" : "watcher.not_found")
                .put("watcher_id", id > 0 ? id : JSONObject.NULL)
                .put("stopped_count", stopped)
                .put("stopped_watcher_ids", stoppedIds)
                .put("scope", all ? "all" : (query.isEmpty() ? "id" : "query"))
                .toString();
    }

    private String backgroundJobCreate(JSONObject arguments) throws JSONException {
        String title = arguments.optString("title", "").trim();
        String prompt = firstNonEmpty(arguments.optString("prompt", ""),
                arguments.optString("goal", ""),
                arguments.optString("task", ""));
        if (title.isEmpty()) {
            return error("empty_background_job");
        }
        if (prompt.isEmpty()) {
            return error("empty_background_job_prompt");
        }
        JSONObject schedule = arguments.optJSONObject("schedule");
        if (schedule == null) {
            schedule = new JSONObject();
        }
        long nextRunAt = firstPositive(arguments.optLong("run_at", 0L),
                arguments.optLong("next_run_at", 0L),
                arguments.optLong("due_at", 0L),
                schedule.optLong("run_at", 0L),
                schedule.optLong("next_run_at", 0L),
                schedule.optLong("due_at", 0L));
        if (nextRunAt <= 0) {
            nextRunAt = System.currentTimeMillis() + 15_000L;
        }
        schedule.put("next_run_at", nextRunAt);
        long intervalMs = firstPositive(arguments.optLong("interval_ms", 0L),
                arguments.optLong("interval_millis", 0L),
                schedule.optLong("interval_ms", 0L),
                schedule.optLong("interval_millis", 0L));
        if (intervalMs > 0) {
            schedule.put("interval_ms", intervalMs);
        }
        JSONObject payload = arguments.optJSONObject("payload");
        if (payload == null) {
            payload = new JSONObject();
        }
        JSONObject delivery = arguments.optJSONObject("delivery");
        if (delivery == null) {
            delivery = new JSONObject().put("mode", "notification");
        }
        String notificationText = firstNonEmpty(arguments.optString("notification_text", ""),
                arguments.optString("notification_message", ""),
                delivery.optString("notification_text", ""),
                delivery.optString("text", ""),
                delivery.optString("message", ""));
        if (!notificationText.isEmpty()) {
            delivery.put("notification_text", notificationText);
        }
        long id = mAgentJobStore.createJob(
                arguments.optString("type", "agent_turn"),
                title,
                prompt,
                payload.toString(),
                schedule.toString(),
                arguments.optString("session_target", "main"),
                delivery.toString(),
                nextRunAt);
        if (id >= 0) {
            OpenPhoneAgentJobScheduler.scheduleNext(mContext);
        }
        return new JSONObject()
                .put("status", id >= 0 ? "background_job.created"
                        : "background_job.create_failed")
                .put("job_id", id)
                .put("title", title)
                .put("next_run_at", nextRunAt)
                .toString();
    }

    private String backgroundJobList(JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "");
        int limit = Math.max(1, Math.min(arguments.optInt("limit", 8), 20));
        JSONObject result = new JSONObject(mAgentJobStore.listJson(query, limit));
        result.put("status", "background_job.list.results")
                .put("query", query)
                .put("limit", limit);
        return result.toString();
    }

    private String backgroundJobStop(JSONObject arguments) throws JSONException {
        long id = arguments.optLong("job_id", -1L);
        if (id <= 0) {
            return error("bad_background_job_stop");
        }
        boolean stopped = mAgentJobStore.stop(id);
        OpenPhoneAgentJobScheduler.cancelJob(id);
        OpenPhoneAgentJobScheduler.scheduleNext(mContext);
        return new JSONObject()
                .put("status", stopped ? "background_job.stopped"
                        : "background_job.not_found")
                .put("job_id", id)
                .toString();
    }

    private String getScreen(String taskId, JSONObject arguments) throws JSONException {
        JSONObject uiTree = accessibilitySnapshot();
        if (shouldBlockScreenshot(arguments, uiTree)) {
            return blockedScreenResult("sensitive_screen_screenshot_blocked", uiTree);
        }
        String screen = mAgentManager.getScreen(taskId, arguments.toString());
        return enrichScreenResult(screen, arguments, uiTree);
    }

    private String localScreenUnderstanding(String taskId, JSONObject arguments)
            throws JSONException {
        int maxVisibleText = Math.max(0, Math.min(arguments.optInt("max_visible_text", 40), 80));
        int maxElements = Math.max(0,
                Math.min(arguments.optInt("max_interactive_elements", 60), 120));
        long timeoutMs = Math.max(250L, Math.min(arguments.optLong("timeout_ms", 2500L), 5000L));
        long startedAtMs = System.currentTimeMillis();
        JSONObject screenArgs = new JSONObject()
                .put("include_screenshot", false)
                .put("include_activity", true)
                .put("include_ui_tree", true)
                .put("timeout_ms", timeoutMs)
                .put("reason", arguments.optString("reason", ""));
        JSONObject screen = parseObject(getScreen(taskId, screenArgs));
        JSONObject context = screen.optJSONObject("context");
        JSONObject uiTree = screen.optJSONObject("ui_tree");
        JSONArray visibleText = firstArray(screen.optJSONArray("visible_text"),
                uiTree == null ? null : uiTree.optJSONArray("visible_text"),
                context == null ? null : context.optJSONArray("visible_text"));
        JSONArray elements = firstArray(screen.optJSONArray("interactive_elements"),
                uiTree == null ? null : uiTree.optJSONArray("interactive_elements"),
                context == null ? null : context.optJSONArray("interactive_elements"));
        JSONArray riskFlags = firstArray(screen.optJSONArray("risk_flags"),
                uiTree == null ? null : uiTree.optJSONArray("risk_flags"),
                context == null ? null : context.optJSONArray("risk_flags"));
        JSONObject result = new JSONObject()
                .put("status", "local_screen_understanding.ok")
                .put("source_status", screen.optString("status", ""))
                .put("foreground_app", firstNonEmpty(
                        screen.optString("foreground_app", ""),
                        context == null ? "" : context.optString("foreground_app", ""),
                        uiTree == null ? "" : uiTree.optString("foreground_app", "")))
                .put("activity", firstNonEmpty(
                        screen.optString("activity", ""),
                        context == null ? "" : context.optString("activity", ""),
                        uiTree == null ? "" : uiTree.optString("activity", "")))
                .put("visible_text", limitedArray(visibleText, maxVisibleText))
                .put("interactive_elements", limitedArray(elements, maxElements))
                .put("risk_flags", riskFlags == null ? new JSONArray() : riskFlags)
                .put("screen_capture_included", false)
                .put("truncated", new JSONObject()
                        .put("visible_text", visibleText != null
                                && visibleText.length() > maxVisibleText)
                        .put("interactive_elements", elements != null
                                && elements.length() > maxElements))
                .put("limits", new JSONObject()
                        .put("max_visible_text", maxVisibleText)
                        .put("max_interactive_elements", maxElements)
                        .put("timeout_ms", timeoutMs))
                .put("compute", new JSONObject()
                        .put("tool", "local_screen_understanding")
                        .put("local", true)
                        .put("bounded", true)
                        .put("elapsed_ms", Math.max(0L,
                                System.currentTimeMillis() - startedAtMs)));
        return result.toString();
    }

    private String watchScreen(String taskId, JSONObject arguments) throws JSONException {
        long durationMs = Math.max(500, Math.min(arguments.optLong("duration_ms", 1500), 5000));
        int fps = Math.max(1, Math.min(arguments.optInt("fps", 1), 5));
        JSONObject boundedArguments = new JSONObject(arguments.toString())
                .put("duration_ms", durationMs)
                .put("fps", fps);
        JSONObject uiTree = accessibilitySnapshot();
        if (shouldBlockScreenshot(boundedArguments, uiTree)) {
            return blockedScreenResult("sensitive_screen_watch_blocked", uiTree);
        }
        String screen = mAgentManager.watchScreen(taskId, boundedArguments.toString());
        return enrichScreenResult(screen, boundedArguments, uiTree);
    }

    private String enrichScreenResult(String screen, JSONObject arguments, JSONObject uiTree)
            throws JSONException {
        if (!arguments.optBoolean("include_ui_tree", false)) {
            return screen;
        }
        JSONObject screenJson = new JSONObject(screen);
        screenJson.put("ui_tree", uiTree);
        JSONObject context = screenJson.optJSONObject("context");
        JSONArray frameworkVisibleText = context == null
                ? null : context.optJSONArray("visible_text");
        JSONArray frameworkElements = context == null
                ? null : context.optJSONArray("interactive_elements");
        JSONArray visibleText = nonEmptyArray(uiTree.optJSONArray("visible_text"))
                ? uiTree.optJSONArray("visible_text") : frameworkVisibleText;
        if (visibleText != null) {
            screenJson.put("visible_text", visibleText);
        }
        JSONArray elements = nonEmptyArray(uiTree.optJSONArray("interactive_elements"))
                ? uiTree.optJSONArray("interactive_elements") : frameworkElements;
        if (elements != null) {
            screenJson.put("interactive_elements", elements);
        }
        mLastScreenJson = new JSONObject(screenJson.toString());
        return screenJson.toString();
    }

    private static boolean nonEmptyArray(JSONArray array) {
        return array != null && array.length() > 0;
    }

    private static JSONArray firstArray(JSONArray first, JSONArray second, JSONArray third) {
        if (nonEmptyArray(first)) {
            return first;
        }
        if (nonEmptyArray(second)) {
            return second;
        }
        return third;
    }

    private static JSONArray limitedArray(JSONArray source, int limit) {
        JSONArray output = new JSONArray();
        if (source == null || limit <= 0) {
            return output;
        }
        for (int i = 0; i < source.length() && output.length() < limit; i++) {
            Object value = source.opt(i);
            if (value != null) {
                output.put(value);
            }
        }
        return output;
    }

    private static String firstNonEmpty(String first, String second, String third) {
        if (first != null && !first.trim().isEmpty()) {
            return first;
        }
        if (second != null && !second.trim().isEmpty()) {
            return second;
        }
        return third == null ? "" : third;
    }

    private static JSONObject parseObject(String raw) {
        try {
            return new JSONObject(raw == null || raw.trim().isEmpty() ? "{}" : raw);
        } catch (JSONException e) {
            JSONObject object = new JSONObject();
            try {
                object.put("status", "error")
                        .put("reason", "json_parse_failed")
                        .put("raw", raw == null ? "" : raw);
            } catch (JSONException ignored) {
            }
            return object;
        }
    }

    private static JSONObject accessibilitySnapshot() throws JSONException {
        return new JSONObject(OpenPhoneAccessibilityService.snapshotJson());
    }

    private boolean shouldBlockScreenshot(JSONObject arguments, JSONObject uiTree) {
        return arguments.optBoolean("include_screenshot", false)
                && !fullYoloMode()
                && hasSensitiveScreenFlag(uiTree);
    }

    private boolean fullYoloMode() {
        try {
            return "yolo".equals(Settings.Secure.getString(mContext.getContentResolver(),
                    SECURE_AUTONOMY_MODE));
        } catch (RuntimeException e) {
            return false;
        }
    }

    private static boolean hasSensitiveScreenFlag(JSONObject uiTree) {
        JSONArray flags = uiTree.optJSONArray("risk_flags");
        if (flags == null) {
            return false;
        }
        for (int i = 0; i < flags.length(); i++) {
            String flag = flags.optString(i);
            if ("sensitive_input_visible".equals(flag)
                    || "account_or_payment_hint_visible".equals(flag)) {
                return true;
            }
        }
        return false;
    }

    private static String blockedScreenResult(String reason, JSONObject uiTree) throws JSONException {
        return new JSONObject()
                .put("status", "screen.blocked")
                .put("reason", reason)
                .put("screen_capture_included", false)
                .put("ui_tree", uiTree)
                .put("risk_flags", uiTree.optJSONArray("risk_flags") == null
                        ? new JSONArray() : uiTree.optJSONArray("risk_flags"))
                .toString();
    }

    private static String waitFor(long durationMs, String reason) throws JSONException {
        long boundedDurationMs = Math.max(250, Math.min(durationMs, 5000));
        try {
            Thread.sleep(boundedDurationMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return error("interrupted");
        }
        return new JSONObject()
                .put("status", "waited")
                .put("duration_ms", boundedDurationMs)
                .put("reason", reason == null ? "" : reason)
                .toString();
    }

    private static String normalizedUrl(String url) throws JSONException {
        if (url == null || url.trim().isEmpty()) {
            throw new JSONException("missing_url");
        }

        String normalizedUrl = url.trim();
        if (!normalizedUrl.startsWith("http://") && !normalizedUrl.startsWith("https://")) {
            normalizedUrl = "https://" + normalizedUrl;
        }
        return normalizedUrl;
    }

    private String browserFetchPage(JSONObject arguments) throws JSONException {
        String url = normalizedUrl(arguments.optString("url"));
        int maxChars = Math.max(500, Math.min(arguments.optInt("max_chars", 4000), 12000));
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(url).openConnection();
            connection.setInstanceFollowRedirects(true);
            connection.setConnectTimeout(8000);
            connection.setReadTimeout(10000);
            connection.setRequestProperty("User-Agent", "OpenPhoneAssistant/1.0");
            int statusCode = connection.getResponseCode();
            String contentType = connection.getContentType();
            byte[] bytes = readBounded(connection, 512 * 1024);
            String html = new String(bytes, StandardCharsets.UTF_8);
            String finalUrl = connection.getURL() == null ? url
                    : connection.getURL().toString();
            String title = extractTitle(html);
            String fullText = extractReadableText(html, Integer.MAX_VALUE);
            String text = fullText.length() > maxChars
                    ? fullText.substring(0, maxChars).trim() : fullText;
            return new JSONObject()
                    .put("status", "browser.page_fetched")
                    .put("url", url)
                    .put("final_url", finalUrl)
                    .put("http_status", statusCode)
                    .put("content_type", contentType == null ? "" : contentType)
                    .put("title", title)
                    .put("text", text)
                    .put("headings", extractHeadings(html))
                    .put("links", extractLinks(html, finalUrl))
                    .put("truncated", fullText.length() > maxChars)
                    .toString();
        } catch (RuntimeException e) {
            return error("browser_fetch_failed:" + e.getClass().getSimpleName());
        } catch (java.io.IOException e) {
            return error("browser_fetch_failed:" + e.getClass().getSimpleName());
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private String browserSearch(String taskId, JSONObject arguments) throws JSONException {
        String query = arguments.optString("query", "").trim();
        if (query.isEmpty()) {
            return error("empty_browser_search_query");
        }
        String engine = arguments.optString("engine", "duckduckgo").trim().toLowerCase(Locale.US);
        Uri.Builder builder;
        if ("google".equals(engine)) {
            builder = new Uri.Builder()
                    .scheme("https")
                    .authority("www.google.com")
                    .path("search")
                    .appendQueryParameter("q", query);
        } else {
            engine = "duckduckgo";
            builder = new Uri.Builder()
                    .scheme("https")
                    .authority("duckduckgo.com")
                    .path("/")
                    .appendQueryParameter("q", query);
        }
        String url = builder.build().toString();
        return mAgentManager.executeAction(taskId, action("open_url")
                .put("url", url)
                .put("search_query", query)
                .put("search_engine", engine)
                .put("reason", arguments.optString("reason")).toString());
    }

    private static byte[] readBounded(HttpURLConnection connection, int maxBytes)
            throws java.io.IOException {
        try (BufferedInputStream input = new BufferedInputStream(
                connection.getInputStream());
                ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int total = 0;
            int count;
            while ((count = input.read(buffer)) != -1 && total < maxBytes) {
                int allowed = Math.min(count, maxBytes - total);
                output.write(buffer, 0, allowed);
                total += allowed;
            }
            return output.toByteArray();
        }
    }

    private static String extractTitle(String html) {
        if (html == null) {
            return "";
        }
        java.util.regex.Matcher matcher = java.util.regex.Pattern
                .compile("(?is)<title[^>]*>(.*?)</title>")
                .matcher(html);
        if (!matcher.find()) {
            return "";
        }
        return decodeHtmlEntities(collapseWhitespace(matcher.group(1))).trim();
    }

    private static String extractReadableText(String html, int maxChars) {
        if (html == null || html.isEmpty()) {
            return "";
        }
        String text = html
                .replaceAll("(?is)<script[^>]*>.*?</script>", " ")
                .replaceAll("(?is)<style[^>]*>.*?</style>", " ")
                .replaceAll("(?is)<noscript[^>]*>.*?</noscript>", " ")
                .replaceAll("(?is)<[^>]+>", " ");
        text = decodeHtmlEntities(collapseWhitespace(text)).trim();
        if (text.length() > maxChars) {
            return text.substring(0, maxChars).trim();
        }
        return text;
    }

    private static JSONArray extractHeadings(String html) {
        JSONArray headings = new JSONArray();
        if (html == null || html.isEmpty()) {
            return headings;
        }
        java.util.regex.Matcher matcher = java.util.regex.Pattern
                .compile("(?is)<h([1-4])[^>]*>(.*?)</h\\1>")
                .matcher(html);
        while (matcher.find() && headings.length() < 24) {
            String text = decodeHtmlEntities(collapseWhitespace(
                    matcher.group(2).replaceAll("(?is)<[^>]+>", " "))).trim();
            if (text.isEmpty()) {
                continue;
            }
            try {
                headings.put(new JSONObject()
                        .put("level", Integer.parseInt(matcher.group(1)))
                        .put("text", text.length() > 160 ? text.substring(0, 160) : text));
            } catch (JSONException ignored) {
                // skip malformed heading
            }
        }
        return headings;
    }

    private static JSONArray extractLinks(String html, String baseUrl) {
        JSONArray links = new JSONArray();
        if (html == null || html.isEmpty()) {
            return links;
        }
        java.net.URL base = null;
        try {
            base = new java.net.URL(baseUrl);
        } catch (java.net.MalformedURLException ignored) {
            // fall back to absolute links only
        }
        java.util.HashSet<String> seen = new java.util.HashSet<>();
        java.util.regex.Matcher matcher = java.util.regex.Pattern
                .compile("(?is)<a\\b[^>]*?href=[\"']([^\"'#]+)[\"'][^>]*>(.*?)</a>")
                .matcher(html);
        while (matcher.find() && links.length() < 40) {
            String href = matcher.group(1).trim();
            String lowered = href.toLowerCase(Locale.US);
            if (lowered.startsWith("javascript:") || lowered.startsWith("mailto:")
                    || lowered.startsWith("tel:") || lowered.startsWith("data:")) {
                continue;
            }
            String resolved = href;
            if (!lowered.startsWith("http://") && !lowered.startsWith("https://")) {
                if (base == null) {
                    continue;
                }
                try {
                    resolved = new java.net.URL(base, href).toString();
                } catch (java.net.MalformedURLException e) {
                    continue;
                }
            }
            String text = decodeHtmlEntities(collapseWhitespace(
                    matcher.group(2).replaceAll("(?is)<[^>]+>", " "))).trim();
            if (text.isEmpty() || !seen.add(resolved)) {
                continue;
            }
            try {
                links.put(new JSONObject()
                        .put("text", text.length() > 120 ? text.substring(0, 120) : text)
                        .put("url", resolved));
            } catch (JSONException ignored) {
                // skip malformed link
            }
        }
        return links;
    }

    private static String collapseWhitespace(String text) {
        return text == null ? "" : text.replaceAll("\\s+", " ");
    }

    private static String decodeHtmlEntities(String text) {
        if (text == null || text.isEmpty()) {
            return "";
        }
        return text.replace("&nbsp;", " ")
                .replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&#39;", "'")
                .replace("&apos;", "'");
    }

    private String pressKey(String taskId, JSONObject arguments) throws JSONException {
        String key = arguments.optString("key", "back").trim().toLowerCase();
        String reason = arguments.optString("reason");
        if ("enter".equals(key) || "search".equals(key) || "go".equals(key)
                || "done".equals(key)) {
            return mAgentManager.executeAction(taskId, action("tap")
                    .put("target", point(930, 2360))
                    .put("reason", reason).toString());
        }
        return mAgentManager.executeAction(taskId, action(key).put("reason", reason).toString());
    }

    private static JSONObject action(String type) throws JSONException {
        return new JSONObject().put("type", type);
    }

    private static JSONObject point(double x, double y) throws JSONException {
        return new JSONObject().put("x", x).put("y", y);
    }

    private JSONObject elementCenter(JSONObject arguments) throws JSONException {
        String elementId = arguments.optString("element_id", "").trim();
        if (elementId.isEmpty()) {
            throw new JSONException("missing_element_id");
        }
        JSONObject snapshot = accessibilitySnapshot();
        JSONObject center = centerFromElements(snapshot.optJSONArray("interactive_elements"),
                elementId);
        if (center != null) {
            return center;
        }
        JSONObject lastScreen = mLastScreenJson;
        center = centerFromElements(lastScreen == null
                ? null : lastScreen.optJSONArray("interactive_elements"), elementId);
        if (center != null) {
            return center;
        }
        JSONObject context = lastScreen == null ? null : lastScreen.optJSONObject("context");
        center = centerFromElements(context == null
                ? null : context.optJSONArray("interactive_elements"), elementId);
        if (center != null) {
            return center;
        }
        throw new JSONException("element_not_found:" + elementId);
    }

    private static JSONObject centerFromElements(JSONArray elements, String elementId)
            throws JSONException {
        if (elements == null) {
            return null;
        }
        for (int i = 0; i < elements.length(); i++) {
            JSONObject element = elements.optJSONObject(i);
            if (element == null || !elementId.equals(element.optString("id"))) {
                continue;
            }
            if (!element.optBoolean("enabled", true)) {
                throw new JSONException("element_disabled:" + elementId);
            }
            JSONArray bounds = element.optJSONArray("bounds");
            if (bounds == null || bounds.length() < 4) {
                throw new JSONException("element_bounds_unavailable:" + elementId);
            }
            double left = bounds.optDouble(0);
            double top = bounds.optDouble(1);
            double right = bounds.optDouble(2);
            double bottom = bounds.optDouble(3);
            if (right <= left || bottom <= top) {
                throw new JSONException("element_bounds_invalid:" + elementId);
            }
            return point((left + right) / 2.0, (top + bottom) / 2.0);
        }
        return null;
    }

    private String resolvePackageOrLabel(String packageOrLabel) {
        if (packageOrLabel == null || packageOrLabel.trim().isEmpty()) {
            return "";
        }
        String value = packageOrLabel.trim();
        if (value.indexOf('.') >= 0
                && mContext.getPackageManager().getLaunchIntentForPackage(value) != null) {
            return value;
        }
        String packageName = launchablePackageForLabel(value);
        return packageName.isEmpty() ? packageName(value) : packageName;
    }

    private String launchablePackageForLabel(String labelOrPackage) {
        String query = labelOrPackage == null ? "" : labelOrPackage.trim().toLowerCase(Locale.US);
        if (query.isEmpty()) {
            return "";
        }
        PackageManager packageManager = mContext.getPackageManager();
        Intent launcherIntent = new Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> launchables = packageManager.queryIntentActivities(launcherIntent, 0);
        String containsMatch = "";
        for (ResolveInfo resolveInfo : launchables) {
            if (resolveInfo == null || resolveInfo.activityInfo == null) {
                continue;
            }
            String packageName = resolveInfo.activityInfo.packageName == null
                    ? "" : resolveInfo.activityInfo.packageName;
            CharSequence labelSeq = resolveInfo.loadLabel(packageManager);
            String label = labelSeq == null ? packageName : labelSeq.toString();
            String normalizedLabel = label.toLowerCase(Locale.US);
            String normalizedPackage = packageName.toLowerCase(Locale.US);
            if (query.equals(normalizedLabel) || query.equals(normalizedPackage)) {
                return packageName;
            }
            if (containsMatch.isEmpty() && normalizedLabel.contains(query)) {
                containsMatch = packageName;
            } else if (containsMatch.isEmpty() && query.indexOf('.') >= 0
                    && normalizedPackage.contains(query)) {
                containsMatch = packageName;
            }
        }
        return containsMatch;
    }

    private static String packageName(String packageOrLabel) {
        if (packageOrLabel == null) {
            return "";
        }
        String value = packageOrLabel.trim();
        if (value.indexOf('.') >= 0) {
            return value;
        }
        if ("settings".equalsIgnoreCase(value)) {
            return "com.android.settings";
        }
        if ("browser".equalsIgnoreCase(value) || "web".equalsIgnoreCase(value)
                || "jelly".equalsIgnoreCase(value)) {
            return "org.lineageos.jelly";
        }
        if ("play store".equalsIgnoreCase(value) || "google play".equalsIgnoreCase(value)
                || "google play store".equalsIgnoreCase(value)) {
            return "com.android.vending";
        }
        if ("twitter".equalsIgnoreCase(value) || "x".equalsIgnoreCase(value)) {
            return "com.twitter.android";
        }
        if ("assistant".equalsIgnoreCase(value) || "openphone".equalsIgnoreCase(value)) {
            return "org.openphone.assistant";
        }
        return value;
    }

    private static String cleanNotificationField(String value) {
        String clean = value == null ? "" : value.trim();
        while (clean.contains("  ")) {
            clean = clean.replace("  ", " ");
        }
        if (clean.length() > 120) {
            clean = clean.substring(0, 120);
        }
        return clean;
    }

    private static JSONObject notificationEvidence(ContextEvent event) throws JSONException {
        return new JSONObject()
                .put("id", event.id)
                .put("source_type", event.sourceType)
                .put("source_app", event.sourceApp)
                .put("source_record_id", event.sourceRecordId)
                .put("observed_at", event.observedAtMillis)
                .put("title", cleanNotificationField(event.title))
                .put("text", cleanNotificationField(event.text));
    }

    private static JSONObject messageEvidence(JSONObject message) throws JSONException {
        return new JSONObject()
                .put("message_id", message.optLong("message_id", 0L))
                .put("thread_id", message.optLong("thread_id", 0L))
                .put("address", message.optString("address", ""))
                .put("body", message.optString("body", ""))
                .put("date", message.optLong("date", 0L))
                .put("type", message.optString("type", ""))
                .put("read", message.optBoolean("read", false));
    }

    private static void collectConfirmationCodes(JSONArray out, String source,
            JSONArray rows, String field) throws JSONException {
        if (rows == null || out.length() >= 8) {
            return;
        }
        Pattern pattern = Pattern.compile(
                "(?i)(?:code|confirmation|confirm|pin|otp|verification)[^A-Z0-9]{0,12}"
                        + "([A-Z0-9][A-Z0-9-]{3,11})");
        for (int i = 0; i < rows.length() && out.length() < 8; i++) {
            JSONObject row = rows.optJSONObject(i);
            if (row == null) {
                continue;
            }
            String text = row.optString(field, "");
            if (text.isEmpty()) {
                continue;
            }
            Matcher matcher = pattern.matcher(text);
            while (matcher.find() && out.length() < 8) {
                String code = matcher.group(1).replace("-", "").trim();
                if (code.length() < 4) {
                    continue;
                }
                out.put(new JSONObject()
                        .put("source", source)
                        .put("field", field)
                        .put("code", code)
                        .put("text", text)
                        .put("row", row));
            }
        }
    }

    private static final class NotificationGroup {
        final String app;
        final String title;
        int count;
        long latestAt;
        String sampleText = "";

        NotificationGroup(String app, String title) {
            this.app = app == null ? "" : app;
            this.title = title == null ? "" : title;
        }

        JSONObject toJson() throws JSONException {
            return new JSONObject()
                    .put("app", app)
                    .put("title", title)
                    .put("sample_text", sampleText)
                    .put("count", count)
                    .put("latest_at", latestAt);
        }
    }

    private static final class MessageThreadGroup {
        final long threadId;
        final String address;
        final JSONArray samples = new JSONArray();
        int count;
        int inboxCount;
        int sentCount;
        int unreadCount;
        long latestAt;

        MessageThreadGroup(long threadId, String address) {
            this.threadId = threadId;
            this.address = address == null ? "" : address;
        }

        JSONObject toJson() throws JSONException {
            return new JSONObject()
                    .put("thread_id", threadId)
                    .put("address", address)
                    .put("count", count)
                    .put("inbox_count", inboxCount)
                    .put("sent_count", sentCount)
                    .put("unread_count", unreadCount)
                    .put("latest_at", latestAt)
                    .put("sample_messages", samples);
        }
    }

    private static String error(String reason) {
        try {
            return new JSONObject().put("status", "error").put("reason", reason).toString();
        } catch (JSONException e) {
            return "{\"status\":\"error\"}";
        }
    }

    private static String status(String status, String detail) {
        try {
            return new JSONObject().put("status", status).put("detail", detail).toString();
        } catch (JSONException e) {
            return "{\"status\":\"" + status + "\"}";
        }
    }
}
