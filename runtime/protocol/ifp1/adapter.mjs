/**
 * ifp/1 action-lifecycle adapter for the OpenPhone runtime protocol v0.
 *
 * Maps the legacy runtime events onto Interfaces Protocol v1 action messages
 * (spec section 8 of packages/interfaces-protocol/spec/interfaces-protocol-1.md
 * in silentspeech-app, vendored alongside as validator.ts/machine.ts):
 *
 *   runtime.tool.requested          -> action.propose   (runtime -> surface)
 *   runtime.confirmation.required   -> (no wire message: confirmation is
 *                                      surface-local state, spec section 8.2;
 *                                      the runtime only sees the outcome)
 *   runtime.confirmation.resolved   -> action.approve | action.reject
 *                                      (surface -> runtime, exact params_hash
 *                                      binding, spec section 8.3)
 *   runtime.tool.result             -> action.result    (surface -> runtime,
 *                                      binding_mismatch on divergence,
 *                                      spec section 8.4)
 *
 * params_hash is "sha256:" + hex SHA-256 of the canonical JSON encoding of
 * params (UTF-8, lexicographically sorted keys at every depth, no
 * insignificant whitespace) — spec section 8.1. Shared test vectors live in
 * fixtures/params-hash-vectors.json.
 */

import { createHash, randomBytes } from "node:crypto";

export const OLD_COMMAND_PREFIX = "openphone.";

