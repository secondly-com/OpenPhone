package org.openphone.assistant.watchers;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.openphone.OpenPhoneAgentManager;
import android.os.UserManager;
import android.provider.Telephony;
import android.telephony.PhoneNumberUtils;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.OpenPhoneNotificationController;
import org.openphone.assistant.PointerOverlayController;
import org.openphone.assistant.agent.FrameworkToolExecutor;
import org.openphone.assistant.commitments.CommitmentRecord;
import org.openphone.assistant.commitments.CommitmentStore;
import org.openphone.assistant.jobs.AgentJobStore;
import org.openphone.assistant.jobs.OpenPhoneAgentJobScheduler;
import org.openphone.assistant.model.ModelEndpointConfig;
import org.openphone.assistant.model.OpenAiResponsesAgentAdapter;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.List;

public final class OpenPhoneWatcherScheduler {
    private static final String TAG = "OpenPhoneWatcher";
    public static final String ACTION_CHECK =
            "org.openphone.assistant.action.CHECK_WATCHERS";
    public static final String ACTION_COMPLETE_COMMITMENT =
            "org.openphone.assistant.action.COMPLETE_COMMITMENT";
    public static final String ACTION_SNOOZE_COMMITMENT =
            "org.openphone.assistant.action.SNOOZE_COMMITMENT";
    public static final String ACTION_DISMISS_COMMITMENT =
            "org.openphone.assistant.action.DISMISS_COMMITMENT";
    public static final String EXTRA_COMMITMENT_ID =
            "org.openphone.assistant.extra.COMMITMENT_ID";
    private static final long MIN_DELAY_MILLIS = 15_000L;
    private static final long SNOOZE_MILLIS = 60L * 60L * 1000L;
    private static final long STUCK_TIMEOUT_MILLIS = 10L * 60L * 1000L;
    private static final long DEFAULT_WEB_INTERVAL_MILLIS = 15L * 60L * 1000L;
    private static final long DEFAULT_MESSAGE_INTERVAL_MILLIS = 5L * 60L * 1000L;
    private static final long USER_UNLOCK_RETRY_MILLIS = 60L * 1000L;
    private static final int MAX_WEB_BYTES = 512 * 1024;
    private static final int MAX_JUDGMENT_CHARS = 24_000;
    private static final int MAX_DUE_PER_CHECK = 8;

    private OpenPhoneWatcherScheduler() {}

    public static void checkNow(Context context) {
        if (context == null) {
            return;
        }
        if (!isUserUnlocked(context)) {
            scheduleUserUnlockRetry(context);
            return;
        }
        CommitmentStore store = new CommitmentStore(context);
        WatcherStore watcherStore = new WatcherStore(context);
        long now = System.currentTimeMillis();
        int repaired = watcherStore.repairStuck(now - STUCK_TIMEOUT_MILLIS, now);
        if (repaired > 0) {
            Log.w(TAG, "Repaired stuck watchers: " + repaired);
        }
        List<CommitmentRecord> due = store.due(now, MAX_DUE_PER_CHECK);
        for (CommitmentRecord commitment : due) {
            if (store.updateStatus(commitment.id, "fired")) {
                OpenPhoneNotificationController.showCommitmentDue(context, commitment);
            }
        }
        for (WatcherRecord watcher : watcherStore.due(now, MAX_DUE_PER_CHECK)) {
            fireWatcher(context, watcherStore, watcher, now);
        }
        scheduleNext(context, store, watcherStore);
    }

    public static void scheduleNext(Context context) {
        if (context == null) {
            return;
        }
        if (!isUserUnlocked(context)) {
            scheduleUserUnlockRetry(context);
            return;
        }
        scheduleNext(context, new CommitmentStore(context), new WatcherStore(context));
    }

    public static void completeCommitment(Context context, long id) {
        updateAndReschedule(context, id, "completed");
    }

    public static void dismissCommitment(Context context, long id) {
        if (context == null || id <= 0) {
            return;
        }
        CommitmentStore store = new CommitmentStore(context);
        store.dismiss(id);
        OpenPhoneNotificationController.cancelCommitment(context, id);
        scheduleNext(context, store, new WatcherStore(context));
    }

    public static void snoozeCommitment(Context context, long id) {
        if (context == null || id <= 0) {
            return;
        }
        CommitmentStore store = new CommitmentStore(context);
        store.snooze(id, System.currentTimeMillis() + SNOOZE_MILLIS);
        OpenPhoneNotificationController.cancelCommitment(context, id);
        scheduleNext(context, store, new WatcherStore(context));
    }

    private static void updateAndReschedule(Context context, long id, String status) {
        if (context == null || id <= 0) {
            return;
        }
        CommitmentStore store = new CommitmentStore(context);
        store.updateStatus(id, status);
        OpenPhoneNotificationController.cancelCommitment(context, id);
        scheduleNext(context, store, new WatcherStore(context));
    }

    public static void stopWatcher(Context context, long id) {
        if (context == null || id <= 0) {
            return;
        }
        WatcherStore watcherStore = new WatcherStore(context);
        watcherStore.stop(id);
        scheduleNext(context, new CommitmentStore(context), watcherStore);
    }

    public static void onNotificationPosted(Context context, String packageName, String title,
            String text, String notificationKey, long observedAtMillis) {
        if (context == null) {
            return;
        }
        WatcherStore watcherStore = new WatcherStore(context);
        long now = System.currentTimeMillis();
        for (WatcherRecord watcher : watcherStore.activeByType("notification", MAX_DUE_PER_CHECK)) {
            if (!notificationMatches(watcher, packageName, title, text)) {
                continue;
            }
            if (!watcherStore.markRunning(watcher.id, now)) {
                continue;
            }
            String resultHash = "notification:"
                    + safeHashPart(packageName) + ":"
                    + safeHashPart(notificationKey) + ":"
                    + observedAtMillis;
            JSONObject event = notificationEvent(watcher, packageName, title, text,
                    notificationKey, observedAtMillis);
            ReactionResult reaction = runWatcherReaction(context, watcher, event);
            if (!reaction.success) {
                failWatcher(context, watcherStore, watcher, now, reaction.error);
                continue;
            }
            watcherStore.markFired(watcher.id, resultHash, now);
            if (reaction.shouldNotify) {
                OpenPhoneNotificationController.showWatcherFired(context, watcher);
            }
        }
        scheduleNext(context, new CommitmentStore(context), watcherStore);
    }

