package org.openphone.assistant.runtime;

import android.content.Context;
import android.openphone.OpenPhoneAgentManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.OpenPhoneNotificationController;
import org.openphone.assistant.runtime.adapters.openclaw.OpenClawRuntimeAdapter;
import org.openphone.assistant.session.PhoneExecutionSession;
import org.openphone.assistant.session.PhoneSessionStore;
import org.openphone.assistant.surface.AdaptiveSurface;
import org.openphone.assistant.surface.AssistantOutput;
import org.openphone.assistant.surface.SurfaceMutationResult;
import org.openphone.assistant.surface.SurfaceRepository;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

public final class RuntimeManager implements RuntimeConfirmationCallback {
    private static final String TAG = "OpenPhoneRuntime";

    private final Context mContext;
    private final OpenPhoneAgentManager mAgentManager;
    private final RuntimeToolBridge mToolBridge;
    private final PhoneSessionStore mSessionStore;
    private final SurfaceRepository mSurfaceRepository;
    private final List<RuntimeAdapter> mAdapters = new ArrayList<>();
    private RuntimeCallback mRuntimeCallback;
    private String mStatus = "disabled";

    public RuntimeManager(Context context, OpenPhoneAgentManager agentManager) {
        mContext = context;
        mAgentManager = agentManager;
        mSessionStore = new PhoneSessionStore(context);
        mSurfaceRepository = new SurfaceRepository(context);
        mToolBridge = new RuntimeToolBridge(context, agentManager, mSessionStore);
        mToolBridge.setConfirmationCallback(this);
    }

    public synchronized void start() {
        stopLocked();
        RuntimeConfig config = RuntimeConfig.load(mContext);
        if (mAgentManager == null) {
            mStatus = "framework_unavailable";
            return;
        }
        if (!config.anyEnabled()) {
            mStatus = "disabled";
            return;
        }
        if (config.openClaw.configured()) {
            mAdapters.add(new OpenClawRuntimeAdapter(mContext, config.openClaw, mToolBridge,
                    new RuntimeCallback() {
                        @Override
                        public void onRuntimeMessage(String runtime, String sessionKey,
                                String message, boolean terminal) {
                            dispatchRuntimeMessage(runtime, sessionKey, message, terminal);
                        }

                        @Override
                        public void onRuntimeOutput(String runtime, String sessionKey,
                                AssistantOutput output, boolean terminal) {
                            acceptRuntimeOutput(runtime, sessionKey, output, terminal, "auto", -1);
                        }

                        @Override
                        public void onRuntimeSurfaceEvent(String runtime, String sessionKey,
                                String event, JSONObject payload) {
                            handleRuntimeSurfaceEvent(runtime, sessionKey, event, payload);
                        }
                    }));
        }
        if (mAdapters.isEmpty()) {
            mStatus = "not_configured";
            return;
        }
        for (RuntimeAdapter adapter : mAdapters) {
            adapter.start();
        }
        mStatus = "connecting";
        Log.i(TAG, "runtime manager started adapters=" + mAdapters.size());
    }

    public synchronized void stop() {
        stopLocked();
        mStatus = "stopped";
    }

    public synchronized String statusJson() {
        JSONArray adapters = new JSONArray();
        for (RuntimeAdapter adapter : mAdapters) {
            try {
                adapters.put(new JSONObject()
                        .put("name", adapter.name())
                        .put("status", adapter.status()));
            } catch (JSONException ignored) {
            }
        }
        String aggregateStatus = aggregateStatusLocked();
        try {
            return new JSONObject()
                    .put("status", aggregateStatus)
                    .put("manager_status", aggregateStatus)
                    .put("lifecycle_status", mStatus)
                    .put("updated_at_ms", System.currentTimeMillis())
                    .put("adapters", adapters)
                    .toString();
        } catch (JSONException e) {
            return "{\"status\":\"error\"}";
        }
    }

    public synchronized void sendEvent(RuntimeEvent event) {
        for (RuntimeAdapter adapter : mAdapters) {
            adapter.sendEvent(event);
        }
    }

    public synchronized void setRuntimeCallback(RuntimeCallback callback) {
        mRuntimeCallback = callback;
    }

