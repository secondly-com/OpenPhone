package org.openphone.assistant.session;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

public final class PhoneSessionStore {
    private static final String TAG = "OpenPhoneSessions";
    private static final String PREFS = "openphone_execution_sessions";
    private static final String KEY_SESSIONS = "sessions";
    private static final int MAX_SESSIONS = 200;

    private final SharedPreferences mPrefs;

    public PhoneSessionStore(Context context) {
        mPrefs = context.getApplicationContext().getSharedPreferences(PREFS,
                Context.MODE_PRIVATE);
    }

    public synchronized PhoneExecutionSession create(String runtimeKind,
            String runtimeSessionId, String attentionId, String source, String autonomy,
            String summary) {
        return upsert("phone-sess-" + UUID.randomUUID(), runtimeKind, runtimeSessionId,
                attentionId, source, autonomy, "created", summary);
    }

    public synchronized PhoneExecutionSession upsert(String phoneSessionId,
            String runtimeKind, String runtimeSessionId, String attentionId, String source,
            String autonomy, String status, String summary) {
        String cleanId = clean(phoneSessionId);
        if (cleanId.isEmpty()) {
            return create(runtimeKind, runtimeSessionId, attentionId, source, autonomy, summary);
        }
        long now = System.currentTimeMillis();
        JSONArray sessions = readSessions();
        JSONObject existing = null;
        for (int i = 0; i < sessions.length(); i++) {
            JSONObject item = sessions.optJSONObject(i);
            if (item != null && cleanId.equals(item.optString("phone_session_id", ""))) {
                existing = item;
                break;
            }
        }
        if (existing == null) {
            existing = new JSONObject();
            sessions.put(existing);
            try {
                existing.put("phone_session_id", cleanId)
                        .put("created_at_ms", now);
            } catch (JSONException ignored) {
            }
        }
        try {
            putIfPresent(existing, "runtime_kind", runtimeKind);
            putIfPresent(existing, "runtime_session_id", runtimeSessionId);
            putIfPresent(existing, "attention_id", attentionId);
            putIfPresent(existing, "source", source);
            putIfPresent(existing, "autonomy", autonomy);
            putIfPresent(existing, "summary", summary);
            existing.put("status", clean(status).isEmpty()
                    ? existing.optString("status", "created") : clean(status))
                    .put("updated_at_ms", now);
            if (!existing.has("audit_log_id") || existing.optString("audit_log_id", "").isEmpty()) {
                existing.put("audit_log_id", "phone-session:" + cleanId);
            }
        } catch (JSONException ignored) {
        }
        trimSessions(sessions);
        if (!writeSessions(sessions)) {
            return PhoneExecutionSession.fromJson(existing);
        }
        return PhoneExecutionSession.fromJson(existing);
    }

    public synchronized PhoneExecutionSession touchStatus(String phoneSessionId,
            String status) {
        JSONObject session = findSessionObject(phoneSessionId);
        if (session == null) {
            return null;
        }
        try {
            session.put("status", clean(status).isEmpty()
                    ? session.optString("status", "created") : clean(status))
                    .put("updated_at_ms", System.currentTimeMillis());
        } catch (JSONException ignored) {
        }
        JSONArray sessions = readSessions();
        replaceSession(sessions, session);
        writeSessions(sessions);
        return PhoneExecutionSession.fromJson(session);
    }

    public synchronized PhoneExecutionSession find(String phoneSessionId) {
        return PhoneExecutionSession.fromJson(findSessionObject(phoneSessionId));
    }

    public synchronized String listJson(int limit) {
        JSONArray out = new JSONArray();
        for (PhoneExecutionSession session : list(limit)) {
            out.put(session.toJson());
        }
        try {
            return new JSONObject().put("sessions", out).toString();
        } catch (JSONException e) {
            return "{\"sessions\":[]}";
        }
    }

    public synchronized List<PhoneExecutionSession> list(int limit) {
        JSONArray sessions = readSessions();
        ArrayList<PhoneExecutionSession> out = new ArrayList<>();
        int boundedLimit = Math.max(1, Math.min(limit, MAX_SESSIONS));
        for (int i = sessions.length() - 1; i >= 0 && out.size() < boundedLimit; i--) {
            PhoneExecutionSession session =
                    PhoneExecutionSession.fromJson(sessions.optJSONObject(i));
            if (session != null) {
                out.add(session);
            }
        }
        return out;
    }

    public static String extractPhoneSessionId(String runtimeSessionId) {
        String clean = clean(runtimeSessionId);
        if (clean.isEmpty()) {
            return "";
        }
        String[] parts = clean.split(":");
        for (String part : parts) {
            if (part != null && part.startsWith("phone-sess-")) {
                return part;
            }
        }
        return clean.startsWith("phone-sess-") ? clean : "";
    }

    private JSONObject findSessionObject(String phoneSessionId) {
        String cleanId = clean(phoneSessionId);
        if (cleanId.isEmpty()) {
            return null;
        }
        JSONArray sessions = readSessions();
        for (int i = 0; i < sessions.length(); i++) {
            JSONObject item = sessions.optJSONObject(i);
            if (item != null && cleanId.equals(item.optString("phone_session_id", ""))) {
                return item;
            }
        }
        return null;
    }

    private static void replaceSession(JSONArray sessions, JSONObject replacement) {
        if (replacement == null) {
            return;
        }
        String id = replacement.optString("phone_session_id", "");
        for (int i = 0; i < sessions.length(); i++) {
            JSONObject item = sessions.optJSONObject(i);
            if (item != null && id.equals(item.optString("phone_session_id", ""))) {
                try {
                    sessions.put(i, replacement);
                } catch (JSONException ignored) {
                }
                return;
            }
        }
        sessions.put(replacement);
    }

    private JSONArray readSessions() {
        String raw = mPrefs.getString(KEY_SESSIONS, "[]");
        try {
            return new JSONArray(raw == null || raw.isEmpty() ? "[]" : raw);
        } catch (JSONException e) {
            Log.w(TAG, "phone session store corrupt; ignoring", e);
            return new JSONArray();
        }
    }

    private boolean writeSessions(JSONArray sessions) {
        return mPrefs.edit().putString(KEY_SESSIONS, sessions.toString()).commit();
    }

    private static void putIfPresent(JSONObject object, String key, String value)
            throws JSONException {
        String clean = clean(value);
        if (!clean.isEmpty()) {
            object.put(key, clean);
        }
    }

    private static void trimSessions(JSONArray sessions) {
        while (sessions.length() > MAX_SESSIONS) {
            sessions.remove(0);
        }
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
