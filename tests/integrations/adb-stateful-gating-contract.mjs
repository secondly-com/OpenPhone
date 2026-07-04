#!/usr/bin/env node

import assert from "node:assert/strict";
import {
  OpenPhoneAdbTransport,
  confirmationMap,
  loadManifestCommands,
} from "../../integrations/adb/openphone-adb-transport.mjs";

delete process.env.OPENPHONE_DRY_RUN;
delete process.env.OPENPHONE_ADB_ALLOW_STATEFUL;

class RecordingTransport extends OpenPhoneAdbTransport {
  constructor(options = {}) {
    super(options);
    this.shellCalls = [];
  }

  shell(args) {
    this.shellCalls.push(args);
    return "";
  }

  exec(args) {
    this.shellCalls.push(args);
    return Buffer.from("");
  }
}

// The manifest is the source of truth for confirmation gating.
{
  const confirmations = confirmationMap(loadManifestCommands());
  assert.equal(confirmations.get("openphone.screen.get"), "none");
  assert.equal(confirmations.get("canvas.snapshot"), "none");
  assert.equal(confirmations.get("openphone.ui.tap"), "ask_before_action");
  assert.equal(confirmations.get("openphone.messages.send"), "always");
}

// State-changing tools are refused by default; ADB is never touched.
{
  const transport = new RecordingTransport();
  for (const name of [
    "openphone.ui.tap",
    "openphone.ui.type_text",
    "openphone.clipboard.set",
    "openphone.url.open",
    "openphone.app.open",
    "openphone.messages.send",
  ]) {
    const result = transport.invoke(name, {});
    assert.equal(result.ok, false, `${name} must be refused by default`);
    assert.equal(result.error.code, "stateful_tool_refused");
    assert.match(result.error.message, /OPENPHONE_ADB_ALLOW_STATEFUL/u);
    assert.match(result.error.message, /OPENPHONE_DRY_RUN/u);
  }
  assert.deepEqual(transport.shellCalls, []);
}

// Read-only tools still execute without any opt-in.
{
  const transport = new RecordingTransport();
  const result = transport.invoke("openphone.apps.search", { query: "" });
  assert.equal(result.ok, true);
  assert.ok(transport.shellCalls.length > 0);
}

// The allowStateful constructor option opts in programmatically.
{
  const transport = new RecordingTransport({ allowStateful: true });
  const result = transport.invoke("openphone.ui.tap", { x: 10, y: 20 });
  assert.deepEqual(result, { ok: true, x: 10, y: 20 });
  assert.deepEqual(transport.shellCalls, [["input", "tap", "10", "20"]]);
}

// OPENPHONE_ADB_ALLOW_STATEFUL=1 (or true) opts in per-session.
{
  process.env.OPENPHONE_ADB_ALLOW_STATEFUL = "1";
  try {
    const transport = new RecordingTransport();
    const result = transport.invoke("openphone.ui.type_text", { text: "hi" });
    assert.equal(result.ok, true);
    assert.deepEqual(transport.shellCalls, [["input", "text", "hi"]]);
  } finally {
    delete process.env.OPENPHONE_ADB_ALLOW_STATEFUL;
  }
}

// An explicit allowStateful option overrides the environment.
{
  process.env.OPENPHONE_ADB_ALLOW_STATEFUL = "1";
  try {
    const transport = new RecordingTransport({ allowStateful: false });
    const result = transport.invoke("openphone.ui.tap", { x: 1, y: 2 });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "stateful_tool_refused");
    assert.deepEqual(transport.shellCalls, []);
  } finally {
    delete process.env.OPENPHONE_ADB_ALLOW_STATEFUL;
  }
}

// Dry-run keeps precedence: nothing executes, even when stateful is allowed.
{
  const transport = new RecordingTransport({ dryRun: true, allowStateful: true });
  const result = transport.invoke("openphone.ui.tap", { x: 3, y: 4 });
  assert.deepEqual(result, {
    ok: true,
    dry_run: true,
    command: "openphone.ui.tap",
    args: { x: 3, y: 4 },
  });
  assert.deepEqual(transport.shellCalls, []);
}

// Dry-run also covers stateful tools without opt-in (safe exploration).
{
  const transport = new RecordingTransport({ dryRun: true });
  const result = transport.invoke("openphone.clipboard.set", { text: "x" });
  assert.equal(result.dry_run, true);
  assert.deepEqual(transport.shellCalls, []);
}