    public synchronized String requestRuntimeAttention(String runtime, String text, String source,
            String autonomy, boolean includeScreen, JSONObject context) {
        String cleanRuntime = cleanRuntime(runtime);
        if (cleanRuntime.isEmpty()) {
            return resultJson(false, "missing_runtime", "Runtime is required.");
        }
        String message = text == null ? "" : text.trim();
        if (message.isEmpty()) {
            return resultJson(false, "missing_text", "Runtime attention text is required.");
        }
        for (RuntimeAdapter adapter : mAdapters) {
            if (!cleanRuntime.equals(adapter.name())) {
                continue;
            }
            if (!"connected".equals(adapter.status())) {
                return resultJson(false, "runtime_not_connected",
                        runtimeLabel(cleanRuntime) + " runtime is not connected.");
            }
            String attentionId = "attn-" + UUID.randomUUID();
            PhoneExecutionSession session = mSessionStore.create(cleanRuntime, "",
                    attentionId, source, autonomy, message);
            String sessionKey = adapter.requestAttention(session.phoneSessionId,
                    attentionId, source, message, autonomy, includeScreen, context);
            if (!sessionKey.isEmpty()) {
                mSessionStore.upsert(session.phoneSessionId, cleanRuntime, sessionKey,
                        attentionId, source, autonomy, "waiting_for_runtime", message);
                return resultJson(true, "sent",
                        runtimeLabel(cleanRuntime) + " attention request sent.",
                        session.phoneSessionId, sessionKey);
            }
            mSessionStore.touchStatus(session.phoneSessionId, "failed");
            return resultJson(false, "send_failed",
                    "Could not send " + runtimeLabel(cleanRuntime) + " attention request.",
                    session.phoneSessionId, "");
        }
        return resultJson(false, "runtime_not_configured",
                runtimeLabel(cleanRuntime) + " runtime is not configured.", "", "");
    }

    public synchronized String resolveRuntimeConfirmation(String confirmationId,
            boolean approved) {
        RuntimeConfirmationResolution resolution =
                mToolBridge.resolveConfirmation(confirmationId, approved);
        RuntimeToolRequest request = resolution.request();
        RuntimeToolResult result = resolution.result();
        if (resolution.pending() != null) {
            OpenPhoneNotificationController.cancelRuntimeConfirmation(
                    mContext, resolution.pending().confirmationId());
        }
        sendResolutionToRuntime(request, result);
        return result == null ? "{\"status\":\"error\"}" : result.toWireString();
    }

    @Override
    public synchronized void onRuntimeConfirmationRequested(RuntimePendingConfirmation pending,
            RuntimeToolResult initialResult) {
        if (pending == null || pending.request() == null) {
            return;
        }
        OpenPhoneNotificationController.showRuntimeConfirmation(
                mContext,
                pending.confirmationId(),
                pending.request().runtime(),
                pending.request().tool(),
                pending.summary());
        sendEventToRuntime(pending.request().runtime(),
                new RuntimeEvent("openphone.confirmation.required",
                        confirmationPayload(pending, initialResult)));
    }

    @Override
    public synchronized void onRuntimeConfirmationTimedOut(RuntimePendingConfirmation pending,
            RuntimeToolResult timeoutResult) {
        if (pending == null || pending.request() == null || timeoutResult == null) {
            return;
        }
        OpenPhoneNotificationController.cancelRuntimeConfirmation(
                mContext, pending.confirmationId());
        sendResolutionToRuntime(pending.request(), timeoutResult);
    }

    private void sendResolutionToRuntime(RuntimeToolRequest request,
            RuntimeToolResult result) {
        if (request == null || result == null) {
            return;
        }
        sendResultToRuntime(request.runtime(), request, result);
    }

    private void dispatchRuntimeMessage(String runtime, String sessionKey, String message,
            boolean terminal) {
        String phoneSessionId = PhoneSessionStore.extractPhoneSessionId(sessionKey);
        if (!phoneSessionId.isEmpty()) {
            String lower = message == null ? "" : message.toLowerCase();
            String status = terminal
                    ? (lower.contains("error") || lower.contains("failed")
                            || lower.contains("disconnected") ? "failed" : "completed")
                    : "running";
            mSessionStore.touchStatus(phoneSessionId, status);
        }
        RuntimeCallback callback = mRuntimeCallback;
        if (callback != null) {
            callback.onRuntimeMessage(runtime, sessionKey, message, terminal);
        }
    }

    private void dispatchRuntimeOutput(String runtime, String sessionKey,
            AssistantOutput output, boolean terminal) {
        RuntimeCallback callback = mRuntimeCallback;
        if (callback != null) {
            callback.onRuntimeOutput(runtime, sessionKey, output, terminal);
        }
    }

    private synchronized void handleRuntimeSurfaceEvent(String runtime, String sessionKey,
            String event, JSONObject payload) {
        if ("runtime.surface.dismiss".equals(event)) {
            handleRuntimeSurfaceDismiss(runtime, sessionKey, payload);
            return;
        }
        if (!"runtime.surface.present".equals(event)
                && !"runtime.surface.replace".equals(event)) {
            sendSurfaceProtocolResult(runtime, null, "event_unsupported",
                    "Unsupported runtime surface event.", event);
            return;
        }
        AssistantOutput output = AssistantOutput.fromJson(
                payload == null ? null : payload.optJSONObject("output"));
        if (output == null) {
            sendSurfaceProtocolResult(runtime, null, "output_invalid",
                    "Surface event requires an explicit assistant output envelope.", event);
            return;
        }
        int expectedRevision = payload.optInt("expected_revision", -1);
        acceptRuntimeOutput(runtime, sessionKey, output, false,
                "runtime.surface.replace".equals(event) ? "replace" : "present",
                expectedRevision);
    }

