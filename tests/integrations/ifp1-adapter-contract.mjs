#!/usr/bin/env node

// Exercises the ifp/1 action-lifecycle adapter
// (runtime/protocol/ifp1/adapter.mjs) end to end against the vendored
// reference validator and state machine: the legacy runtime events
// (runtime.tool.requested / runtime.confirmation.resolved /
// runtime.tool.result) become ifp/1 action messages that a conformant
// runtime accepts, and the failure paths (user rejection, binding mismatch,
// expiry) produce the spec-mandated terminal outcomes.

import assert from "node:assert/strict";

import {
  actionMessageFromConfirmationResolution,
  canonicalJson,
  paramsHash,
  proposeFromToolRequest,
  resultFromToolResult,
  toolNameFromCommand,
} from "../../runtime/protocol/ifp1/adapter.mjs";
import { validateMessage } from "../../runtime/protocol/ifp1/validator.ts";
import { ConformanceMachine } from "../../runtime/protocol/ifp1/machine.ts";

let cases = 0;
const check = (name, fn) => {
  fn();
  cases += 1;
};

const GENERATION = 3;
const baseContext = {
  entity: "ent_test01",
  session: "ses_test01",
  device: "dev_phone_01",
  generation: GENERATION,
};

// Deterministic clock inside the proposal's validity window.
const T0 = Date.parse("2026-07-21T02:00:00Z");
let nowMs = T0;
const clock = () => nowMs;

function legacyToolRequest(overrides = {}) {
  return {
    request_id: "req-42-abc",
    runtime: "openclaw",
    runtime_session_id: "rs-1",
    tool: "openphone.messages.send",
    params: { to: "+15551234567", body: "on my way" },
    reason: "user asked to notify Dana",
    ...overrides,
  };
}

function propose(overrides = {}) {
  return proposeFromToolRequest(legacyToolRequest(overrides), {
    ...baseContext,
    risk: "high",
    clock,
  });
}

// --- canonical hashing (spec 8.1) -------------------------------------------
check("canonical json sorts keys at every depth", () => {
  assert.equal(
    canonicalJson({ z: { b: 2, a: 1 }, a: [3, { y: true, x: null }] }),
    '{"a":[3,{"x":null,"y":true}],"z":{"a":1,"b":2}}',
  );
});

check("params_hash matches the shared spec 8.1 vector", () => {
  assert.equal(
    paramsHash({ to: "+15551234567", body: "on my way" }),
    "sha256:1e920af2c02daa49a449d1ebe938e08f196a9dfa6a3c05b36adbabbd7387193b",
  );
});

check("tool names drop the openphone. prefix", () => {
  assert.equal(toolNameFromCommand("openphone.messages.send"), "messages.send");
  assert.equal(toolNameFromCommand("messages.send"), "messages.send");
});

// --- runtime.tool.requested -> action.propose --------------------------------
check("tool request maps to a structurally valid action.propose", () => {
  const proposal = propose();
  const verdict = validateMessage(proposal);
  assert.equal(verdict.ok, true, `${verdict.errorClass}: ${verdict.detail}`);
  assert.equal(proposal.type, "action.propose");
  assert.equal(proposal.payload.tool, "messages.send");
  assert.equal(proposal.payload.risk, "high");
  assert.equal(proposal.payload.params_hash, paramsHash(proposal.payload.params));
  assert.equal(proposal.correlation, "req-42-abc");
  assert.equal(proposal.payload.idempotency_key, "req-42-abc");
  assert.ok(proposal.payload.expires_at > proposal.ts, "expiry must be in the future");
});

// --- full approve -> execute lifecycle ---------------------------------------
check("approve then execute walks requested -> approved -> executed", () => {
  const machine = new ConformanceMachine(GENERATION);
  const proposal = propose();
  assert.equal(machine.step(proposal).actionState, "requested");

  nowMs = T0 + 5_000;
  const approve = actionMessageFromConfirmationResolution(
    { approved: true, confirmation_id: "runtime-confirm-1" },
    proposal,
    { ...baseContext, clock },
  );
  assert.equal(validateMessage(approve).ok, true);
  assert.equal(approve.type, "action.approve");
  assert.equal(approve.payload.params_hash, proposal.payload.params_hash);
  assert.equal(approve.payload.confirmation.mode, "user_confirmed");
  assert.equal(approve.payload.confirmation.ref, "runtime-confirm-1");
  const approveStep = machine.step(approve);
  assert.equal(approveStep.verdict, "accepted");
  assert.equal(approveStep.actionState, "approved");

  nowMs = T0 + 8_000;
  const result = resultFromToolResult(
    { request_id: "req-42-abc", status: "ok", result: { sent: true } },
    proposal,
    {
      ...baseContext,
      approvedParamsHash: approve.payload.params_hash,
      executedParams: proposal.payload.params,
      evidence: "audit-evt-77",
      clock,
    },
  );
  assert.equal(validateMessage(result).ok, true);
  assert.equal(result.payload.status, "executed");
  assert.equal(result.payload.error_class, null);
  assert.equal(result.payload.evidence, "audit-evt-77");
  const resultStep = machine.step(result);
  assert.equal(resultStep.verdict, "accepted");
  assert.equal(resultStep.actionState, "executed");
});

