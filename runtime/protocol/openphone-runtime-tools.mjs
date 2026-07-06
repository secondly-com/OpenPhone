import fs from "node:fs";
import path from "node:path";

const protocolRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const commandsPath = path.join(protocolRoot, "runtime/protocol/openphone-commands.json");

// The inclusive range of runtime-protocol manifest versions this loader
// understands. Bump max_version when a new manifest version is introduced;
// bump min_version only when support for an old version is dropped.
export const RUNTIME_PROTOCOL_VERSION_RANGE = Object.freeze({
  min_version: 1,
  max_version: 1,
});

export function isSupportedRuntimeProtocolVersion(
  version,
  range = RUNTIME_PROTOCOL_VERSION_RANGE,
) {
  return Number.isInteger(version)
    && version >= range.min_version
    && version <= range.max_version;
}

export function assertSupportedRuntimeProtocolVersion(
  version,
  range = RUNTIME_PROTOCOL_VERSION_RANGE,
) {
  if (!isSupportedRuntimeProtocolVersion(version, range)) {
    throw new Error(
      `unsupported runtime protocol version: ${version} `
        + `(supported range: ${range.min_version}..${range.max_version})`,
    );
  }
}

// Structured advertisement of the runtime-protocol version range for
// initialize-style handshakes (MCP initialize result, CLI info output).
export function runtimeProtocolInfo(range = RUNTIME_PROTOCOL_VERSION_RANGE) {
  return {
    name: "openphone-runtime-protocol",
    min_version: range.min_version,
    max_version: range.max_version,
  };
}

export function validateCommandDeprecations(commands) {
  const known = new Set();
  for (const command of commands) {
    known.add(command.name);
    for (const alias of command.aliases ?? []) {
      known.add(alias);
    }
  }
  for (const command of commands) {
    if (command.deprecated !== undefined && typeof command.deprecated !== "boolean") {
      throw new Error(`command ${command.name}: deprecated must be a boolean`);
    }
    if (command.superseded_by !== undefined) {
      if (typeof command.superseded_by !== "string" || !command.superseded_by) {
        throw new Error(`command ${command.name}: superseded_by must be a non-empty string`);
      }
      if (command.deprecated !== true) {
        throw new Error(`command ${command.name}: superseded_by requires deprecated=true`);
      }
      if (!known.has(command.superseded_by)) {
        throw new Error(
          `command ${command.name}: superseded_by references unknown command: `
            + command.superseded_by,
        );
      }
      if (command.superseded_by === command.name
          || (command.aliases ?? []).includes(command.superseded_by)) {
        throw new Error(`command ${command.name}: superseded_by must reference another command`);
      }
    }
  }
  return commands;
}

export function loadCommandManifest(file = commandsPath) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

export function loadCommands(file = commandsPath, options = {}) {
  const range = options.versionRange ?? RUNTIME_PROTOCOL_VERSION_RANGE;
  const manifest = loadCommandManifest(file);
  if (!isSupportedRuntimeProtocolVersion(manifest.version, range)
      || !Array.isArray(manifest.commands)) {
    throw new Error(
      "openphone-commands.json must contain commands[] and a supported version "
        + `(range: ${range.min_version}..${range.max_version}, got: ${manifest.version})`,
    );
  }
  return validateCommandDeprecations(manifest.commands);
}

export function commandMap(commands = loadCommands()) {
  const out = new Map();
  for (const command of commands) {
    out.set(command.name, command);
    for (const alias of command.aliases ?? []) {
      out.set(alias, command);
    }
  }
  return out;
}

export function resolveCommand(name, commands = loadCommands()) {
  return commandMap(commands).get(name);
}

export function mcpTools(commands = loadCommands()) {
  return commands
    .filter((command) => command.mcp)
    .map((command) => ({
      name: command.name,
      title: titleForCommand(command.name),
      description: command.description,
      inputSchema: command.input_schema ?? { type: "object" },
      outputSchema: command.output_schema ?? { type: "object", additionalProperties: true },
      annotations: {
        readOnlyHint: command.default_exposure !== "dangerous",
        destructiveHint: command.confirmation === "always",
        openWorldHint: command.category === "apps" || command.category === "share",
      },
    }));
}

export function parseJsonObject(value, label = "JSON") {
  if (value == null || value === "") {
    return {};
  }
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw new Error(`${label} must be valid JSON: ${error.message}`);
  }
  if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
    throw new Error(`${label} must be a JSON object`);
  }
  return parsed;
}

export function textContent(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return [{ type: "text", text }];
}

export function titleForCommand(name) {
  return String(name)
    .replace(/^openphone\./, "")
    .split(/[._-]+/gu)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}