    private static void fireWatcher(Context context, WatcherStore store,
            WatcherRecord watcher, long now) {
        if (!store.markRunning(watcher.id, now)) {
            return;
        }
        if ("web_change".equals(watcher.type)) {
            runWebChangeWatcher(context.getApplicationContext(), watcher);
            return;
        }
        if ("message_reply".equals(watcher.type)) {
            runMessageReplyWatcher(context, store, watcher, now);
            return;
        }
        if ("call_back".equals(watcher.type)) {
            runCallBackWatcher(context, store, watcher, now);
            return;
        }
        if (!"time".equals(watcher.type)) {
            failWatcher(context, store, watcher, now, "unsupported_watcher_type:" + watcher.type);
            return;
        }
        JSONObject event = baseEvent(watcher, "time", now);
        ReactionResult reaction = runWatcherReaction(context, watcher, event);
        if (!reaction.success) {
            failWatcher(context, store, watcher, now, reaction.error);
            return;
        }
        store.markFired(watcher.id, watcher.type + ":" + watcher.title, now);
        if (reaction.shouldNotify) {
            OpenPhoneNotificationController.showWatcherFired(context, watcher);
        }
    }

    private static void runMessageReplyWatcher(Context context, WatcherStore store,
            WatcherRecord watcher, long now) {
        JSONObject condition = parseOrEmpty(watcher.conditionJson);
        JSONObject schedule = parseOrEmpty(watcher.scheduleJson);
        String address = firstNonEmpty(condition.optString("address", ""),
                condition.optString("phone", ""),
                condition.optString("phone_number", ""),
                condition.optString("sender", ""),
                condition.optString("from", ""));
        long threadId = condition.optLong("thread_id", 0L);
        boolean matchAny = condition.optBoolean("match_any", false)
                || isAnyNumberToken(address);
        if (matchAny) {
            address = "";
        }
        if (address.isEmpty() && threadId <= 0 && !matchAny) {
            failWatcher(context, store, watcher, now, "missing_message_watcher_target");
            return;
        }
        long baseline = condition.optLong("baseline_ms", 0L);
        if (baseline <= 0) {
            baseline = watcher.createdAtMillis;
        }
        long deadline = condition.optLong("deadline_at", 0L);
        String notifyOn = firstNonEmpty(condition.optString("notify_on", ""),
                deadline > 0 ? "no_reply" : "reply");
        InboundMessage reply;
        try {
            reply = findInboundMessage(context, address, threadId, baseline);
        } catch (SecurityException e) {
            failWatcher(context, store, watcher, now, "messages_permission_denied:read");
            return;
        } catch (RuntimeException e) {
            failWatcher(context, store, watcher, now, "messages_query_failed:"
                    + safeHashPart(e.getClass().getSimpleName()));
            return;
        }
        if (reply != null) {
            String resultHash = "message_reply:" + reply.messageId + ":" + reply.dateMillis;
            long interval = messageWatcherIntervalMillis(condition, schedule);
            long nextRunAt = now + interval;
            if (resultAlreadySeen(watcher.lastResultHash, resultHash)) {
                store.markNoop(watcher.id, nextRunAt, resultHash, now);
                return;
            }
            JSONObject event = messageEvent(watcher, "reply", address, threadId, reply, now);
            ReactionResult reaction = runWatcherReaction(context, watcher, event);
            if (!reaction.success) {
                failWatcher(context, store, watcher, now, reaction.error);
                return;
            }
            if (matchAny || condition.optBoolean("recurring", false)) {
                store.markNoop(watcher.id, nextRunAt, resultHash, now);
            } else {
                store.markFired(watcher.id, resultHash, now);
            }
            if ("reply".equals(notifyOn) && reaction.shouldNotify) {
                OpenPhoneNotificationController.showWatcherFired(context, watcher);
            }
            // notify_on=no_reply: the reply arrived, so the reminder is moot —
            // resolve the watcher silently.
            return;
        }
        if (deadline > 0 && now >= deadline) {
            if ("no_reply".equals(notifyOn)) {
                JSONObject event = messageEvent(watcher, "no_reply", address, threadId,
                        null, now);
                ReactionResult reaction = runWatcherReaction(context, watcher, event);
                if (!reaction.success) {
                    failWatcher(context, store, watcher, now, reaction.error);
                    return;
                }
                store.markFired(watcher.id, "message_reply:no_reply_by_deadline:" + deadline,
                        now);
                if (reaction.shouldNotify) {
                    OpenPhoneNotificationController.showWatcherFired(context, watcher);
                }
            } else {
                store.stop(watcher.id);
            }
            return;
        }
        long interval = messageWatcherIntervalMillis(condition, schedule);
        long nextRunAt = now + interval;
        if (deadline > now) {
            nextRunAt = Math.min(nextRunAt, Math.max(deadline, now + MIN_DELAY_MILLIS));
        }
        store.markNoop(watcher.id, nextRunAt, "message_reply:no_reply_yet:" + baseline, now);
    }