// --- user rejection is terminal ----------------------------------------------
check("user denial maps to action.reject and is terminal", () => {
  const machine = new ConformanceMachine(GENERATION);
  nowMs = T0;
  const proposal = propose({ request_id: "req-43-rej" });
  machine.step(proposal);

  nowMs = T0 + 2_000;
  const reject = actionMessageFromConfirmationResolution(
    { approved: false, confirmation_id: "runtime-confirm-2" },
    proposal,
    { ...baseContext, clock },
  );
  assert.equal(validateMessage(reject).ok, true);
  assert.equal(reject.type, "action.reject");
  assert.equal(reject.payload.reason_class, "user_denied");
  const rejectStep = machine.step(reject);
  assert.equal(rejectStep.verdict, "accepted");
  assert.equal(rejectStep.actionState, "rejected");

  // A later approval of the rejected action is a protocol violation.
  const lateApprove = actionMessageFromConfirmationResolution(
    { approved: true },
    proposal,
    { ...baseContext, clock },
  );
  const lateStep = machine.step(lateApprove);
  assert.equal(lateStep.verdict, "rejected");
  assert.equal(lateStep.actionState, "rejected");
});

// --- params_hash mismatch => binding_mismatch ---------------------------------
check("approve with tampered params is rejected as binding_mismatch", () => {
  const machine = new ConformanceMachine(GENERATION);
  nowMs = T0;
  const proposal = propose({ request_id: "req-44-bind" });
  machine.step(proposal);

  nowMs = T0 + 2_000;
  const tamperedApprove = actionMessageFromConfirmationResolution(
    {
      approved: true,
      executed_params: { to: "+15559999999", body: "on my way" },
    },
    proposal,
    { ...baseContext, clock },
  );
  assert.equal(validateMessage(tamperedApprove).ok, true);
  assert.notEqual(tamperedApprove.payload.params_hash, proposal.payload.params_hash);
  const step = machine.step(tamperedApprove);
  assert.equal(step.verdict, "rejected");
  assert.equal(step.errorClass, "binding_mismatch");
  assert.equal(step.actionState, "requested", "binding failure leaves the action requested (spec 8.3)");
});

check("executed params diverging from approval fail as binding_mismatch without executing", () => {
  nowMs = T0;
  const proposal = propose({ request_id: "req-45-exec" });
  const approvedHash = proposal.payload.params_hash;

  nowMs = T0 + 3_000;
  const result = resultFromToolResult(
    { request_id: "req-45-exec", status: "ok" },
    proposal,
    {
      ...baseContext,
      approvedParamsHash: approvedHash,
      executedParams: { to: "+15550000000", body: "on my way" },
      clock,
    },
  );
  assert.equal(validateMessage(result).ok, true);
  assert.equal(result.payload.status, "failed");
  assert.equal(result.payload.error_class, "binding_mismatch");
});

// --- expiry -------------------------------------------------------------------
check("approval after expires_at is rejected as action_expired", () => {
  const machine = new ConformanceMachine(GENERATION);
  nowMs = T0;
  const proposal = propose({ request_id: "req-46-exp" });
  machine.step(proposal);

  nowMs = Date.parse(proposal.payload.expires_at) + 60_000;
  const lateApprove = actionMessageFromConfirmationResolution(
    { approved: true },
    proposal,
    { ...baseContext, clock },
  );
  const step = machine.step(lateApprove);
  assert.equal(step.verdict, "rejected");
  assert.equal(step.errorClass, "action_expired");
  assert.equal(step.actionState, "expired");
});

check("execution attempted past expiry reports failed/action_expired", () => {
  nowMs = T0;
  const proposal = propose({ request_id: "req-47-exp" });
  nowMs = Date.parse(proposal.payload.expires_at) + 60_000;
  const result = resultFromToolResult(
    { request_id: "req-47-exp", status: "ok" },
    proposal,
    { ...baseContext, clock },
  );
  assert.equal(result.payload.status, "failed");
  assert.equal(result.payload.error_class, "action_expired");
});

// --- error path from the legacy bridge ----------------------------------------
check("legacy error results map to failed/internal", () => {
  const machine = new ConformanceMachine(GENERATION);
  nowMs = T0;
  const proposal = propose({ request_id: "req-48-err" });
  machine.step(proposal);
  nowMs = T0 + 1_000;
  machine.step(actionMessageFromConfirmationResolution(
    { approved: true }, proposal, { ...baseContext, clock },
  ));
  nowMs = T0 + 2_000;
  const result = resultFromToolResult(
    { request_id: "req-48-err", status: "error", error: { code: "tool_failed" } },
    proposal,
    { ...baseContext, clock },
  );
  assert.equal(result.payload.status, "failed");
  assert.equal(result.payload.error_class, "internal");
  const step = machine.step(result);
  assert.equal(step.verdict, "accepted");
  assert.equal(step.actionState, "failed");
});

// --- policy_auto confirmations --------------------------------------------------
check("trusted_actions resolutions map to policy_auto confirmation mode", () => {
  nowMs = T0;
  const proposal = propose({ request_id: "req-49-auto" });
  const approve = actionMessageFromConfirmationResolution(
    { approved: true },
    proposal,
    { ...baseContext, mode: "policy_auto", clock },
  );
  assert.equal(validateMessage(approve).ok, true);
  assert.equal(approve.payload.confirmation.mode, "policy_auto");
});

console.log(`ifp/1 adapter contract passed (${cases} cases).`);
