#!/usr/bin/env node

import { OpenPhoneAdbTransport } from "../adb/openphone-adb-transport.mjs";
import {
  loadCommands,
  mcpTools,
  parseJsonObject,
  resolveCommand,
  runtimeProtocolInfo,
} from "../runtime/protocol/openphone-runtime-tools.mjs";

const commands = loadCommands();

export async function main(argv = process.argv.slice(2), io = process) {
  const options = parseGlobalOptions(argv);
  const transport = new OpenPhoneAdbTransport({
    dryRun: options.dryRun,
    serial: options.serial,
  });
  const [group, command, ...rest] = options.args;
  try {
    let result;
    if (!group || group === "help" || group === "-h" || group === "--help") {
      io.stdout.write(usage());
      return 0;
    }
    if (group === "info") {
      result = infoCommand();
    } else if (group === "runtime") {
      result = await runtimeCommand(command, rest, transport);
    } else if (group === "screen" && command === "get") {
      result = await toolInvoke("openphone.screen.get", flagsToToolArgs(rest), transport);
    } else if (group === "tool") {
      result = await toolCommand(command, rest, transport);
    } else if (group === "mcp" && command === "serve") {
      const { serve } = await importRuntimeMcpServer();
      await serve({ transport });
      return 0;
    } else {
      throw new Error(`unknown command: ${[group, command].filter(Boolean).join(" ")}`);
    }
    writeResult(result, options.json, io.stdout);
    return result?.ok === false ? 1 : 0;
  } catch (error) {
    if (options.json) {
      writeResult({ ok: false, error: { message: error.message } }, true, io.stdout);
    } else {
      io.stderr.write(`error: ${error.message}\n`);
    }
    return 1;
  }
}

async function importRuntimeMcpServer() {
  try {
    return await import("@openphone/runtime-mcp-server");
  } catch (error) {
    if (error?.code !== "ERR_MODULE_NOT_FOUND") {
      throw error;
    }
    return import("../../mcp-server/src/index.mjs");
  }
}

function infoCommand() {
  return {
    name: "openphone-runtime-cli",
    version: "0.1.0",
    runtime_protocol: runtimeProtocolInfo(),
    commands: commands.length,
  };
}

function runtimeCommand(command, args, transport) {
  switch (command) {
    case "status":
      return transport.runtimeStatus();
    case "list":
      return transport.runtimeList();
    case "select":
      return transport.runtimeSelect({
        chat: optionValue(args, "--chat"),
        volume: optionValue(args, "--volume"),
        background: optionValue(args, "--background"),
      });
    case "configure": {
      const [runtime] = args;
      if (runtime !== "openclaw") {
        throw new Error("only openclaw runtime configuration is supported");
      }
      return transport.configureOpenClaw({
        url: optionValue(args, "--url"),
        token: optionValue(args, "--token"),
        label: optionValue(args, "--label"),
        enabled: !args.includes("--disable"),
      });
    }
    default:
      throw new Error(`unknown runtime command: ${command ?? ""}`);
  }
}

function toolCommand(command, args, transport) {
  switch (command) {
    case "list":
      return {
        tools: mcpTools(commands).map((tool) => ({
          name: tool.name,
          description: tool.description,
          input_schema: tool.inputSchema,
        })),
      };
    case "invoke": {
      const [name, json = "{}"] = args;
      if (!name) {
        throw new Error("tool invoke requires a command name");
      }
      const resolved = resolveCommand(name, commands);
      if (!resolved) {
        throw new Error(`unknown runtime tool: ${name}`);
      }
      return toolInvoke(name, parseJsonObject(json, "tool arguments"), transport);
    }
    default:
      throw new Error(`unknown tool command: ${command ?? ""}`);
  }
}

function toolInvoke(name, args, transport) {
  const resolved = resolveCommand(name, commands);
  if (!resolved) {
    throw new Error(`unknown runtime tool: ${name}`);
  }
  return transport.invoke(name, args);
}

function parseGlobalOptions(argv) {
  const args = [];
  let json = false;
  let dryRun = false;
  let serial = "";
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") {
      json = true;
    } else if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg === "--serial") {
      serial = argv[++i] ?? "";
    } else {
      args.push(arg);
    }
  }
  return { args, json, dryRun, serial };
}

function flagsToToolArgs(args) {
  const out = {};
  if (args.includes("--screenshot")) {
    out.include_screenshot = true;
  }
  if (args.includes("--no-screenshot")) {
    out.include_screenshot = false;
  }
  out.include_activity = !args.includes("--no-activity");
  out.include_ui_tree = !args.includes("--no-ui-tree");
  return out;
}

function optionValue(args, name) {
  const index = args.indexOf(name);
  if (index < 0) {
    return undefined;
  }
  return args[index + 1];
}

function writeResult(result, json, stream) {
  if (json || typeof result !== "string") {
    stream.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    stream.write(`${result}\n`);
  }
}

function usage() {
  return `Usage: openphone <command> [options]

Commands:
  info
  runtime status
  runtime list
  runtime select --chat <phone|openclaw> [--volume <phone|openclaw>] [--background <phone|openclaw>]
  runtime configure openclaw --url <ws-url> [--token <token>] [--label <label>] [--disable]
  tool list
  tool invoke <openphone.command> '<json>'
  screen get [--screenshot]
  mcp serve

Global options:
  --json
  --dry-run
  --serial <adb-serial>
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exitCode = await main();
}