    private static void runCallBackWatcher(Context context, WatcherStore store,
            WatcherRecord watcher, long now) {
        JSONObject condition = parseOrEmpty(watcher.conditionJson);
        JSONObject schedule = parseOrEmpty(watcher.scheduleJson);
        JSONObject delivery = parseOrEmpty(watcher.deliveryJson);
        String number = firstNonEmpty(condition.optString("number", ""),
                condition.optString("address", ""),
                condition.optString("phone", ""),
                condition.optString("phone_number", ""));
        boolean hasReaction = hasConcreteReaction(delivery);
        boolean matchAny = condition.optBoolean("match_any", false)
                || isAnyNumberToken(number)
                || (number.isEmpty() && hasReaction);
        if (number.isEmpty() && !matchAny) {
            failWatcher(context, store, watcher, now, "missing_call_watcher_number");
            return;
        }
        long baseline = condition.optLong("baseline_ms", 0L);
        if (baseline <= 0) {
            baseline = watcher.createdAtMillis;
        }
        long deadline = condition.optLong("deadline_at", 0L);
        String notifyOn = firstNonEmpty(condition.optString("notify_on", ""),
                deadline > 0 ? "no_call" : "call");
        // direction filter: any (default), incoming, outgoing
        String direction = firstNonEmpty(condition.optString("direction", ""), "any")
                .toLowerCase(Locale.US);
        boolean recurring = condition.optBoolean("recurring", false)
                || schedule.optBoolean("recurring", false)
                || delivery.optBoolean("recurring", false)
                || delivery.optBoolean("repeat", false)
                || (hasReaction && matchAny);
        ObservedCall call;
        try {
            call = findCall(context, number, baseline, direction, matchAny);
        } catch (SecurityException e) {
            failWatcher(context, store, watcher, now, "calls_permission_denied:read");
            return;
        } catch (RuntimeException e) {
            failWatcher(context, store, watcher, now, "calls_query_failed:"
                    + safeHashPart(e.getClass().getSimpleName()));
            return;
        }
        if (call != null) {
            String resultHash = "call_back:" + call.callId + ":" + call.dateMillis;
            long interval = messageWatcherIntervalMillis(condition, schedule);
            long nextRunAt = now + interval;
            if (resultAlreadySeen(watcher.lastResultHash, resultHash)) {
                store.markNoop(watcher.id, nextRunAt, resultHash, now);
                return;
            }
            JSONObject event = callEvent(watcher, "call", call, direction, now);
            ReactionResult reaction = runWatcherReaction(context, watcher, event);
            if (!reaction.success) {
                if ("watcher_reaction_skipped:empty_template_value".equals(reaction.error)) {
                    store.markNoop(watcher.id, nextRunAt, resultHash, now);
                } else {
                    failWatcher(context, store, watcher, now, reaction.error);
                }
                return;
            }
            if (recurring) {
                store.markNoop(watcher.id, nextRunAt, resultHash, now);
            } else {
                store.markFired(watcher.id, resultHash, now);
            }
            if ("call".equals(notifyOn) && reaction.shouldNotify) {
                OpenPhoneNotificationController.showWatcherFired(context, watcher);
            }
            // notify_on=no_call: the call happened, so the reminder is moot —
            // resolve the watcher silently.
            return;
        }
        if (deadline > 0 && now >= deadline) {
            if ("no_call".equals(notifyOn)) {
                JSONObject event = callDeadlineEvent(watcher, number, direction, now, deadline);
                ReactionResult reaction = runWatcherReaction(context, watcher, event);
                if (!reaction.success) {
                    failWatcher(context, store, watcher, now, reaction.error);
                    return;
                }
                store.markFired(watcher.id, "call_back:no_call_by_deadline:" + deadline, now);
                if (reaction.shouldNotify) {
                    OpenPhoneNotificationController.showWatcherFired(context, watcher);
                }
            } else {
                store.stop(watcher.id);
            }
            return;
        }
        long interval = messageWatcherIntervalMillis(condition, schedule);
        long nextRunAt = now + interval;
        if (deadline > now) {
            nextRunAt = Math.min(nextRunAt, Math.max(deadline, now + MIN_DELAY_MILLIS));
        }
        store.markNoop(watcher.id, nextRunAt, "call_back:no_call_yet:" + baseline, now);
    }

    private static ObservedCall findCall(Context context, String number, long baselineMillis,
            String direction, boolean matchAny) {
        String[] projection = new String[] {
                android.provider.CallLog.Calls._ID,
                android.provider.CallLog.Calls.NUMBER,
                android.provider.CallLog.Calls.DATE,
                android.provider.CallLog.Calls.TYPE
        };
        try (Cursor cursor = context.getContentResolver().query(
                android.provider.CallLog.Calls.CONTENT_URI, projection,
                android.provider.CallLog.Calls.DATE + " > ?",
                new String[] { Long.toString(baselineMillis) },
                android.provider.CallLog.Calls.DATE + " DESC")) {
            if (cursor == null) {
                throw new IllegalStateException("calls_query_null_cursor");
            }
            int scanned = 0;
            while (cursor.moveToNext() && scanned < 100) {
                scanned++;
                int type = cursor.getInt(3);
                if ("incoming".equals(direction)
                        && type != android.provider.CallLog.Calls.INCOMING_TYPE
                        && type != android.provider.CallLog.Calls.MISSED_TYPE) {
                    continue;
                }
                if ("outgoing".equals(direction)
                        && type != android.provider.CallLog.Calls.OUTGOING_TYPE) {
                    continue;
                }
                String rowNumber = cursor.getString(1);
                if (!matchAny && !addressMatches(rowNumber, number)) {
                    continue;
                }
                return new ObservedCall(cursor.getLong(0), rowNumber, cursor.getLong(2));
            }
        }
        return null;
    }

    private static final class ObservedCall {
        final long callId;
        final String number;
        final long dateMillis;

        ObservedCall(long callId, String number, long dateMillis) {
            this.callId = callId;
            this.number = number == null ? "" : number.trim();
            this.dateMillis = dateMillis;
        }
    }

    private static InboundMessage findInboundMessage(Context context, String address,
            long threadId, long baselineMillis) {
        StringBuilder selection = new StringBuilder(
                Telephony.Sms.TYPE + " = " + Telephony.Sms.MESSAGE_TYPE_INBOX
                        + " AND " + Telephony.Sms.DATE + " > ?");
        java.util.ArrayList<String> args = new java.util.ArrayList<>();
        args.add(Long.toString(baselineMillis));
        if (threadId > 0) {
            selection.append(" AND ").append(Telephony.Sms.THREAD_ID).append(" = ?");
            args.add(Long.toString(threadId));
        }
        String[] projection = new String[] {
                Telephony.Sms._ID,
                Telephony.Sms.THREAD_ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE
        };
        try (Cursor cursor = context.getContentResolver().query(
                Telephony.Sms.CONTENT_URI, projection,
                selection.toString(), args.toArray(new String[0]),
                Telephony.Sms.DATE + " DESC")) {
            if (cursor == null) {
                throw new IllegalStateException("messages_query_null_cursor");
            }
            int scanned = 0;
            while (cursor.moveToNext() && scanned < 100) {
                scanned++;
                String rowAddress = cursor.getString(2);
                if (!address.isEmpty() && !addressMatches(rowAddress, address)) {
                    continue;
                }
                return new InboundMessage(cursor.getLong(0), cursor.getLong(1),
                        rowAddress, cursor.getString(3), cursor.getLong(4));
            }
        }
        return null;
    }

    private static boolean addressMatches(String rowAddress, String watchedAddress) {
        if (containsNormalized(rowAddress, watchedAddress)) {
            return true;
        }
        return PhoneNumberUtils.compare(safe(rowAddress), safe(watchedAddress));
    }

