/**
 * VENDORED from silentspeech-app packages/interfaces-protocol/ts/src/validator.ts
 * (rewrite/interfaces-v1, ifp/1 v1.0.0-draft). Do not edit here; upstream is
 * the source of truth until the fixture corpus freezes (ADR 0004). Re-vendor
 * by copying the upstream file and re-running scripts/check.sh.
 */
/**
 * Structural validation of ifp/1 envelopes.
 *
 * Dependency-free by design: rules are transcribed from
 * schemas/ifp-1.schema.json, and tests assert against the shared fixture
 * corpus, so drift between schema and code shows up as a fixture failure.
 * Must produce verdicts identical to the Python validator (spec §11).
 */

export const ERROR_CLASSES = new Set([
  "unsupported_version",
  "invalid_envelope",
  "unauthorized_device",
  "pairing_failed",
  "unknown_type",
  "stale_generation",
  "ordering_violation",
  "action_expired",
  "binding_mismatch",
  "capability_missing",
  "policy_denied",
  "user_denied",
  "rate_limited",
  "internal",
]);

const CONSENT_LABELS = new Set([
  "transient_inference",
  "product_operation",
  "user_memory",
  "research_contribution",
  "personal_model_training",
  "shared_model_training",
  "operational_audit",
]);

const RETENTION_LABELS = new Set(["transient", "standard", "extended", "permanent"]);

const ACTION_REJECT_REASONS = new Set([
  "capability_missing",
  "policy_denied",
  "user_denied",
  "expired",
  "other",
]);

const RISK_LEVELS = new Set(["low", "medium", "high"]);

const ENTITYLESS_TYPES = new Set(["pair.request", "control.hello"]);

const ID_RE = /^[a-z]+_[A-Za-z0-9]{6,64}$/;
const TYPE_RE = /^[a-z][a-z0-9_.]*$/;
const TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
const SHA256_RE = /^sha256:[0-9a-f]{64}$/;
const PUBKEY_RE = /^[A-Za-z0-9_-]{43}$/;
const ENTITY_RE = /^ent_[A-Za-z0-9]{6,64}$/;
const SESSION_RE = /^ses_[A-Za-z0-9]{6,64}$/;
const DEVICE_RE = /^dev_[A-Za-z0-9_]{4,64}$/;

const ENVELOPE_FIELDS = new Set([
  "ifp",
  "id",
  "ts",
  "type",
  "entity",
  "session",
  "device",
  "generation",
  "parent",
  "correlation",
  "provenance",
  "labels",
  "payload",
  "ext",
]);

export interface ValidationResult {
  ok: boolean;
  errorClass: string | null;
  detail: string | null;
}

const accept = (): ValidationResult => ({ ok: true, errorClass: null, detail: null });
const reject = (errorClass: string, detail: string): ValidationResult => ({
  ok: false,
  errorClass,
  detail,
});

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const isStr = (v: unknown): v is string => typeof v === "string";
const isInt = (v: unknown): v is number => Number.isInteger(v);

function checkProvenance(prov: unknown): string | null {
  if (!isObj(prov)) return "provenance must be an object";
  if (!isStr(prov.sensor) || !prov.sensor) return "provenance.sensor required";
  if (!isStr(prov.captured_at) || !TS_RE.test(prov.captured_at)) {
    return "provenance.captured_at must be RFC 3339";
  }
  if (prov.chain !== undefined && prov.chain !== null) {
    if (!Array.isArray(prov.chain)) return "provenance.chain must be a list";
    for (const entry of prov.chain) {
      if (!isObj(entry) || !isStr(entry.stage)) return "provenance.chain entries require stage";
    }
  }
  return null;
}

function checkLabels(labels: unknown): string | null {
  if (!isObj(labels)) return "labels must be an object";
  if (!CONSENT_LABELS.has(labels.consent as string)) return "labels.consent not in registry";
  if (!RETENTION_LABELS.has(labels.retention as string)) return "labels.retention not in registry";
  return null;
}

