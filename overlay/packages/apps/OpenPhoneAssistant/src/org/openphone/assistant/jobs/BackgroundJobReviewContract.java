package org.openphone.assistant.jobs;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/** Exact, bounded approval binding for a background mutating tool request. */
public final class BackgroundJobReviewContract {
    public static final long REVIEW_TTL_MILLIS = 15L * 60L * 1000L;
    private static final int MAX_REQUEST_CHARS = 12000;

    private BackgroundJobReviewContract() {
    }

    public static PreparedRequest prepare(AgentJobRecord job, String tool,
            JSONObject arguments, long nowMillis) {
        if (job == null || job.id <= 0 || clean(tool).isEmpty() || arguments == null) {
            return null;
        }
        if (containsBlockedMaterial(arguments)) {
            return null;
        }
        JSONObject params = copy(arguments);
        if (params.toString().length() > MAX_REQUEST_CHARS) {
            return null;
        }
        String confirmationId = "job-confirm-" + UUID.randomUUID();
        String resumeToken = "job-resume-" + UUID.randomUUID();
        String idempotencyKey = "job:" + job.id + ":" + UUID.randomUUID();
        String sessionId = "background-job:" + job.id;
        long expiresAt = nowMillis + REVIEW_TTL_MILLIS;
        String paramsDigest = sha256(clean(tool) + "\n" + canonical(params));
        String bindingDigest = bindingDigest(job.id, "builtin", sessionId, tool,
                paramsDigest, idempotencyKey, expiresAt);
        JSONObject pending = new JSONObject();
        JSONObject checkpoint = new JSONObject();
        try {
            pending.put("schema", "openphone.background_confirmation.v1")
                    .put("confirmation_id", confirmationId)
                    .put("job_id", job.id)
                    .put("runtime", "builtin")
                    .put("phone_session_id", sessionId)
                    .put("tool", clean(tool))
                    .put("params", params)
                    .put("params_digest", paramsDigest)
                    .put("binding_digest", bindingDigest)
                    .put("idempotency_key", idempotencyKey)
                    .put("created_at", nowMillis)
                    .put("expires_at", expiresAt)
                    .put("review_state", "pending")
                    .put("summary", summary(tool, params));
            checkpoint.put("schema", "openphone.background_checkpoint.v1")
                    .put("job_id", job.id)
                    .put("phase", "awaiting_review")
                    .put("tool", clean(tool))
                    .put("params_digest", paramsDigest)
                    .put("binding_digest", bindingDigest)
                    .put("idempotency_key", idempotencyKey)
                    .put("resume_token", resumeToken)
                    .put("created_at", nowMillis)
                    .put("resume_pending", false);
        } catch (JSONException e) {
            return null;
        }
        if (pending.toString().length() > MAX_REQUEST_CHARS
                || checkpoint.toString().length() > MAX_REQUEST_CHARS) {
            return null;
        }
        return new PreparedRequest(
                confirmationId, resumeToken, pending, checkpoint, paramsDigest, bindingDigest);
    }

