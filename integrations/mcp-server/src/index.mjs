#!/usr/bin/env node

import { OpenPhoneAdbTransport } from "../adb/openphone-adb-transport.mjs";
import {
  loadCommands,
  mcpTools,
  resolveCommand,
  textContent,
} from "../runtime/protocol/openphone-runtime-tools.mjs";

export const SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18"];
const LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0];
const SERVER_INFO = { name: "openphone-runtime", version: "0.1.0" };

const commands = loadCommands();

export function negotiateProtocolVersion(requested) {
  if (SUPPORTED_PROTOCOL_VERSIONS.includes(requested)) {
    return requested;
  }
  return LATEST_PROTOCOL_VERSION;
}

export async function handleRequest(message, context = {}) {
  if (!message || typeof message !== "object") {
    return errorResponse(null, -32600, "Invalid Request");
  }
  if (message.method?.startsWith("notifications/")) {
    return null;
  }
  const id = message.id ?? null;
  const transport = context.transport ?? new OpenPhoneAdbTransport();
  try {
    switch (message.method) {
      case "initialize":
        return resultResponse(id, {
          protocolVersion: negotiateProtocolVersion(message.params?.protocolVersion),
          capabilities: {
            tools: { listChanged: false },
          },
          serverInfo: SERVER_INFO,
        });
      case "ping":
        return resultResponse(id, {});
      case "tools/list":
        return resultResponse(id, { tools: mcpTools(commands) });
      case "tools/call":
        return resultResponse(id, await callTool(message.params ?? {}, transport));
      default:
        return errorResponse(id, -32601, `Method not found: ${message.method ?? ""}`);
    }
  } catch (error) {
    return errorResponse(id, -32000, error.message);
  }
}

export async function serve(options = {}) {
  const transport = options.transport ?? new OpenPhoneAdbTransport();
  let buffer = "";
  let queue = Promise.resolve();
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    // Buffer mutation must stay synchronous: extract every complete line
    // before awaiting anything, then process messages serially on a promise
    // chain so interleaved chunks cannot drop or reorder responses.
    buffer += chunk;
    const lines = [];
    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      lines.push(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      newline = buffer.indexOf("\n");
    }
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (!line) {
        continue;
      }
      queue = queue.then(async () => {
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          writeMessage(errorResponse(null, -32700, "Parse error"));
          return;
        }
        const response = await handleRequest(message, { transport });
        if (response) {
          writeMessage(response);
        }
      });
    }
  });
  process.stdin.resume();
}

async function callTool(params, transport) {
  const name = params.name;
  if (!name || typeof name !== "string") {
    return {
      isError: true,
      content: textContent({ error: { code: "missing_tool_name", message: "Tool name is required." } }),
    };
  }
  const command = resolveCommand(name, commands);
  if (!command || !command.mcp) {
    return {
      isError: true,
      content: textContent({ error: { code: "unknown_tool", message: `Unknown OpenPhone tool: ${name}` } }),
    };
  }
  const result = transport.invoke(name, params.arguments ?? {});
  return {
    isError: result?.ok === false,
    content: textContent(result),
    structuredContent: result,
  };
}

function resultResponse(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function errorResponse(id, code, message) {
  return {
    jsonrpc: "2.0",
    id,
    error: { code, message },
  };
}

function writeMessage(message) {
  // MCP stdio transport framing: one JSON-RPC message per line.
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await serve();
}