    private synchronized void acceptRuntimeOutput(String runtime, String sessionKey,
            AssistantOutput output, boolean terminal, String operation, int expectedRevision) {
        if (output == null) {
            sendSurfaceProtocolResult(runtime, null, "output_invalid",
                    "Assistant output is malformed.", operation);
            return;
        }
        AdaptiveSurface surface = output.surface;
        if (surface != null) {
            if (!RuntimeRegistry.normalize(runtime).equals(
                    RuntimeRegistry.normalize(surface.runtime))) {
                sendSurfaceProtocolResult(runtime, surface, "runtime_mismatch",
                        "Surface runtime ownership does not match its transport.", operation);
                return;
            }
            if (!output.sessionId.equals(surface.sessionId)
                    || (!sessionKey.isEmpty() && !sessionKey.contains(output.sessionId))) {
                sendSurfaceProtocolResult(runtime, surface, "session_mismatch",
                        "Surface session ownership does not match its output.", operation);
                return;
            }
            SurfaceMutationResult mutation;
            AdaptiveSurface current = mSurfaceRepository.getActive(surface.surfaceId);
            if ("replace".equals(operation)) {
                int expected = expectedRevision < 1
                        ? surface.revision - 1 : expectedRevision;
                mutation = mSurfaceRepository.replace(surface, expected);
            } else if ("present".equals(operation)) {
                mutation = mSurfaceRepository.present(surface);
            } else if (current == null) {
                mutation = mSurfaceRepository.present(surface);
            } else if (surface.revision == current.revision
                    && surface.toJson().toString().equals(current.toJson().toString())) {
                mutation = SurfaceMutationResult.ok("already_presented", current);
            } else {
                mutation = mSurfaceRepository.replace(surface, current.revision);
            }
            if (!mutation.ok) {
                sendSurfaceProtocolResult(runtime, surface, mutation.code,
                        mutation.message, operation);
                return;
            }
            sendSurfaceProtocolResult(runtime, surface, mutation.code,
                    "Surface accepted by the phone.", operation);
        }
        if (!output.sessionId.isEmpty()) {
            mSessionStore.touchStatus(output.sessionId, terminal ? "completed" : "running");
        }
        dispatchRuntimeOutput(runtime, sessionKey, output, terminal);
    }

    private void handleRuntimeSurfaceDismiss(String runtime, String sessionKey,
            JSONObject payload) {
        String surfaceId = payload == null ? "" : payload.optString("surface_id", "");
        AdaptiveSurface surface = mSurfaceRepository.getActive(surfaceId);
        if (surface == null) {
            sendSurfaceProtocolResult(runtime, null, "surface_not_active",
                    "Surface is missing, expired, or already dismissed.", "dismiss");
            return;
        }
        if (!RuntimeRegistry.normalize(runtime).equals(
                RuntimeRegistry.normalize(surface.runtime))) {
            sendSurfaceProtocolResult(runtime, surface, "runtime_mismatch",
                    "Runtime cannot dismiss another runtime's surface.", "dismiss");
            return;
        }
        String claimedSession = payload.optString("session_id", "");
        if (claimedSession.isEmpty()) {
            claimedSession = PhoneSessionStore.extractPhoneSessionId(sessionKey);
        }
        if (!claimedSession.isEmpty() && !claimedSession.equals(surface.sessionId)) {
            sendSurfaceProtocolResult(runtime, surface, "session_mismatch",
                    "Runtime cannot dismiss another session's surface.", "dismiss");
            return;
        }
        int revision = payload.optInt("revision", 0);
        if (revision != surface.revision) {
            sendSurfaceProtocolResult(runtime, surface, "stale_revision",
                    "Runtime dismissal revision is stale.", "dismiss");
            return;
        }
        SurfaceMutationResult result = mSurfaceRepository.dismiss(
                surface.surfaceId, payload.optString("reason", "runtime_dismissed"));
        sendSurfaceProtocolResult(runtime, surface, result.code,
                result.ok ? "Surface dismissed." : result.message, "dismiss");
    }

