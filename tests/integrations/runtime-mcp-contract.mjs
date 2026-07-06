#!/usr/bin/env node

import assert from "node:assert/strict";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  handleRequest,
  SUPPORTED_PROTOCOL_VERSIONS,
} from "../../integrations/mcp-server/src/index.mjs";

const serverPath = fileURLToPath(
  new URL("../../integrations/mcp-server/src/index.mjs", import.meta.url),
);

const calls = [];
const fakeTransport = {
  invoke(name, args) {
    calls.push({ name, args });
    return { ok: true, name, args };
  },
};

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {},
  }, { transport: fakeTransport });
  assert.equal(response.result.serverInfo.name, "openphone-runtime");
  assert.ok(response.result.capabilities.tools);
  assert.equal(response.result.protocolVersion, SUPPORTED_PROTOCOL_VERSIONS[0]);
  // The initialize handshake advertises the runtime-protocol version range.
  const runtimeProtocol = response.result.serverInfo.runtimeProtocol;
  assert.equal(runtimeProtocol.name, "openphone-runtime-protocol");
  assert.ok(Number.isInteger(runtimeProtocol.min_version));
  assert.ok(Number.isInteger(runtimeProtocol.max_version));
  assert.ok(runtimeProtocol.min_version <= runtimeProtocol.max_version);
  assert.equal(runtimeProtocol.min_version, 1);
}

{
  // A supported client protocolVersion is echoed back.
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-06-18" },
  }, { transport: fakeTransport });
  assert.equal(response.result.protocolVersion, "2025-06-18");
}

{
  // An unsupported client protocolVersion falls back to the latest we support.
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "1999-01-01" },
  }, { transport: fakeTransport });
  assert.equal(response.result.protocolVersion, SUPPORTED_PROTOCOL_VERSIONS[0]);
}

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 2,
    method: "ping",
    params: {},
  }, { transport: fakeTransport });
  assert.deepEqual(response.result, {});
}

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 3,
    method: "tools/list",
    params: {},
  }, { transport: fakeTransport });
  assert.ok(response.result.tools.length > 10);
  assert.ok(response.result.tools.some((tool) => tool.name === "openphone.screen.get"));
  assert.ok(response.result.tools.every((tool) =>
    tool.inputSchema?.type === "object"
      && tool.outputSchema?.type === "object"
      && typeof tool.annotations?.readOnlyHint === "boolean"
      && typeof tool.annotations?.destructiveHint === "boolean"));
}

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "openphone.screen.get",
      arguments: { include_screenshot: false },
    },
  }, { transport: fakeTransport });
  assert.equal(response.result.isError, false);
  assert.equal(response.result.structuredContent.name, "openphone.screen.get");
  assert.deepEqual(calls.at(-1), {
    name: "openphone.screen.get",
    args: { include_screenshot: false },
  });
}

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 5,
    method: "tools/call",
    params: {
      name: "canvas.snapshot",
      arguments: { include_screenshot: true },
    },
  }, { transport: fakeTransport });
  assert.equal(response.result.isError, false);
  assert.deepEqual(calls.at(-1), {
    name: "canvas.snapshot",
    args: { include_screenshot: true },
  });
}

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 6,
    method: "tools/call",
    params: {
      name: "openphone.unknown",
      arguments: {},
    },
  }, { transport: fakeTransport });
  assert.equal(response.result.isError, true);
}

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    id: 7,
    method: "runtime/list",
    params: {},
  }, { transport: fakeTransport });
  assert.equal(response.error.code, -32601);
}

{
  const response = await handleRequest({
    jsonrpc: "2.0",
    method: "notifications/initialized",
    params: {},
  }, { transport: fakeTransport });
  assert.equal(response, null);
}

{
  const response = await handleRequest("not an object", { transport: fakeTransport });
  assert.equal(response.error.code, -32600);
}

{
  // Stdio smoke test: a real newline-delimited JSON handshake against the
  // server process (initialize -> notifications/initialized -> tools/list).
  const server = spawn(process.execPath, [serverPath], {
    env: { ...process.env, OPENPHONE_DRY_RUN: "1" },
    stdio: ["pipe", "pipe", "inherit"],
  });

  const responses = [];
  let stdoutBuffer = "";
  const waiters = [];
  server.stdout.setEncoding("utf8");
  server.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    let newline = stdoutBuffer.indexOf("\n");
    while (newline >= 0) {
      const line = stdoutBuffer.slice(0, newline).trim();
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      if (line) {
        responses.push(JSON.parse(line));
        const waiter = waiters.shift();
        if (waiter) {
          waiter();
        }
      }
      newline = stdoutBuffer.indexOf("\n");
    }
  });

  const nextResponse = async () => {
    if (responses.length === 0) {
      await new Promise((resolve) => waiters.push(resolve));
    }
    return responses.shift();
  };

  const send = (message) => {
    server.stdin.write(`${JSON.stringify(message)}\n`);
  };

  try {
    send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "contract-test", version: "0.0.0" },
      },
    });
    const initialize = await nextResponse();
    assert.equal(initialize.id, 1);
    assert.equal(initialize.result.protocolVersion, "2025-06-18");
    assert.equal(initialize.result.serverInfo.name, "openphone-runtime");
    assert.equal(initialize.result.serverInfo.runtimeProtocol.name, "openphone-runtime-protocol");
    assert.equal(initialize.result.serverInfo.runtimeProtocol.min_version, 1);

    send({ jsonrpc: "2.0", method: "notifications/initialized" });

    send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    const toolsList = await nextResponse();
    assert.equal(toolsList.id, 2);
    assert.ok(toolsList.result.tools.length > 10);
    assert.equal(responses.length, 0);
  } finally {
    server.kill();
    await once(server, "exit");
  }
}