function checkCapabilities(caps: unknown): string | null {
  if (!Array.isArray(caps)) return "capabilities must be a list";
  for (const cap of caps) {
    if (!isObj(cap) || !isStr(cap.type) || !cap.type) return "capability entries require type";
  }
  return null;
}

export function validateMessage(msg: unknown): ValidationResult {
  if (!isObj(msg)) return reject("invalid_envelope", "message must be an object");

  if (msg.ifp !== "1") return reject("unsupported_version", "ifp must be '1'");

  for (const key of Object.keys(msg)) {
    if (!ENVELOPE_FIELDS.has(key)) {
      return reject("invalid_envelope", `unknown envelope field: ${key}`);
    }
  }

  for (const field of ["id", "ts", "type"] as const) {
    if (!isStr(msg[field])) return reject("invalid_envelope", `${field} required`);
  }
  if (!ID_RE.test(msg.id as string)) return reject("invalid_envelope", "id format invalid");
  if (!TS_RE.test(msg.ts as string)) return reject("invalid_envelope", "ts must be RFC 3339");
  if (!TYPE_RE.test(msg.type as string)) return reject("invalid_envelope", "type format invalid");

  const payload = msg.payload;
  if (!isObj(payload)) return reject("invalid_envelope", "payload must be an object");

  const ext = msg.ext ?? {};
  if (!isObj(ext)) return reject("invalid_envelope", "ext must be an object");
  for (const key of Object.keys(ext)) {
    if (!key.startsWith("x-")) return reject("invalid_envelope", `ext key without x- prefix: ${key}`);
  }

  const mtype = msg.type as string;
  const entity = msg.entity ?? null;
  const session = msg.session ?? null;
  const device = msg.device ?? null;
  const generation = msg.generation ?? null;

  if (entity !== null && (!isStr(entity) || !ENTITY_RE.test(entity))) {
    return reject("invalid_envelope", "entity format invalid");
  }
  if (session !== null && (!isStr(session) || !SESSION_RE.test(session))) {
    return reject("invalid_envelope", "session format invalid");
  }
  if (device !== null && (!isStr(device) || !DEVICE_RE.test(device))) {
    return reject("invalid_envelope", "device format invalid");
  }
  if (generation !== null && (!isInt(generation) || (generation as number) < 1)) {
    return reject("invalid_envelope", "generation must be int >= 1");
  }

  if (entity === null && !ENTITYLESS_TYPES.has(mtype)) {
    return reject("invalid_envelope", "entity required on this message type");
  }

  if (mtype.startsWith("event.")) {
    if (session === null) return reject("invalid_envelope", "event requires session");
    if (generation === null) return reject("invalid_envelope", "event requires generation");
    const provErr = checkProvenance(msg.provenance);
    if (provErr) return reject("invalid_envelope", provErr);
    const labelErr = checkLabels(msg.labels);
    if (labelErr) return reject("invalid_envelope", labelErr);
    const seq = payload.seq;
    if (!isInt(seq) || (seq as number) < 0) {
      return reject("invalid_envelope", "event payload.seq must be int >= 0");
    }
    if (!isStr(payload.dedup) || !payload.dedup) {
      return reject("invalid_envelope", "event payload.dedup required");
    }
  }

  if (mtype.startsWith("action.") && session === null) {
    return reject("invalid_envelope", "action requires session");
  }

  if ((mtype === "action.approve" || mtype === "action.result") && generation === null) {
    return reject("invalid_envelope", `${mtype} requires generation`);
  }

  if (mtype === "action.propose") {
    for (const field of ["action_id", "tool", "params", "params_hash", "risk", "idempotency_key", "expires_at"]) {
      if (!(field in payload)) return reject("invalid_envelope", `action.propose payload.${field} required`);
    }
    if (!isObj(payload.params)) return reject("invalid_envelope", "params must be an object");
    if (!isStr(payload.params_hash) || !SHA256_RE.test(payload.params_hash)) {
      return reject("invalid_envelope", "params_hash must be sha256:<hex64>");
    }
    if (!RISK_LEVELS.has(payload.risk as string)) return reject("invalid_envelope", "risk not in registry");
    if (!isStr(payload.expires_at) || !TS_RE.test(payload.expires_at)) {
      return reject("invalid_envelope", "expires_at must be RFC 3339");
    }
    if (!isStr(payload.tool) || !payload.tool) return reject("invalid_envelope", "tool required");
    if (!isStr(payload.idempotency_key) || !payload.idempotency_key) {
      return reject("invalid_envelope", "idempotency_key required");
    }
  }

  if (mtype === "action.approve") {
    for (const field of ["action_id", "params_hash", "confirmation"]) {
      if (!(field in payload)) return reject("invalid_envelope", `action.approve payload.${field} required`);
    }
    if (!isStr(payload.params_hash) || !SHA256_RE.test(payload.params_hash)) {
      return reject("invalid_envelope", "params_hash must be sha256:<hex64>");
    }
    const conf = payload.confirmation;
    if (!isObj(conf) || (conf.mode !== "user_confirmed" && conf.mode !== "policy_auto")) {
      return reject("invalid_envelope", "confirmation.mode invalid");
    }
  }

  if (mtype === "action.reject") {
    if (!isStr(payload.action_id)) return reject("invalid_envelope", "action.reject payload.action_id required");
    if (!ACTION_REJECT_REASONS.has(payload.reason_class as string)) {
      return reject("invalid_envelope", "reason_class not in registry");
    }
  }

  if (mtype === "action.result") {
    if (!isStr(payload.action_id)) return reject("invalid_envelope", "action.result payload.action_id required");
    if (payload.status !== "executed" && payload.status !== "failed") {
      return reject("invalid_envelope", "status invalid");
    }
    const errClass = payload.error_class ?? null;
    if (errClass !== null && !ERROR_CLASSES.has(errClass as string)) {
      return reject("invalid_envelope", "error_class not in registry");
    }
  }

  if (mtype === "action.cancel") {
    if (!isStr(payload.action_id)) return reject("invalid_envelope", "action.cancel payload.action_id required");
  }

  if (mtype === "pair.request") {
    for (const field of ["pairing_code", "public_key", "capabilities"]) {
      if (!(field in payload)) return reject("invalid_envelope", `pair.request payload.${field} required`);
    }
    if (!isStr(payload.pairing_code) || payload.pairing_code.length < 6) {
      return reject("invalid_envelope", "pairing_code too short");
    }
    if (!isStr(payload.public_key) || !PUBKEY_RE.test(payload.public_key)) {
      return reject("invalid_envelope", "public_key must be 32 bytes base64url");
    }
    const capErr = checkCapabilities(payload.capabilities);
    if (capErr) return reject("invalid_envelope", capErr);
  }

  if (mtype === "control.hello") {
    for (const field of ["device_id", "proof", "capabilities", "protocol"]) {
      if (!(field in payload)) return reject("invalid_envelope", `control.hello payload.${field} required`);
    }
    if (!isStr(payload.proof) || !payload.proof) return reject("invalid_envelope", "proof required");
    const capErr = checkCapabilities(payload.capabilities);
    if (capErr) return reject("invalid_envelope", capErr);
    const proto = payload.protocol;
    if (
      !isObj(proto) ||
      !isInt(proto.min) ||
      !isInt(proto.max) ||
      (proto.min as number) < 1 ||
      (proto.max as number) < (proto.min as number)
    ) {
      return reject("invalid_envelope", "protocol range invalid");
    }
  }

  if (mtype === "error") {
    if (!ERROR_CLASSES.has(payload.class as string)) {
      return reject("invalid_envelope", "error class not in registry");
    }
  }

  return accept();
}
