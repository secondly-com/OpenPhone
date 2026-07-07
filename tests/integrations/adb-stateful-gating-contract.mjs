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
    "openphone.ui.tap_element",
    "openphone.ui.long_press",
    "openphone.ui.long_press_element",
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

// New ADB read-only approximations execute without unresolved helper failures.
{
  const transport = new RecordingTransport();
  const screen = transport.invoke("openphone.screen.get", {});
  assert.equal(screen.ok, true);
  assert.deepEqual(screen.interactive_elements, []);

  const status = transport.invoke("openphone.device.status", {});
  assert.equal(status.ok, true);
  assert.equal(status.source, "adb");
  assert.equal(status.battery.status, "unknown");
  assert.equal(status.connectivity.airplane_mode, false);

  const watchers = transport.invoke("openphone.watchers.list", {});
  assert.equal(watchers.ok, false);
  assert.equal(watchers.error.code, "unsupported_adb_state");

  const jobs = transport.invoke("openphone.jobs.list", {});
  assert.equal(jobs.ok, false);
  assert.equal(jobs.error.code, "unsupported_adb_state");
}

// The allowStateful constructor option opts in programmatically.
{
  const transport = new RecordingTransport({ allowStateful: true });
  const result = transport.invoke("openphone.ui.tap", { x: 10, y: 20 });
  assert.deepEqual(result, { ok: true, x: 10, y: 20 });
  assert.deepEqual(transport.shellCalls, [["input", "tap", "10", "20"]]);
}

// Element-targeted actions resolve the current UI dump before issuing input.
{
  const transport = new RecordingTransport({ allowStateful: true });
  transport.exec = (args) => {
    transport.shellCalls.push(args);
    return Buffer.from(
      '<hierarchy><node text="OK" content-desc="Confirm" resource-id="com.example:id/ok" '
      + 'class="android.widget.Button" clickable="true" enabled="true" '
      + 'bounds="[10,20][110,220]" /></hierarchy>',
    );
  };

  const tap = transport.invoke("openphone.ui.tap_element", { element_id: "el-1" });
  assert.equal(tap.ok, true);
  assert.deepEqual(tap, { ok: true, element_id: "el-1", x: 60, y: 120 });
  assert.deepEqual(transport.shellCalls.at(-1), ["input", "tap", "60", "120"]);

  const longPress = transport.invoke("openphone.ui.long_press_element", {
    element_id: "com.example:id/ok",
    duration_ms: 750,
  });
  assert.equal(longPress.ok, true);
  assert.equal(longPress.duration_ms, 750);
  assert.deepEqual(
    transport.shellCalls.at(-1),
    ["input", "swipe", "60", "120", "60", "120", "750"],
  );
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