    public static boolean verify(AgentJobStore.ReviewClaim claim, long nowMillis) {
        if (claim == null || claim.job == null || claim.pendingRequest == null) {
            return false;
        }
        JSONObject request = claim.pendingRequest;
        JSONObject params = request.optJSONObject("params");
        JSONObject checkpoint = object(claim.job.checkpointJson);
        long createdAt = request.optLong("created_at", 0L);
        long expiresAt = request.optLong("expires_at", 0L);
        if (!"openphone.background_confirmation.v1".equals(
                request.optString("schema", ""))
                || request.optLong("job_id", -1L) != claim.job.id
                || !"builtin".equals(request.optString("runtime", ""))
                || !("background-job:" + claim.job.id).equals(
                        request.optString("phone_session_id", ""))
                || clean(request.optString("tool", "")).isEmpty()
                || params == null
                || containsBlockedMaterial(params)
                || request.toString().length() > MAX_REQUEST_CHARS
                || createdAt <= 0L
                || expiresAt <= nowMillis
                || expiresAt <= createdAt
                || expiresAt - createdAt > REVIEW_TTL_MILLIS
                || !"resolving".equals(request.optString("review_state", ""))
                || !(claim.approved ? "approved" : "denied").equals(
                        request.optString("decision", ""))
                || clean(request.optString("idempotency_key", "")).isEmpty()
                || !"openphone.background_checkpoint.v1".equals(
                        checkpoint.optString("schema", ""))
                || checkpoint.optLong("job_id", -1L) != claim.job.id
                || !"awaiting_review".equals(checkpoint.optString("phase", ""))
                || !clean(request.optString("tool", "")).equals(
                        checkpoint.optString("tool", ""))
                || !clean(request.optString("idempotency_key", "")).equals(
                        checkpoint.optString("idempotency_key", ""))
                || clean(claim.job.resumeToken).isEmpty()
                || !clean(claim.job.resumeToken).equals(
                        checkpoint.optString("resume_token", ""))) {
            return false;
        }
        String paramsDigest = sha256(request.optString("tool", "")
                + "\n" + canonical(params));
        if (!constantEquals(paramsDigest, request.optString("params_digest", ""))
                || !constantEquals(paramsDigest,
                        checkpoint.optString("params_digest", ""))) {
            return false;
        }
        String binding = bindingDigest(
                claim.job.id,
                request.optString("runtime", ""),
                request.optString("phone_session_id", ""),
                request.optString("tool", ""),
                paramsDigest,
                request.optString("idempotency_key", ""),
                expiresAt);
        return constantEquals(binding, request.optString("binding_digest", ""))
                && constantEquals(binding,
                        checkpoint.optString("binding_digest", ""));
    }

    public static boolean matchesResume(AgentJobRecord job, String tool, JSONObject params) {
        if (job == null || params == null) {
            return false;
        }
        JSONObject checkpoint = object(job.checkpointJson);
        if (!"openphone.background_checkpoint.v1".equals(
                checkpoint.optString("schema", ""))
                || checkpoint.optLong("job_id", -1L) != job.id
                || clean(job.resumeToken).isEmpty()
                || !clean(job.resumeToken).equals(
                        checkpoint.optString("resume_token", ""))
                || !checkpoint.optBoolean("resume_pending", false)
                || !clean(tool).equals(checkpoint.optString("tool", ""))) {
            return false;
        }
        String digest = sha256(clean(tool) + "\n" + canonical(params));
        return constantEquals(digest, checkpoint.optString("params_digest", ""));
    }

    public static String resumeToolResult(AgentJobRecord job) {
        return object(job == null ? "{}" : job.checkpointJson)
                .optString("tool_result",
                        "{\"status\":\"background.review_result_missing\"}");
    }

    public static String resumePrompt(AgentJobRecord job) {
        JSONObject checkpoint = object(job == null ? "{}" : job.checkpointJson);
        if (!checkpoint.optBoolean("resume_pending", false)) {
            return job == null ? "" : job.prompt;
        }
        String resolution = checkpoint.optString("review_resolution", "resolved");
        String tool = checkpoint.optString("tool", "");
        String result = checkpoint.optString("tool_result", "{}");
        return clean(job.prompt)
                + "\n\nOpenPhone durable review checkpoint (trusted phone state):\n"
                + "The exact " + tool + " request was " + resolution + ".\n"
                + "Its bound tool result is:\n" + truncate(result, 4000) + "\n"
                + "Continue from this result and finish gracefully. Do not execute or ask "
                + "for the same action again unless the user request requires a distinct "
                + "new action.";
    }

    private static String bindingDigest(long jobId, String runtime, String sessionId,
            String tool, String paramsDigest, String idempotencyKey, long expiresAt) {
        return sha256(jobId + "\n" + clean(runtime) + "\n" + clean(sessionId) + "\n"
                + clean(tool) + "\n" + clean(paramsDigest) + "\n"
                + clean(idempotencyKey) + "\n" + expiresAt);
    }