    private static boolean isAnyNumberToken(String value) {
        String clean = safe(value).trim().toLowerCase(Locale.US);
        return "*".equals(clean) || "any".equals(clean) || "all".equals(clean)
                || "anyone".equals(clean) || "everybody".equals(clean)
                || "everyone".equals(clean);
    }

    private static boolean hasConcreteReaction(JSONObject rawDelivery) {
        JSONObject delivery = normalizedDelivery(rawDelivery);
        String tool = deliveryTool(delivery);
        if (!tool.isEmpty()) {
            return true;
        }
        String prompt = deliveryPrompt(delivery);
        if (!prompt.isEmpty()) {
            return true;
        }
        String mode = delivery.optString("mode", "").trim().toLowerCase(Locale.US);
        return "tool".equals(mode) || "agent_job".equals(mode)
                || "background_job".equals(mode) || "agent".equals(mode);
    }

    private static ReactionResult runWatcherReaction(Context context, WatcherRecord watcher,
            JSONObject event) {
        JSONObject delivery = normalizedDelivery(parseOrEmpty(watcher.deliveryJson));
        boolean concrete = hasConcreteReaction(delivery);
        boolean shouldNotify = shouldNotifyForDelivery(delivery, !concrete);
        if (!concrete) {
            return ReactionResult.success(shouldNotify, "notification");
        }
        String mode = delivery.optString("mode", "").trim().toLowerCase(Locale.US);
        String prompt = deliveryPrompt(delivery);
        if (!prompt.isEmpty() || "agent_job".equals(mode)
                || "background_job".equals(mode) || "agent".equals(mode)) {
            return createReactionJob(context, watcher, delivery, event, shouldNotify);
        }
        String tool = deliveryTool(delivery);
        if (tool.isEmpty()) {
            return ReactionResult.failure("watcher_reaction_missing_tool");
        }
        JSONObject rawArguments = delivery.optJSONObject("arguments");
        if (rawArguments == null) {
            rawArguments = delivery.optJSONObject("tool_arguments");
        }
        if (rawArguments == null) {
            rawArguments = new JSONObject();
        }
        JSONObject arguments;
        try {
            arguments = renderTemplateObject(rawArguments, event, watcher);
            if (containsUnresolvedTemplate(arguments)) {
                return ReactionResult.failure("watcher_reaction_unresolved_template");
            }
            if (arguments.optString("reason", "").trim().isEmpty()) {
                arguments.put("reason", "Watcher " + watcher.id + " fired: " + watcher.title);
            }
        } catch (JSONException e) {
            return ReactionResult.failure("watcher_reaction_bad_arguments");
        }
        OpenPhoneAgentManager agentManager = context.getSystemService(OpenPhoneAgentManager.class);
        if (agentManager == null) {
            return ReactionResult.failure("framework_unavailable");
        }
        try {
            FrameworkToolExecutor executor = new FrameworkToolExecutor(context, agentManager);
            String resultText = executor.execute("watcher-" + watcher.id + "-"
                    + System.currentTimeMillis(), tool, arguments);
            JSONObject result = new JSONObject(resultText == null ? "{}" : resultText);
            String status = result.optString("status", "");
            if (isFailureStatus(status)) {
                return ReactionResult.failure(status.isEmpty()
                        ? "watcher_reaction_failed" : status);
            }
            return ReactionResult.success(shouldNotify,
                    status.isEmpty() ? "watcher_reaction.done" : status);
        } catch (JSONException e) {
            return ReactionResult.failure("watcher_reaction_bad_result");
        } catch (RuntimeException e) {
            return ReactionResult.failure("watcher_reaction_failed:"
                    + e.getClass().getSimpleName());
        }
    }

    private static ReactionResult createReactionJob(Context context, WatcherRecord watcher,
            JSONObject delivery, JSONObject event, boolean shouldNotify) {
        String prompt = deliveryPrompt(delivery);
        if (prompt.isEmpty()) {
            return ReactionResult.failure("watcher_reaction_missing_prompt");
        }
        try {
            prompt = renderTemplateString(prompt, event, watcher);
            if (containsUnresolvedTemplate(prompt)) {
                return ReactionResult.failure("watcher_reaction_unresolved_template");
            }
            JSONObject payload = new JSONObject()
                    .put("watcher_id", watcher.id)
                    .put("watcher_title", watcher.title)
                    .put("event", event);
            prompt = prompt + "\n\nWatcher event JSON:\n"
                    + (event == null ? "{}" : event.toString());
            JSONObject schedule = new JSONObject()
                    .put("next_run_at", System.currentTimeMillis() + MIN_DELAY_MILLIS);
            JSONObject jobDelivery = new JSONObject()
                    .put("mode", shouldNotify ? "notification" : "silent");
            String notificationText = firstNonEmpty(delivery.optString("notification_text", ""),
                    delivery.optString("text", ""),
                    delivery.optString("message", ""));
            if (!notificationText.isEmpty()) {
                String renderedNotification = renderTemplateString(notificationText, event,
                        watcher);
                if (containsUnresolvedTemplate(renderedNotification)) {
                    return ReactionResult.failure("watcher_reaction_unresolved_template");
                }
                jobDelivery.put("notification_text", renderedNotification);
            }
            long id = new AgentJobStore(context).createJob(
                    "agent_turn",
                    firstNonEmpty(delivery.optString("title", ""),
                            "Watcher " + watcher.id + ": " + watcher.title),
                    prompt,
                    payload.toString(),
                    schedule.toString(),
                    delivery.optString("session_target", "isolated"),
                    jobDelivery.toString(),
                    schedule.optLong("next_run_at"));
            if (id < 0) {
                return ReactionResult.failure("background_job.create_failed");
            }
            OpenPhoneAgentJobScheduler.scheduleNext(context);
            return ReactionResult.success(shouldNotify, "background_job.created:" + id);
        } catch (JSONException e) {
            return ReactionResult.failure("watcher_reaction_bad_prompt");
        }
    }

