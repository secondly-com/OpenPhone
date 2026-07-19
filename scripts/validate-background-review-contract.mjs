#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const confirmationSchema = readJson("schemas/background-confirmation.schema.json");
const jobSchema = readJson("schemas/agent-job.schema.json");

function readJson(relative) {
  return JSON.parse(fs.readFileSync(path.join(root, relative), "utf8"));
}

function fail(message) {
  throw new Error(message);
}

function canonical(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (typeof value === "object") {
    return `{${Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function sha256(value) {
  return crypto.createHash("sha256").update(value.trim()).digest("hex");
}

function validateShallowSchema(value, schema, label) {
  if (!value || Array.isArray(value) || typeof value !== "object") {
    fail(`${label} must be an object`);
  }
  for (const required of schema.required ?? []) {
    if (!(required in value)) fail(`${label} is missing ${required}`);
  }
  if (schema.additionalProperties === false) {
    for (const key of Object.keys(value)) {
      if (!(key in schema.properties)) fail(`${label} has unknown property ${key}`);
    }
  }
  for (const [key, property] of Object.entries(schema.properties ?? {})) {
    if (!(key in value)) continue;
    const item = value[key];
    if (property.type === "object"
        && (!item || Array.isArray(item) || typeof item !== "object")) {
      fail(`${label}.${key} must be an object`);
    }
    if (property.type === "string" && typeof item !== "string") {
      fail(`${label}.${key} must be a string`);
    }
    if (property.type === "integer" && !Number.isSafeInteger(item)) {
      fail(`${label}.${key} must be an integer`);
    }
    if (property.type === "boolean" && typeof item !== "boolean") {
      fail(`${label}.${key} must be a boolean`);
    }
    if ("const" in property && item !== property.const) {
      fail(`${label}.${key} must equal ${property.const}`);
    }
    if (property.enum && !property.enum.includes(item)) {
      fail(`${label}.${key} is outside its enum`);
    }
    if (typeof item === "string") {
      if (property.minLength && item.length < property.minLength) {
        fail(`${label}.${key} is too short`);
      }
      if (property.maxLength && item.length > property.maxLength) {
        fail(`${label}.${key} is too long`);
      }
      if (property.pattern && !(new RegExp(property.pattern)).test(item)) {
        fail(`${label}.${key} does not match its pattern`);
      }
    }
    if (Number.isSafeInteger(item) && property.minimum !== undefined
        && item < property.minimum) {
      fail(`${label}.${key} is below its minimum`);
    }
  }
}

function containsBlockedMaterial(value) {
  if (Array.isArray(value)) return value.some(containsBlockedMaterial);
  if (value && typeof value === "object") {
    return Object.entries(value).some(([key, nested]) => {
      const lower = key.toLowerCase();
      return lower.includes("api_key")
        || lower.includes("authorization")
        || lower === "auth"
        || lower.includes("credential")
        || lower.includes("private_key")
        || lower.includes("token")
        || lower.includes("secret")
        || lower.includes("password")
        || lower.includes("cookie")
        || lower.includes("screenshot")
        || containsBlockedMaterial(nested);
    });
  }
  if (typeof value === "string") {
    const clean = value.trim();
    const lower = clean.toLowerCase();
    return lower.startsWith("bearer ")
      || lower.startsWith("basic ")
      || lower.includes("-----begin private key-----")
      || lower.startsWith("data:image/")
      || (clean.length > 2048 && /^[A-Za-z0-9+/=_-]+$/.test(clean));
  }
  return false;
}

function validateConfirmation(request) {
  validateShallowSchema(request, confirmationSchema, "background confirmation");
  if (request.phone_session_id !== `background-job:${request.job_id}`) {
    fail("confirmation crosses its bound job session");
  }
  if (request.expires_at <= request.created_at
      || request.expires_at - request.created_at > 15 * 60 * 1000) {
    fail("confirmation expiry exceeds the bounded review window");
  }
  if (containsBlockedMaterial(request.params)) {
    fail("confirmation persists blocked secret or screenshot material");
  }
  if (JSON.stringify(request).length > 12000) {
    fail("confirmation exceeds its persisted bound");
  }
  const paramsDigest = sha256(
    `${request.tool}\n${canonical(request.params)}`,
  );
  if (request.params_digest !== paramsDigest) {
    fail("confirmation params digest does not match exact parameters");
  }
  const bindingDigest = sha256([
    request.job_id,
    request.runtime,
    request.phone_session_id,
    request.tool,
    request.params_digest,
    request.idempotency_key,
    request.expires_at,
  ].join("\n"));
  if (request.binding_digest !== bindingDigest) {
    fail("confirmation binding digest does not match bound request");
  }
}

function validateAwaitingJob(job) {
  validateShallowSchema(job, jobSchema, "agent job");
  if (job.status !== "awaiting_review" || job.phase !== "awaiting_review") {
    fail("fixture must persist the awaiting-review lifecycle");
  }
  if (!job.pending_confirmation_id || !job.resume_token) {
    fail("awaiting job must persist confirmation and resume identifiers");
  }
  validateConfirmation(job.pending_tool_request_json);
  const request = job.pending_tool_request_json;
  const checkpoint = job.checkpoint_json;
  for (const [checkpointKey, requestKey] of [
    ["job_id", "job_id"],
    ["tool", "tool"],
    ["params_digest", "params_digest"],
    ["binding_digest", "binding_digest"],
    ["idempotency_key", "idempotency_key"],
  ]) {
    if (checkpoint[checkpointKey] !== request[requestKey]) {
      fail(`checkpoint ${checkpointKey} drifted from pending request`);
    }
  }
  if (checkpoint.resume_token !== job.resume_token
      || checkpoint.resume_pending !== false) {
    fail("awaiting checkpoint has an invalid resume binding");
  }
  const checkpointSafetyView = { ...checkpoint };
  delete checkpointSafetyView.resume_token;
  if (JSON.stringify(checkpoint).length > 12000
      || containsBlockedMaterial(checkpointSafetyView)) {
    fail("checkpoint is unsafe or unbounded");
  }
}

if (confirmationSchema.properties.schema.const
    !== "openphone.background_confirmation.v1") {
  fail("background confirmation schema marker drifted");
}
for (const status of [
  "queued",
  "running",
  "waiting",
  "awaiting_review",
  "paused",
  "completed",
  "failed",
  "stopped",
]) {
  if (!jobSchema.properties.status.enum.includes(status)) {
    fail(`agent job schema is missing lifecycle state ${status}`);
  }
}

validateAwaitingJob(readJson(
  "tests/fixtures/jobs/background-awaiting-review.json",
));
for (const name of [
  "invalid-background-review-tampered.json",
  "invalid-background-review-secret.json",
]) {
  let rejected = false;
  try {
    validateConfirmation(readJson(`tests/fixtures/jobs/${name}`));
  } catch {
    rejected = true;
  }
  if (!rejected) fail(`invalid review fixture was accepted: ${name}`);
}

const storeSource = fs.readFileSync(path.join(
  root,
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/jobs/AgentJobStore.java",
), "utf8");
const managerSource = fs.readFileSync(path.join(
  root,
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/jobs/BackgroundJobReviewManager.java",
), "utf8");
if (!storeSource.includes("REVIEW_LOCK")
    || !storeSource.includes('.put("review_state", "resolving")')) {
  fail("background review claim must atomically gate duplicate taps");
}
if (managerSource.indexOf("claimReview(") < 0
    || managerSource.indexOf("claimReview(")
      > managerSource.indexOf("executor.execute(")) {
  fail("tool execution must happen only after an atomic review claim");
}
const auditMethod = managerSource.slice(
  managerSource.indexOf("private static void recordAudit"),
);
if (auditMethod.includes('.put("params",')) {
  fail("background review audit must not persist raw tool parameters");
}

console.log("Background review contract checks passed.");