    private static String summary(String tool, JSONObject params) {
        String visible = canonical(params);
        return truncate(clean(tool).replace('_', ' ') + " with " + visible, 1000);
    }

    private static boolean containsBlockedMaterial(Object value) {
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                String lower = key.toLowerCase(Locale.US);
                if (lower.contains("api_key") || lower.contains("authorization")
                        || "auth".equals(lower) || lower.contains("credential")
                        || lower.contains("private_key")
                        || lower.contains("token") || lower.contains("secret")
                        || lower.contains("password") || lower.contains("cookie")
                        || lower.contains("screenshot")
                        || ("data".equals(lower)
                                && "base64".equalsIgnoreCase(object.optString("encoding", "")))) {
                    return true;
                }
                if (containsBlockedMaterial(object.opt(key))) {
                    return true;
                }
            }
        } else if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            for (int i = 0; i < array.length(); i++) {
                if (containsBlockedMaterial(array.opt(i))) {
                    return true;
                }
            }
        } else if (value instanceof String) {
            String text = ((String) value).trim();
            String lower = text.toLowerCase(Locale.US);
            if (lower.startsWith("bearer ") || lower.startsWith("basic ")
                    || lower.contains("-----begin private key-----")
                    || lower.startsWith("data:image/")) {
                return true;
            }
            if (text.length() > 2048 && text.matches("^[A-Za-z0-9+/=_-]+$")) {
                return true;
            }
        }
        return false;
    }

    private static String canonical(Object value) {
        if (value == null || JSONObject.NULL.equals(value)) {
            return "null";
        }
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            List<String> keys = new ArrayList<>();
            Iterator<String> iterator = object.keys();
            while (iterator.hasNext()) {
                keys.add(iterator.next());
            }
            Collections.sort(keys);
            StringBuilder out = new StringBuilder("{");
            for (String key : keys) {
                if (out.length() > 1) out.append(',');
                out.append(JSONObject.quote(key)).append(':')
                        .append(canonical(object.opt(key)));
            }
            return out.append('}').toString();
        }
        if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            StringBuilder out = new StringBuilder("[");
            for (int i = 0; i < array.length(); i++) {
                if (i > 0) out.append(',');
                out.append(canonical(array.opt(i)));
            }
            return out.append(']').toString();
        }
        if (value instanceof String) {
            return JSONObject.quote((String) value);
        }
        return String.valueOf(value);
    }

    private static String sha256(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(clean(value).getBytes(StandardCharsets.UTF_8));
            StringBuilder out = new StringBuilder(digest.length * 2);
            for (byte item : digest) {
                out.append(String.format(Locale.US, "%02x", item & 0xff));
            }
            return out.toString();
        } catch (NoSuchAlgorithmException e) {
            return "";
        }
    }

    private static boolean constantEquals(String left, String right) {
        byte[] a = clean(left).getBytes(StandardCharsets.UTF_8);
        byte[] b = clean(right).getBytes(StandardCharsets.UTF_8);
        return MessageDigest.isEqual(a, b);
    }

    private static JSONObject copy(JSONObject source) {
        return object(source == null ? "{}" : source.toString());
    }

    private static JSONObject object(String raw) {
        try {
            return new JSONObject(raw == null || raw.trim().isEmpty() ? "{}" : raw);
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static String truncate(String value, int max) {
        String clean = clean(value);
        return clean.length() <= max ? clean : clean.substring(0, max - 1) + "…";
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    public static final class PreparedRequest {
        public final String confirmationId;
        public final String resumeToken;
        public final JSONObject pendingRequest;
        public final JSONObject checkpoint;
        public final String paramsDigest;
        public final String bindingDigest;

        PreparedRequest(String confirmationId, String resumeToken, JSONObject pendingRequest,
                JSONObject checkpoint, String paramsDigest, String bindingDigest) {
            this.confirmationId = confirmationId;
            this.resumeToken = resumeToken;
            this.pendingRequest = copy(pendingRequest);
            this.checkpoint = copy(checkpoint);
            this.paramsDigest = paramsDigest;
            this.bindingDigest = bindingDigest;
        }
    }
}