    private void sendSurfaceProtocolResult(String runtime, AdaptiveSurface surface,
            String status, String message, String operation) {
        JSONObject payload = new JSONObject();
        try {
            payload.put("surface_id", surface == null ? "" : surface.surfaceId)
                    .put("revision", surface == null ? 0 : surface.revision)
                    .put("session_id", surface == null ? "" : surface.sessionId)
                    .put("operation", operation == null ? "" : operation)
                    .put("status", status == null ? "" : status)
                    .put("message", message == null ? "" : message);
        } catch (JSONException ignored) {
        }
        sendEventToRuntime(runtime,
                new RuntimeEvent("runtime.surface.action_result", payload));
    }

    private void sendResultToRuntime(String runtime, RuntimeToolRequest request,
            RuntimeToolResult result) {
        for (RuntimeAdapter adapter : mAdapters) {
            if (adapter.name().equals(runtime)) {
                adapter.sendToolResult(request, result);
            }
        }
    }

    public synchronized void sendEventToRuntime(String runtime, RuntimeEvent event) {
        if (runtime == null || runtime.isEmpty() || event == null) {
            return;
        }
        for (RuntimeAdapter adapter : mAdapters) {
            if (adapter.name().equals(runtime)) {
                adapter.sendEvent(event);
            }
        }
    }

    private void stopLocked() {
        sendEvent(new RuntimeEvent("openphone.presence.offline", presencePayload("stop")));
        for (RuntimeAdapter adapter : mAdapters) {
            adapter.stop();
        }
        mAdapters.clear();
    }

    private String aggregateStatusLocked() {
        if (mAdapters.isEmpty()) {
            return mStatus;
        }
        boolean anyConnected = false;
        boolean anyConnecting = false;
        boolean anyAuthFailed = false;
        boolean anyInsecureTransport = false;
        boolean anyOffline = false;
        for (RuntimeAdapter adapter : mAdapters) {
            String status = adapter.status();
            if ("connected".equals(status)) {
                anyConnected = true;
            } else if ("connecting".equals(status) || "waiting_for_challenge".equals(status)
                    || "handshaking".equals(status)) {
                anyConnecting = true;
            } else if (status != null && status.startsWith("auth_failed")) {
                anyAuthFailed = true;
            } else if ("insecure_transport_denied".equals(status)) {
                anyInsecureTransport = true;
            } else {
                anyOffline = true;
            }
        }
        if (anyInsecureTransport) {
            return anyConnected ? "degraded" : "insecure_transport_denied";
        }
        if (anyAuthFailed) {
            return anyConnected ? "degraded" : "auth_failed";
        }
        if (anyConnected) {
            return anyOffline || anyConnecting ? "degraded" : "connected";
        }
        if (anyConnecting) {
            return "connecting";
        }
        return "offline";
    }

    private JSONObject confirmationPayload(RuntimePendingConfirmation pending,
            RuntimeToolResult initialResult) {
        JSONObject payload = new JSONObject();
        RuntimeToolRequest request = pending == null ? null : pending.request();
        try {
            payload.put("confirmation_id", pending == null ? "" : pending.confirmationId())
                    .put("request_id", request == null ? "" : request.requestId())
                    .put("runtime", request == null ? "" : request.runtime())
                    .put("runtime_session_id", request == null ? "" : request.runtimeSessionId())
                    .put("tool", request == null ? "" : request.tool())
                    .put("summary", pending == null ? "" : pending.summary())
                    .put("reason", request == null ? "" : request.reason())
                    .put("autonomy", request == null ? "" : request.autonomy())
                    .put("timeout_ms", request == null ? 0L : request.timeoutMs())
                    .put("result", initialResult == null
                            ? new JSONObject() : initialResult.toJson());
        } catch (JSONException ignored) {
        }
        return payload;
    }

    private JSONObject presencePayload(String trigger) {
        JSONObject payload = new JSONObject();
        try {
            payload.put("trigger", trigger == null ? "" : trigger)
                    .put("sentAtMs", System.currentTimeMillis())
                    .put("runtime_manager_status", mStatus);
        } catch (JSONException ignored) {
        }
        return payload;
    }

    private static String resultJson(boolean ok, String status, String message) {
        return resultJson(ok, status, message, "", "");
    }

    private static String resultJson(boolean ok, String status, String message,
            String phoneSessionId, String runtimeSessionId) {
        try {
            return new JSONObject()
                    .put("ok", ok)
                    .put("status", status == null ? "" : status)
                    .put("message", message == null ? "" : message)
                    .put("phone_session_id", phoneSessionId == null ? "" : phoneSessionId)
                    .put("runtime_session_id", runtimeSessionId == null ? "" : runtimeSessionId)
                    .toString();
        } catch (JSONException e) {
            return ok ? "{\"ok\":true}" : "{\"ok\":false}";
        }
    }

    private static String cleanRuntime(String runtime) {
        return RuntimeRegistry.normalize(runtime);
    }

    private static String runtimeLabel(String runtime) {
        return RuntimeRegistry.label(runtime);
    }
}