/** Canonical JSON encoding per spec section 8.1. */
export function canonicalJson(value) {
  if (value === null || typeof value === "number" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (typeof value === "string") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item ?? null)).join(",")}]`;
  }
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    const body = keys
      .filter((key) => value[key] !== undefined)
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",");
    return `{${body}}`;
  }
  throw new TypeError(`value not representable in canonical JSON: ${typeof value}`);
}

/** "sha256:<hex64>" over the canonical JSON encoding of params. */
export function paramsHash(params) {
  const canonical = canonicalJson(params);
  return `sha256:${createHash("sha256").update(canonical, "utf8").digest("hex")}`;
}

/** Old command name ("openphone.messages.send") -> ifp/1 tool name ("messages.send"). */
export function toolNameFromCommand(command) {
  const name = String(command ?? "");
  return name.startsWith(OLD_COMMAND_PREFIX) ? name.slice(OLD_COMMAND_PREFIX.length) : name;
}

function newMessageId(prefix = "msg") {
  return `${prefix}_${randomBytes(12).toString("hex")}`;
}

function isoNow(clock) {
  return (clock ? new Date(clock()) : new Date()).toISOString().replace(/\.\d{3}Z$/u, "Z");
}

function requireContext(context, fields) {
  for (const field of fields) {
    if (context?.[field] === undefined || context?.[field] === null) {
      throw new Error(`adapter context missing required field: ${field}`);
    }
  }
}

/**
 * runtime.tool.requested -> action.propose.
 *
 * toolRequest is the legacy toolRequest shape
 * (runtime/protocol/openphone-runtime.schema.json $defs.toolRequest):
 * { request_id, runtime, runtime_session_id, tool, params, reason?,
 *   idempotency_key?, timeout_ms? }.
 *
 * context: { entity, session, risk, expiresAt?, ttlMs?, clock? }.
 * risk comes from the ifp1 tools manifest entry for the tool.
 */
export function proposeFromToolRequest(toolRequest, context) {
  requireContext(context, ["entity", "session", "risk"]);
  const params = toolRequest.params ?? {};
  const ttlMs = context.ttlMs ?? 5 * 60 * 1000;
  const now = context.clock ? context.clock() : Date.now();
  const expiresAt = context.expiresAt
    ?? new Date(now + ttlMs).toISOString().replace(/\.\d{3}Z$/u, "Z");
  return {
    ifp: "1",
    id: newMessageId(),
    ts: isoNow(context.clock),
    type: "action.propose",
    entity: context.entity,
    session: context.session,
    device: null,
    correlation: toolRequest.request_id ?? null,
    payload: {
      action_id: `act_${(toolRequest.request_id ?? newMessageId("act")).replace(/[^A-Za-z0-9]/gu, "").slice(-24) || randomBytes(8).toString("hex")}`,
      tool: toolNameFromCommand(toolRequest.tool),
      params,
      params_hash: paramsHash(params),
      reason: toolRequest.reason ?? null,
      risk: context.risk,
      idempotency_key: toolRequest.idempotency_key ?? toolRequest.request_id,
      expires_at: expiresAt,
    },
  };
}

/**
 * runtime.confirmation.resolved -> action.approve | action.reject.
 *
 * resolution: { approved: boolean, confirmation_id?, reason_class? } — the
 * Android-local confirmation outcome. proposal is the action.propose envelope
 * this resolution answers. executedParams are the exact params the surface
 * will execute (defaults to the proposal's params); the approve message
 * carries their hash so the runtime's exact-binding check (spec section 8.3)
 * catches any divergence as binding_mismatch.
 *
 * context: { entity, session, device, generation, mode?, clock? }.
 * mode defaults to "user_confirmed"; pass "policy_auto" for
 * trusted_actions/no-confirmation tools.
 */
export function actionMessageFromConfirmationResolution(resolution, proposal, context) {
  requireContext(context, ["entity", "session", "device"]);
  const base = {
    ifp: "1",
    id: newMessageId(),
    ts: isoNow(context.clock),
    entity: context.entity,
    session: context.session,
    device: context.device,
    parent: proposal.id ?? null,
  };
  if (!resolution.approved) {
    return {
      ...base,
      type: "action.reject",
      payload: {
        action_id: proposal.payload.action_id,
        reason_class: resolution.reason_class ?? "user_denied",
      },
    };
  }
  requireContext(context, ["generation"]);
  const executedParams = resolution.executed_params ?? proposal.payload.params;
  return {
    ...base,
    type: "action.approve",
    generation: context.generation,
    payload: {
      action_id: proposal.payload.action_id,
      params_hash: paramsHash(executedParams),
      confirmation: {
        mode: context.mode ?? "user_confirmed",
        ref: resolution.confirmation_id ?? null,
      },
    },
  };
}

/**
 * runtime.tool.result -> action.result.
 *
 * toolResult is the legacy toolResult shape
 * (runtime/protocol/openphone-runtime.schema.json $defs.toolResult):
 * { request_id, status: "ok" | "error" | ..., result?, error? }.
 *
 * Before reporting execution, the surface re-checks exact binding: if the
 * params it executed (context.executedParams) hash differently from the
 * approved params_hash (context.approvedParamsHash), the result MUST be
 * failed/binding_mismatch and nothing may execute (spec section 8.4). Expiry
 * (context.expiresAt vs message ts) fails with action_expired.
 *
 * context: { entity, session, device, generation, approvedParamsHash?,
 *            executedParams?, expiresAt?, evidence?, clock? }.
 */
export function resultFromToolResult(toolResult, proposal, context) {
  requireContext(context, ["entity", "session", "device", "generation"]);
  const ts = isoNow(context.clock);
  const base = {
    ifp: "1",
    id: newMessageId(),
    ts,
    type: "action.result",
    entity: context.entity,
    session: context.session,
    device: context.device,
    generation: context.generation,
    parent: proposal.id ?? null,
  };
  const payload = {
    action_id: proposal.payload.action_id,
    status: "failed",
    error_class: null,
    evidence: context.evidence ?? null,
  };

  if (context.approvedParamsHash && context.executedParams !== undefined) {
    if (paramsHash(context.executedParams) !== context.approvedParamsHash) {
      payload.error_class = "binding_mismatch";
      return { ...base, payload };
    }
  }

  const expiresAt = context.expiresAt ?? proposal.payload.expires_at;
  if (expiresAt && ts > expiresAt) {
    payload.error_class = "action_expired";
    return { ...base, payload };
  }

  const ok = toolResult.status === "ok" || toolResult.status === "success"
    || toolResult.status === "executed";
  payload.status = ok ? "executed" : "failed";
  payload.error_class = ok ? null : "internal";
  return { ...base, payload };
}
