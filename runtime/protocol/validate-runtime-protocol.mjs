#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  RUNTIME_PROTOCOL_VERSION_RANGE,
  isSupportedRuntimeProtocolVersion,
} from "./openphone-runtime-tools.mjs";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const commandsPath = path.join(root, "runtime/protocol/openphone-commands.json");
const eventsPath = path.join(root, "runtime/protocol/openphone-events.json");
const capabilitiesPath = path.join(root, "runtime/protocol/openphone-capabilities.json");
const schemaPath = path.join(root, "runtime/protocol/openphone-runtime.schema.json");
const actionRegistryPath = path.join(
  root,
  "overlay/vendor/openphone/config/openphone_action_registry.json",
);
const pluginSourcePath = path.join(root, "integrations/openclaw-plugin/src/index.ts");
const pluginDistPath = path.join(root, "integrations/openclaw-plugin/dist/index.js");
const androidCommandRegistryPath = path.join(
  root,
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/runtime/adapters/openclaw/OpenClawCommandRegistry.java",
);
const openClawAdapterPath = path.join(
  root,
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/runtime/adapters/openclaw/OpenClawRuntimeAdapter.java",
);
const surfaceFixturePaths = [
  "surface-present-event.json",
  "surface-replace-event.json",
  "surface-dismiss-event.json",
].map((name) => path.join(root, "tests/fixtures/runtime", name));