    private static JSONObject normalizedDelivery(JSONObject rawDelivery) {
        JSONObject delivery;
        try {
            delivery = new JSONObject(rawDelivery == null ? "{}" : rawDelivery.toString());
        } catch (JSONException e) {
            delivery = new JSONObject();
        }
        try {
            String tool = firstNonEmpty(delivery.optString("tool", ""),
                    delivery.optString("action_tool", ""),
                    delivery.optString("model_tool", ""));
            String action = delivery.optString("action", "").trim();
            if (tool.isEmpty() && !action.isEmpty() && !isPassiveDeliveryAction(action)
                    && !isLegacySmsDelivery(action)) {
                tool = action;
            }
            String smsBody = firstNonEmpty(delivery.optString("sms_body", ""),
                    delivery.optString("message_body", ""),
                    delivery.optString("body", ""));
            if (tool.isEmpty() && (isLegacySmsDelivery(action)
                    || isLegacySmsDelivery(delivery.optString("mode", ""))
                    || !smsBody.isEmpty())) {
                tool = "messages_send";
                JSONObject arguments = delivery.optJSONObject("arguments");
                if (arguments == null) {
                    arguments = new JSONObject();
                }
                if (arguments.optString("to", "").trim().isEmpty()) {
                    arguments.put("to", "{{event.number}}");
                }
                if (arguments.optString("body", "").trim().isEmpty()
                        && !smsBody.isEmpty()) {
                    arguments.put("body", smsBody);
                }
                delivery.put("arguments", arguments);
            }
            if (!tool.isEmpty()) {
                delivery.put("tool", tool);
            }
        } catch (JSONException ignored) {
        }
        return delivery;
    }

    private static String deliveryTool(JSONObject delivery) {
        return firstNonEmpty(delivery.optString("tool", ""),
                delivery.optString("action_tool", ""),
                delivery.optString("model_tool", ""));
    }

    private static String deliveryPrompt(JSONObject delivery) {
        return firstNonEmpty(delivery.optString("prompt", ""),
                delivery.optString("task_goal", ""),
                delivery.optString("goal", ""),
                delivery.optString("task", ""));
    }

    private static boolean shouldNotifyForDelivery(JSONObject delivery, boolean defaultValue) {
        String mode = delivery.optString("mode", "").trim().toLowerCase(Locale.US);
        if ("silent".equals(mode) || "none".equals(mode)) {
            return false;
        }
        if (delivery.has("notify")) {
            return delivery.optBoolean("notify", defaultValue);
        }
        if (delivery.has("show_notification")) {
            return delivery.optBoolean("show_notification", defaultValue);
        }
        if ("notification".equals(mode) || "notify".equals(mode) || "alert".equals(mode)) {
            return true;
        }
        return defaultValue;
    }

    private static boolean isPassiveDeliveryAction(String value) {
        String clean = safe(value).trim().toLowerCase(Locale.US);
        return clean.isEmpty() || "notification".equals(clean) || "notify".equals(clean)
                || "alert".equals(clean) || "none".equals(clean) || "silent".equals(clean)
                || "tool".equals(clean) || "agent".equals(clean)
                || "agent_job".equals(clean) || "background_job".equals(clean);
    }

    private static boolean isLegacySmsDelivery(String value) {
        String clean = safe(value).trim().toLowerCase(Locale.US);
        return "send_sms".equals(clean) || "sms".equals(clean)
                || "send_message".equals(clean) || "message".equals(clean);
    }

    private static JSONObject baseEvent(WatcherRecord watcher, String eventType, long now) {
        JSONObject event = new JSONObject();
        try {
            event.put("watcher_id", watcher.id)
                    .put("watcher_type", watcher.type)
                    .put("watcher_title", watcher.title)
                    .put("event_type", eventType)
                    .put("observed_at", now);
        } catch (JSONException ignored) {
        }
        return event;
    }

    private static JSONObject notificationEvent(WatcherRecord watcher, String packageName,
            String title, String text, String notificationKey, long observedAtMillis) {
        JSONObject event = baseEvent(watcher, "notification", observedAtMillis);
        try {
            event.put("source", "notification")
                    .put("package", safe(packageName))
                    .put("package_name", safe(packageName))
                    .put("title", safe(title))
                    .put("text", safe(text))
                    .put("body", safe(text))
                    .put("notification_key", safe(notificationKey));
        } catch (JSONException ignored) {
        }
        return event;
    }

    private static JSONObject messageEvent(WatcherRecord watcher, String eventType,
            String address, long threadId, InboundMessage reply, long now) {
        JSONObject event = baseEvent(watcher, eventType, now);
        try {
            String eventAddress = firstNonEmpty(address, reply == null ? "" : reply.address);
            long eventThreadId = threadId > 0 ? threadId : reply == null ? 0L : reply.threadId;
            event.put("source", "message")
                    .put("address", safe(eventAddress))
                    .put("number", safe(eventAddress))
                    .put("thread_id", eventThreadId);
            if (reply != null) {
                event.put("message_id", reply.messageId)
                        .put("message_date", reply.dateMillis)
                        .put("date", reply.dateMillis)
                        .put("body", safe(reply.body))
                        .put("text", safe(reply.body));
            }
        } catch (JSONException ignored) {
        }
        return event;
    }

    private static JSONObject callEvent(WatcherRecord watcher, String eventType,
            ObservedCall call, String direction, long now) {
        JSONObject event = baseEvent(watcher, eventType, now);
        try {
            event.put("source", "call")
                    .put("number", call == null ? "" : call.number)
                    .put("address", call == null ? "" : call.number)
                    .put("direction", safe(direction))
                    .put("call_id", call == null ? 0L : call.callId)
                    .put("call_date", call == null ? 0L : call.dateMillis);
        } catch (JSONException ignored) {
        }
        return event;
    }

    private static JSONObject callDeadlineEvent(WatcherRecord watcher, String number,
            String direction, long now, long deadline) {
        JSONObject event = baseEvent(watcher, "no_call", now);
        try {
            event.put("source", "call")
                    .put("number", safe(number))
                    .put("address", safe(number))
                    .put("direction", safe(direction))
                    .put("deadline_at", deadline);
        } catch (JSONException ignored) {
        }
        return event;
    }

    private static JSONObject webEvent(WatcherRecord watcher, String eventType,
            String url, String query, String resultHash, long now) {
        JSONObject event = baseEvent(watcher, eventType, now);
        try {
            event.put("source", "web")
                    .put("url", safe(url))
                    .put("query", safe(query))
                    .put("result_hash", safe(resultHash));
        } catch (JSONException ignored) {
        }
        return event;
    }

    private static JSONObject renderTemplateObject(JSONObject input, JSONObject event,
            WatcherRecord watcher) throws JSONException {
        JSONObject out = new JSONObject();
        if (input == null) {
            return out;
        }
        JSONArray names = input.names();
        if (names == null) {
            return out;
        }
        for (int i = 0; i < names.length(); i++) {
            String key = names.optString(i, "");
            if (key.isEmpty()) {
                continue;
            }
            out.put(key, renderTemplateValue(input.opt(key), event, watcher));
        }
        return out;
    }

