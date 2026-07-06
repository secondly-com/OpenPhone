#!/usr/bin/env node

import assert from "node:assert/strict";
import { main } from "../../integrations/cli/src/index.mjs";

function captureIo() {
  let stdout = "";
  let stderr = "";
  return {
    io: {
      stdout: { write(value) { stdout += value; } },
      stderr: { write(value) { stderr += value; } },
    },
    stdout() {
      return stdout;
    },
    stderr() {
      return stderr;
    },
  };
}

{
  // `info --json` advertises the supported runtime-protocol version range.
  const capture = captureIo();
  const code = await main(["info", "--json"], capture.io);
  assert.equal(code, 0);
  const parsed = JSON.parse(capture.stdout());
  assert.equal(parsed.name, "openphone-runtime-cli");
  assert.equal(parsed.runtime_protocol.name, "openphone-runtime-protocol");
  assert.equal(parsed.runtime_protocol.min_version, 1);
  assert.ok(Number.isInteger(parsed.runtime_protocol.max_version));
  assert.ok(parsed.runtime_protocol.min_version <= parsed.runtime_protocol.max_version);
  assert.ok(parsed.commands > 10);
  assert.equal(capture.stderr(), "");
}

{
  const capture = captureIo();
  const code = await main(["tool", "list", "--json"], capture.io);
  assert.equal(code, 0);
  const parsed = JSON.parse(capture.stdout());
  assert.ok(parsed.tools.length > 10);
  assert.ok(parsed.tools.some((tool) => tool.name === "openphone.screen.get"));
  assert.ok(parsed.tools.every((tool) =>
    typeof tool.name === "string"
      && typeof tool.description === "string"
      && tool.input_schema?.type === "object"));
  assert.equal(capture.stderr(), "");
}

{
  const capture = captureIo();
  const code = await main([
    "tool",
    "invoke",
    "openphone.screen.get",
    "{\"include_screenshot\":false}",
    "--dry-run",
    "--json",
  ], capture.io);
  assert.equal(code, 0);
  const parsed = JSON.parse(capture.stdout());
  assert.equal(parsed.dry_run, true);
  assert.equal(parsed.command, "openphone.screen.get");
  assert.deepEqual(parsed.args, { include_screenshot: false });
}

{
  const capture = captureIo();
  const code = await main([
    "tool",
    "invoke",
    "canvas.snapshot",
    "{\"include_screenshot\":true}",
    "--dry-run",
    "--json",
  ], capture.io);
  assert.equal(code, 0);
  const parsed = JSON.parse(capture.stdout());
  assert.equal(parsed.command, "canvas.snapshot");
  assert.deepEqual(parsed.args, { include_screenshot: true });
}

{
  const capture = captureIo();
  const code = await main([
    "runtime",
    "list",
    "--dry-run",
    "--json",
  ], capture.io);
  assert.equal(code, 0);
  const parsed = JSON.parse(capture.stdout());
  assert.ok(parsed.runtimes.some((runtime) => runtime.name === "builtin"
    && runtime.configured === true));
  assert.ok(parsed.runtimes.some((runtime) => runtime.name === "openclaw"));
}

{
  const capture = captureIo();
  const code = await main([
    "runtime",
    "select",
    "--chat",
    "openclaw",
    "--volume",
    "phone",
    "--dry-run",
    "--json",
  ], capture.io);
  assert.equal(code, 0);
  const parsed = JSON.parse(capture.stdout());
  assert.deepEqual(parsed.changes, {
    chat_runtime: "openclaw",
    volume_runtime: "builtin",
  });
}

{
  const capture = captureIo();
  const code = await main([
    "runtime",
    "configure",
    "openclaw",
    "--url",
    "ws://127.0.0.1:18789",
    "--token",
    "test-token",
    "--label",
    "OpenClaw Dev",
    "--dry-run",
    "--json",
  ], capture.io);
  assert.equal(code, 0);
  const parsed = JSON.parse(capture.stdout());
  assert.deepEqual(parsed.changes, {
    runtimes_enabled: true,
    openclaw_url: "ws://127.0.0.1:18789",
    openclaw_token_set: true,
    openclaw_label: "OpenClaw Dev",
  });
}

{
  const capture = captureIo();
  const code = await main([
    "tool",
    "invoke",
    "openphone.screen.get",
    "[]",
    "--dry-run",
    "--json",
  ], capture.io);
  assert.equal(code, 1);
  const parsed = JSON.parse(capture.stdout());
  assert.match(parsed.error.message, /must be a JSON object/u);
}

{
  const capture = captureIo();
  const code = await main([
    "runtime",
    "select",
    "--chat",
    "unknown",
    "--dry-run",
    "--json",
  ], capture.io);
  assert.equal(code, 1);
  const parsed = JSON.parse(capture.stdout());
  assert.match(parsed.error.message, /unsupported runtime/u);
}