function fail(message) {
  console.error(`check-runtime-protocol: ${message}`);
  process.exit(1);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function unique(values, label) {
  const seen = new Set();
  for (const value of values) {
    if (seen.has(value)) {
      fail(`duplicate ${label}: ${value}`);
    }
    seen.add(value);
  }
  return seen;
}

function extractQuotedStringsInArray(source, name) {
  const match = source.match(new RegExp(`const\\s+${name}\\s*=\\s*\\[([\\s\\S]*?)\\];`, "u"));
  if (!match) {
    fail(`missing plugin array ${name}`);
  }
  return [...match[1].matchAll(/"([^"]+)"/gu)].map((item) => item[1]);
}

function extractAndroidCommands(source) {
  return [
    ...source.matchAll(/(?:mCommandToTool|commandToTool)\.put\("([^"]+)",\s*"([^"]+)"\);/gu),
  ].map((item) => ({ command: item[1], tool: item[2] }));
}

function extractPluginCommandBuckets(source, label) {
  const safeRead = unique(
    extractQuotedStringsInArray(source, "OPENPHONE_SCREEN_READ_COMMANDS"),
    `${label} safe read command`,
  );
  const privateRead = unique(
    extractQuotedStringsInArray(source, "OPENPHONE_PRIVATE_READ_COMMANDS"),
    `${label} private read command`,
  );
  const dangerous = unique(
    extractQuotedStringsInArray(source, "OPENPHONE_ACTION_COMMANDS"),
    `${label} action command`,
  );
  const all = unique([...safeRead, ...privateRead, ...dangerous], `${label} command`);
  return { safeRead, privateRead, dangerous, all };
}

const manifest = readJson(commandsPath);
if (!isSupportedRuntimeProtocolVersion(manifest.version) || !Array.isArray(manifest.commands)) {
  fail(
    "openphone-commands.json must contain commands[] and a supported version "
      + `(range: ${RUNTIME_PROTOCOL_VERSION_RANGE.min_version}..`
      + `${RUNTIME_PROTOCOL_VERSION_RANGE.max_version}, got: ${manifest.version})`,
  );
}

const runtimeSchema = readJson(schemaPath);
if (runtimeSchema.title !== "OpenPhone Runtime Agent Protocol" || !runtimeSchema.$defs) {
  fail("openphone-runtime.schema.json must contain title and $defs");
}

const eventsManifest = readJson(eventsPath);
if (eventsManifest.version !== 1 || !Array.isArray(eventsManifest.events)) {
  fail("openphone-events.json must contain version=1 and events[]");
}
unique(eventsManifest.events.map((entry) => entry.name), "event");
const eventDirections = new Map(
  eventsManifest.events.map((entry) => [entry.name, entry.direction]),
);
const expectedSurfaceEvents = new Map([
  ["runtime.surface.present", "runtime_to_phone"],
  ["runtime.surface.replace", "runtime_to_phone"],
  ["runtime.surface.dismiss", "runtime_to_phone"],
  ["runtime.surface.action_result", "phone_to_runtime"],
  ["phone.surface.action_invoked", "phone_to_runtime"],
  ["phone.surface.dismissed", "phone_to_runtime"],
]);
for (const [event, direction] of expectedSurfaceEvents) {
  if (eventDirections.get(event) !== direction) {
    fail(`missing or misdirected surface event: ${event} -> ${direction}`);
  }
}
const openClawMappings = new Map(
  (eventsManifest.transport_mappings ?? [])
    .filter((mapping) => mapping.runtime === "openclaw")
    .flatMap((mapping) => mapping.events ?? [])
    .map((mapping) => [mapping.protocol, mapping.wire]),
);
for (const event of expectedSurfaceEvents.keys()) {
  if (!openClawMappings.has(event)) {
    fail(`OpenClaw transport mapping missing surface event: ${event}`);
  }
}

const surfaceFixtures = surfaceFixturePaths.map(readJson);
const [presentFixture, replaceFixture, dismissFixture] = surfaceFixtures;
if (presentFixture.event !== "runtime.surface.present"
    || presentFixture.payload?.output?.schema !== "openphone.assistant_output.v1"
    || presentFixture.payload?.output?.surface?.schema !== "openphone.surface.v1"
    || presentFixture.payload?.output?.session_id
      !== presentFixture.payload?.output?.surface?.session_id) {
  fail("runtime surface present fixture is malformed");
}
if (replaceFixture.event !== "runtime.surface.replace"
    || replaceFixture.payload?.expected_revision !== 1
    || replaceFixture.payload?.output?.surface?.revision !== 2
    || replaceFixture.payload?.output?.surface?.surface_id
      !== presentFixture.payload?.output?.surface?.surface_id) {
  fail("runtime surface replace fixture must increment the same surface revision");
}
if (dismissFixture.event !== "runtime.surface.dismiss"
    || dismissFixture.payload?.revision !== replaceFixture.payload?.output?.surface?.revision
    || dismissFixture.payload?.surface_id
      !== replaceFixture.payload?.output?.surface?.surface_id) {
  fail("runtime surface dismiss fixture must target the replacement revision");
}
const openClawAdapterSource = fs.readFileSync(openClawAdapterPath, "utf8");
for (const wire of openClawMappings.values()) {
  if (wire.startsWith("openphone.surface.") && !openClawAdapterSource.includes(wire)) {
    fail(`Android OpenClaw adapter does not map surface wire event: ${wire}`);
  }
}

const capabilitiesManifest = readJson(capabilitiesPath);
if (capabilitiesManifest.version !== 1 || !Array.isArray(capabilitiesManifest.capabilities)) {
  fail("openphone-capabilities.json must contain version=1 and capabilities[]");
}
const capabilitySet = unique(capabilitiesManifest.capabilities.map((entry) => entry.id), "capability");

const manifestEntries = manifest.commands;
const manifestCommands = [];
const actionRegistry = readJson(actionRegistryPath);
if (actionRegistry.version !== 1 || !Array.isArray(actionRegistry.actions)) {
  fail("openphone_action_registry.json must contain version=1 and actions[]");
}
const androidToolSet = unique(
  actionRegistry.actions
    .map((entry) => entry.model_tool)
    .filter(Boolean),
  "Android action-registry model tool",
);
for (const entry of manifestEntries) {
  if (!entry.name || !entry.android_tool || !entry.default_exposure || !entry.description
      || !entry.input_schema || !entry.output_schema) {
    fail(`manifest command is missing required fields: ${JSON.stringify(entry)}`);
  }
  if (!androidToolSet.has(entry.android_tool)) {
    fail(`manifest command references missing Android tool: ${entry.name} -> ${entry.android_tool}`);
  }
  if (!capabilitySet.has(entry.capability)) {
    fail(`manifest command references missing capability: ${entry.name} -> ${entry.capability}`);
  }
  manifestCommands.push(entry.name, ...(entry.aliases ?? []));
}
const manifestSet = unique(manifestCommands, "manifest command or alias");

for (const entry of manifestEntries) {
  if (entry.deprecated !== undefined && typeof entry.deprecated !== "boolean") {
    fail(`manifest command has non-boolean deprecated field: ${entry.name}`);
  }
  if (entry.superseded_by !== undefined) {
    if (typeof entry.superseded_by !== "string" || !entry.superseded_by) {
      fail(`manifest command has invalid superseded_by field: ${entry.name}`);
    }
    if (entry.deprecated !== true) {
      fail(`manifest command sets superseded_by without deprecated=true: ${entry.name}`);
    }
    if (!manifestSet.has(entry.superseded_by)) {
      fail(
        `manifest command superseded_by references missing command: `
          + `${entry.name} -> ${entry.superseded_by}`,
      );
    }
    if (entry.superseded_by === entry.name || (entry.aliases ?? []).includes(entry.superseded_by)) {
      fail(`manifest command superseded_by must reference another command: ${entry.name}`);
    }
  }
}

const pluginBuckets = extractPluginCommandBuckets(
  fs.readFileSync(pluginSourcePath, "utf8"),
  "plugin source",
);
const pluginDistBuckets = extractPluginCommandBuckets(
  fs.readFileSync(pluginDistPath, "utf8"),
  "plugin dist",
);
const pluginSet = pluginBuckets.all;
const pluginDistSet = pluginDistBuckets.all;

for (const command of pluginSet) {
  if (!manifestSet.has(command)) {
    fail(`plugin command missing from manifest: ${command}`);
  }
}

for (const command of pluginDistSet) {
  if (!pluginSet.has(command)) {
    fail(`plugin dist command missing from source: ${command}`);
  }
}

for (const command of pluginSet) {
  if (!pluginDistSet.has(command)) {
    fail(`plugin source command missing from dist: ${command}`);
  }
}

for (const [bucketName, sourceBucket, distBucket] of [
  ["safe read", pluginBuckets.safeRead, pluginDistBuckets.safeRead],
  ["private read", pluginBuckets.privateRead, pluginDistBuckets.privateRead],
  ["dangerous", pluginBuckets.dangerous, pluginDistBuckets.dangerous],
]) {
  for (const command of sourceBucket) {
    if (!distBucket.has(command)) {
      fail(`plugin source ${bucketName} command missing from dist bucket: ${command}`);
    }
  }
  for (const command of distBucket) {
    if (!sourceBucket.has(command)) {
      fail(`plugin dist ${bucketName} command missing from source bucket: ${command}`);
    }
  }
}

for (const entry of manifestEntries) {
  const expected = [entry.name, ...(entry.aliases ?? [])];
  if (entry.remote_runtime && !expected.some((command) => pluginSet.has(command))) {
    fail(`manifest remote command missing from plugin: ${entry.name}`);
  }
  if (entry.remote_runtime && entry.default_exposure === "safe_read"
      && !expected.every((command) => pluginBuckets.safeRead.has(command))) {
    fail(`manifest safe read command is not in plugin safe read bucket: ${entry.name}`);
  }
  if (entry.remote_runtime && entry.default_exposure === "private_read"
      && !expected.every((command) => pluginBuckets.privateRead.has(command))) {
    fail(`manifest private read command is not in plugin private read bucket: ${entry.name}`);
  }
  if (entry.remote_runtime && entry.default_exposure === "dangerous"
      && !expected.every((command) => pluginBuckets.dangerous.has(command))) {
    fail(`manifest dangerous command is not in plugin dangerous bucket: ${entry.name}`);
  }
}

const androidSource = fs.readFileSync(androidCommandRegistryPath, "utf8");
const androidMappings = extractAndroidCommands(androidSource);
const androidByCommand = new Map(androidMappings.map((entry) => [entry.command, entry.tool]));
for (const entry of manifestEntries) {
  for (const command of [entry.name, ...(entry.aliases ?? [])]) {
    if (!androidByCommand.has(command)) {
      fail(`Android OpenClaw adapter missing command mapping: ${command}`);
    }
    if (androidByCommand.get(command) !== entry.android_tool) {
      fail(
        `Android mapping mismatch for ${command}: expected ${entry.android_tool}, got ${androidByCommand.get(command)}`,
      );
    }
  }
}