    private static JSONArray renderTemplateArray(JSONArray input, JSONObject event,
            WatcherRecord watcher) throws JSONException {
        JSONArray out = new JSONArray();
        if (input == null) {
            return out;
        }
        for (int i = 0; i < input.length(); i++) {
            out.put(renderTemplateValue(input.opt(i), event, watcher));
        }
        return out;
    }

    private static Object renderTemplateValue(Object value, JSONObject event,
            WatcherRecord watcher) throws JSONException {
        if (value instanceof JSONObject) {
            return renderTemplateObject((JSONObject) value, event, watcher);
        }
        if (value instanceof JSONArray) {
            return renderTemplateArray((JSONArray) value, event, watcher);
        }
        if (value instanceof String) {
            return renderTemplateString((String) value, event, watcher);
        }
        return value == null ? JSONObject.NULL : value;
    }

    private static String renderTemplateString(String value, JSONObject event,
            WatcherRecord watcher) {
        String rendered = value == null ? "" : value;
        JSONArray names = event == null ? null : event.names();
        if (names != null) {
            for (int i = 0; i < names.length(); i++) {
                String key = names.optString(i, "");
                if (key.isEmpty()) {
                    continue;
                }
                String replacement = event.optString(key, "");
                rendered = rendered.replace("{{event." + key + "}}", replacement)
                        .replace("{{" + key + "}}", replacement);
            }
        }
        rendered = rendered.replace("{{watcher.id}}", Long.toString(watcher.id))
                .replace("{{watcher.title}}", watcher.title)
                .replace("{{watcher.type}}", watcher.type);
        return rendered;
    }

    private static boolean containsUnresolvedTemplate(Object value) {
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            JSONArray names = object.names();
            if (names == null) {
                return false;
            }
            for (int i = 0; i < names.length(); i++) {
                if (containsUnresolvedTemplate(object.opt(names.optString(i)))) {
                    return true;
                }
            }
            return false;
        }
        if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            for (int i = 0; i < array.length(); i++) {
                if (containsUnresolvedTemplate(array.opt(i))) {
                    return true;
                }
            }
            return false;
        }
        if (value instanceof String) {
            String text = (String) value;
            return text.contains("{{") && text.contains("}}");
        }
        return false;
    }

    private static boolean isFailureStatus(String status) {
        String clean = safe(status).trim().toLowerCase(Locale.US);
        return clean.isEmpty()
                || "error".equals(clean)
                || clean.startsWith("error:")
                || clean.startsWith("missing_")
                || clean.startsWith("empty_")
                || clean.startsWith("bad_")
                || clean.contains("_failed")
                || clean.contains(".failed")
                || clean.contains("denied")
                || clean.contains("unavailable")
                || clean.contains("not_found")
                || clean.contains("confirmation_required");
    }

    private static final class ReactionResult {
        final boolean success;
        final boolean shouldNotify;
        final String status;
        final String error;

        private ReactionResult(boolean success, boolean shouldNotify, String status,
                String error) {
            this.success = success;
            this.shouldNotify = shouldNotify;
            this.status = status == null ? "" : status;
            this.error = error == null ? "" : error;
        }

        static ReactionResult success(boolean shouldNotify, String status) {
            return new ReactionResult(true, shouldNotify, status, "");
        }

        static ReactionResult failure(String error) {
            return new ReactionResult(false, false, "", firstNonEmpty(error,
                    "watcher_reaction_failed"));
        }
    }

    private static long messageWatcherIntervalMillis(JSONObject condition, JSONObject schedule) {
        long interval = firstPositive(
                schedule.optLong("interval_ms", 0L),
                schedule.optLong("interval_millis", 0L),
                condition.optLong("interval_ms", 0L),
                condition.optLong("interval_millis", 0L));
        if (interval <= 0) {
            interval = DEFAULT_MESSAGE_INTERVAL_MILLIS;
        }
        return Math.max(MIN_DELAY_MILLIS, Math.min(interval, 24L * 60L * 60L * 1000L));
    }

    private static final class InboundMessage {
        final long messageId;
        final long threadId;
        final String address;
        final String body;
        final long dateMillis;

        InboundMessage(long messageId, long threadId, String address, String body,
                long dateMillis) {
            this.messageId = messageId;
            this.threadId = threadId;
            this.address = address == null ? "" : address.trim();
            this.body = body == null ? "" : body;
            this.dateMillis = dateMillis;
        }
    }

    private static void runWebChangeWatcher(Context context, WatcherRecord watcher) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                WatcherStore store = new WatcherStore(context);
                long now = System.currentTimeMillis();
                JSONObject condition = parseOrEmpty(watcher.conditionJson);
                JSONObject schedule = parseOrEmpty(watcher.scheduleJson);
                String url = firstNonEmpty(condition.optString("url", ""),
                        condition.optString("uri", ""),
                        condition.optString("query", ""));
                if (!isHttpUrl(url)) {
                    failWatcher(context, store, watcher, now, "bad_web_watcher_url");
                    scheduleNext(context);
                    return;
                }
                String previousHash = safe(watcher.lastResultHash);
                try {
                    byte[] content = fetchContent(url);
                    String contentHash = "web:" + sha256Hex(content);
                    String evaluator = normalizeEvaluator(firstNonEmpty(
                            condition.optString("evaluator", ""),
                            condition.optString("operator", ""),
                            condition.optString("mode", "")));
                    long nextRunAt = now + watcherIntervalMillis(condition, schedule);
                    if ("text_contains".equals(evaluator)
                            || "semantic_match".equals(evaluator)) {
                        String query = firstNonEmpty(condition.optString("query", ""),
                                condition.optString("condition_text", ""),
                                condition.optString("text", ""),
                                condition.optString("contains", ""),
                                condition.optString("needle", ""));
                        if (query.isEmpty()) {
                            failWatcher(context, store, watcher, now,
                                    "missing_web_watcher_query");
                            scheduleNext(context);
                            return;
                        }
                        boolean matched;
                        String firedPrefix;
                        if ("semantic_match".equals(evaluator)) {
                            String noMatchHash = "web_no_match:" + contentHash;
                            if (noMatchHash.equals(previousHash)) {
                                // Content unchanged since the last "no" verdict; skip the
                                // model call instead of re-judging identical bytes.
                                store.markNoop(watcher.id, nextRunAt, noMatchHash, now);
                                scheduleNext(context);
                                return;
                            }
                            matched = judgeSemanticMatch(context, query,
                                    webTextForJudgment(content));
                            firedPrefix = "web_semantic_match:";
                        } else {
                            String text = new String(content,
                                    java.nio.charset.StandardCharsets.UTF_8);
                            matched = containsNormalized(text, query);
                            firedPrefix = "web_match:";
                        }
                        if (matched) {
                            String matchHash = firedPrefix + sha256Hex(
                                    (url + "\n" + query + "\n" + contentHash)
                                            .getBytes(java.nio.charset.StandardCharsets.UTF_8));
                            ReactionResult reaction = runWatcherReaction(context, watcher,
                                    webEvent(watcher, "web_match", url, query, matchHash, now));
                            if (!reaction.success) {
                                failWatcher(context, store, watcher, now, reaction.error);
                                scheduleNext(context);
                                return;
                            }
                            store.markFired(watcher.id, matchHash, now);
                            if (reaction.shouldNotify) {
                                OpenPhoneNotificationController.showWatcherFired(context,
                                        watcher);
                            }
                        } else {
                            store.markNoop(watcher.id, nextRunAt,
                                    "web_no_match:" + contentHash, now);
                        }
                        scheduleNext(context);
                        return;
                    }
                    if (previousHash.isEmpty()
                            || previousHash.startsWith("unsupported_watcher_type:")
                            || previousHash.startsWith("stuck_running_repaired")
                            || previousHash.startsWith("web_error:")) {
                        store.markNoop(watcher.id, nextRunAt, contentHash, now);
                    } else if (previousHash.equals(contentHash)) {
                        store.markNoop(watcher.id, nextRunAt, contentHash, now);
                    } else {
                        ReactionResult reaction = runWatcherReaction(context, watcher,
                                webEvent(watcher, "web_change", url, "", contentHash, now));
                        if (!reaction.success) {
                            failWatcher(context, store, watcher, now, reaction.error);
                            scheduleNext(context);
                            return;
                        }
                        store.markFired(watcher.id, contentHash, now);
                        if (reaction.shouldNotify) {
                            OpenPhoneNotificationController.showWatcherFired(context, watcher);
                        }
                    }
                } catch (IOException | RuntimeException e) {
                    failWatcher(context, store, watcher, now, "web_error:"
                            + safeHashPart(e.getClass().getSimpleName() + ":" + e.getMessage()));
                }
                scheduleNext(context);
            }
        }, "OpenPhoneWebWatcher").start();
    }

    private static String fetchContentHash(String urlString) throws IOException {
        return sha256Hex(fetchContent(urlString));
    }

    private static boolean judgeSemanticMatch(Context context, String conditionText,
            String pageText) throws IOException {
        ModelEndpointConfig endpointConfig = watcherModelEndpointConfig(context);
        if (!endpointConfig.isConfigured()) {
            throw new IOException("semantic_model_unconfigured");
        }
        return new OpenAiResponsesAgentAdapter(endpointConfig)
                .judgeWatcherCondition(conditionText, pageText);
    }

    private static ModelEndpointConfig watcherModelEndpointConfig(Context context) {
        return ModelEndpointConfig.fromStoredSettings(context.getApplicationContext());
    }

    private static String webTextForJudgment(byte[] content) {
        String text = new String(content, java.nio.charset.StandardCharsets.UTF_8);
        text = text.replaceAll("(?is)<(script|style)[^>]*>.*?</\\1>", " ")
                .replaceAll("(?s)<[^>]{0,500}>", " ")
                .replaceAll("&nbsp;", " ")
                .replaceAll("&amp;", "&")
                .replaceAll("&lt;", "<")
                .replaceAll("&gt;", ">")
                .replaceAll("\\s+", " ")
                .trim();
        return text.length() <= MAX_JUDGMENT_CHARS
                ? text : text.substring(0, MAX_JUDGMENT_CHARS);
    }

    private static byte[] fetchContent(String urlString) throws IOException {
        HttpURLConnection connection = null;
        try {
            URL url = new URL(urlString);
            connection = (HttpURLConnection) url.openConnection();
            connection.setInstanceFollowRedirects(true);
            connection.setConnectTimeout(10_000);
            connection.setReadTimeout(10_000);
            connection.setRequestProperty("User-Agent", "OpenPhoneWatcher/1");
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                throw new IOException("http_status_" + status);
            }
            try (InputStream input = connection.getInputStream()) {
                return readBounded(input, MAX_WEB_BYTES);
            }
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static byte[] readBounded(InputStream input, int maxBytes) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int total = 0;
        while (true) {
            int read = input.read(buffer, 0, Math.min(buffer.length, maxBytes - total));
            if (read < 0) {
                break;
            }
            output.write(buffer, 0, read);
            total += read;
            if (total >= maxBytes) {
                break;
            }
        }
        return output.toByteArray();
    }

    private static String sha256Hex(byte[] data) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(data == null ? new byte[0] : data);
            StringBuilder builder = new StringBuilder(hash.length * 2);
            for (byte value : hash) {
                builder.append(String.format(Locale.US, "%02x", value & 0xff));
            }
            return builder.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static long watcherIntervalMillis(JSONObject condition, JSONObject schedule) {
        long interval = firstPositive(
                schedule.optLong("interval_ms", 0L),
                schedule.optLong("interval_millis", 0L),
                condition.optLong("interval_ms", 0L),
                condition.optLong("interval_millis", 0L));
        if (interval <= 0) {
            return DEFAULT_WEB_INTERVAL_MILLIS;
        }
        return Math.max(MIN_DELAY_MILLIS, Math.min(interval, 24L * 60L * 60L * 1000L));
    }

    private static long firstPositive(long... values) {
        if (values == null) {
            return 0L;
        }
        for (long value : values) {
            if (value > 0) {
                return value;
            }
        }
        return 0L;
    }

    private static boolean isHttpUrl(String value) {
        String clean = safe(value).toLowerCase(Locale.US);
        return clean.startsWith("https://") || clean.startsWith("http://");
    }

    private static boolean notificationMatches(WatcherRecord watcher, String packageName,
            String title, String text) {
        JSONObject condition = parseOrEmpty(watcher.conditionJson);
        String packageFilter = firstNonEmpty(condition.optString("package", ""),
                condition.optString("package_name", ""),
                condition.optString("source_app", ""));
        String titleNeedle = firstNonEmpty(condition.optString("title_contains", ""),
                condition.optString("title", ""));
        String textNeedle = firstNonEmpty(condition.optString("text_contains", ""),
                condition.optString("body_contains", ""));
        String query = firstNonEmpty(condition.optString("query", ""),
                condition.optString("contains", ""),
                condition.optString("text", ""),
                condition.optString("needle", ""));
        if (packageFilter.isEmpty() && titleNeedle.isEmpty()
                && textNeedle.isEmpty() && query.isEmpty()) {
            return false;
        }
        if (!packageFilter.isEmpty()
                && !containsNormalized(packageName, packageFilter)) {
            return false;
        }
        String haystack = (safe(packageName) + " " + safe(title) + " " + safe(text))
                .toLowerCase(Locale.US);
        String titleHaystack = safe(title).toLowerCase(Locale.US);
        String textHaystack = safe(text).toLowerCase(Locale.US);
        if (!titleNeedle.isEmpty()
                && !titleHaystack.contains(titleNeedle.toLowerCase(Locale.US))) {
            return false;
        }
        if (!textNeedle.isEmpty()
                && !textHaystack.contains(textNeedle.toLowerCase(Locale.US))) {
            return false;
        }
        return query.isEmpty() || haystack.contains(query.toLowerCase(Locale.US));
    }

    private static void failWatcher(Context context, WatcherStore store, WatcherRecord watcher,
            long now, String reason) {
        int failures = watcher.failureCount + 1;
        long nextRunAt = now + WatcherStore.backoffMillis(failures);
        long failureAlertAt = failures >= 3 ? now : watcher.failureAlertAtMillis;
        String storedReason = reason;
        if (isEventResultHash(watcher.lastResultHash)) {
            storedReason = reason + ";previous_result=" + watcher.lastResultHash;
        }
        store.markFailed(watcher.id, storedReason, nextRunAt, failures, failureAlertAt, now);
        Log.w(TAG, "Watcher failed: " + watcher.id + " " + reason);
        if (failures >= 3) {
            OpenPhoneNotificationController.showWatcherFailed(context, watcher, reason);
        }
    }

    private static void scheduleNext(Context context, CommitmentStore store,
            WatcherStore watcherStore) {
        if (!isUserUnlocked(context)) {
            scheduleUserUnlockRetry(context);
            return;
        }
        try {
            PointerOverlayController.publishWatchingCount(watcherStore.active(50).size());
        } catch (RuntimeException e) {
            Log.w(TAG, "Failed to publish watcher count", e);
        }
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms == null) {
            return;
        }
        PendingIntent pending = checkPendingIntent(context);
        long now = System.currentTimeMillis();
        long nextCommitmentDueAt = store.nextDueAt(now);
        long nextWatcherRunAt = watcherStore.nextRunAt(now);
        long nextDueAt = earliestPositive(nextCommitmentDueAt, nextWatcherRunAt);
        if (nextDueAt <= 0) {
            alarms.cancel(pending);
            return;
        }
        long triggerAt = Math.max(nextDueAt, now + MIN_DELAY_MILLIS);
        try {
            alarms.set(AlarmManager.RTC_WAKEUP, triggerAt, pending);
            Log.i(TAG, "Scheduled watcher check at " + triggerAt);
        } catch (RuntimeException e) {
            Log.w(TAG, "Failed to schedule watcher check", e);
        }
    }

    private static PendingIntent checkPendingIntent(Context context) {
        Intent intent = new Intent(context, OpenPhoneWatcherReceiver.class);
        intent.setAction(ACTION_CHECK);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(context, 7001, intent, flags);
    }

    private static boolean isUserUnlocked(Context context) {
        UserManager userManager = context.getSystemService(UserManager.class);
        return userManager == null || userManager.isUserUnlocked();
    }

    private static void scheduleUserUnlockRetry(Context context) {
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms == null) {
            return;
        }
        long triggerAt = System.currentTimeMillis() + USER_UNLOCK_RETRY_MILLIS;
        try {
            alarms.set(AlarmManager.RTC_WAKEUP, triggerAt, checkPendingIntent(context));
            Log.i(TAG, "User locked; scheduled watcher retry at " + triggerAt);
        } catch (RuntimeException e) {
            Log.w(TAG, "Failed to schedule watcher unlock retry", e);
        }
    }

    private static boolean resultAlreadySeen(String previous, String resultHash) {
        String cleanPrevious = safe(previous);
        String cleanResult = safe(resultHash);
        return !cleanResult.isEmpty()
                && (cleanResult.equals(cleanPrevious) || cleanPrevious.contains(cleanResult));
    }

    private static boolean isEventResultHash(String value) {
        String clean = safe(value);
        return clean.startsWith("call_back:")
                || clean.startsWith("message_reply:")
                || clean.startsWith("notification:")
                || clean.startsWith("web:")
                || clean.startsWith("web_match:")
                || clean.startsWith("web_semantic_match:");
    }

    private static long earliestPositive(long first, long second) {
        if (first <= 0) {
            return second;
        }
        if (second <= 0) {
            return first;
        }
        return Math.min(first, second);
    }

    private static JSONObject parseOrEmpty(String json) {
        try {
            return new JSONObject(json == null || json.isEmpty() ? "{}" : json);
        } catch (JSONException e) {
            return new JSONObject();
        }
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

    private static String normalizeEvaluator(String evaluator) {
        String clean = safe(evaluator).toLowerCase(Locale.US);
        if ("contains".equals(clean) || "text".equals(clean) || "text_match".equals(clean)) {
            return "text_contains";
        }
        if ("semantic".equals(clean) || "semantic_contains".equals(clean)) {
            return "semantic_match";
        }
        if (clean.isEmpty() || "change".equals(clean) || "hash".equals(clean)) {
            return "hash_change";
        }
        return clean;
    }

    private static boolean containsNormalized(String value, String needle) {
        return safe(value).toLowerCase(Locale.US)
                .contains(safe(needle).toLowerCase(Locale.US));
    }

    private static String safe(String value) {
        return value == null ? "" : value.trim();
    }

    private static String safeHashPart(String value) {
        String clean = safe(value);
        return clean.length() <= 80 ? clean : clean.substring(0, 80);
    }
}
