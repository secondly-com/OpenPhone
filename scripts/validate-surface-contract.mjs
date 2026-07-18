#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = path.join(root, "schemas/openphone-surface.schema.json");
const outputSchemaPath = path.join(
  root,
  "schemas/openphone-assistant-output.schema.json",
);
const fixturesDir = path.join(root, "tests/fixtures/surfaces");
const actionRegistry = JSON.parse(
  fs.readFileSync(
    path.join(root, "overlay/vendor/openphone/config/openphone_action_registry.json"),
    "utf8",
  ),
);
const actionsByTool = new Map(
  actionRegistry.actions.map((action) => [action.model_tool, action]),
);
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const outputSchema = JSON.parse(fs.readFileSync(outputSchemaPath, "utf8"));

const componentTypes = new Set(
  schema.$defs.component.properties.type.enum,
);
const allowedComponentKeys = new Set(
  Object.keys(schema.$defs.component.properties),
);
const allowedRootKeys = new Set(Object.keys(schema.properties));
const allowedActionKeys = new Set(
  Object.keys(schema.$defs.action.properties),
);
const textKeys = ["text", "title", "subtitle", "label", "message", "placeholder"];
const limits = {
  nodes: 120,
  depth: 12,
  text: 24000,
  images: 4,
  actions: schema.properties.actions.maxProperties,
  bytes: 256 * 1024,
};

function fail(message) {
  throw new Error(message);
}

function string(value, label, max, required = false) {
  if (typeof value !== "string" || (required && value.trim().length === 0)) {
    fail(`${label} must be ${required ? "a non-empty " : "a "}string`);
  }
  if (value.length > max) fail(`${label} exceeds ${max} characters`);
}

function validateComponent(component, state, depth = 1) {
  if (!component || Array.isArray(component) || typeof component !== "object") {
    fail("surface component must be an object");
  }
  if (depth > limits.depth) fail(`surface exceeds depth ${limits.depth}`);
  state.nodes += 1;
  if (state.nodes > limits.nodes) fail(`surface exceeds ${limits.nodes} nodes`);
  if (!componentTypes.has(component.type)) {
    fail(`unknown component type: ${String(component.type)}`);
  }
  for (const key of Object.keys(component)) {
    if (!allowedComponentKeys.has(key)) fail(`unknown component property: ${key}`);
  }
  for (const key of textKeys) {
    if (key in component) {
      const max = schema.$defs.component.properties[key].maxLength;
      string(component[key], `component.${key}`, max);
      state.text += component[key].length;
    }
  }
  if (state.text > limits.text) fail(`surface exceeds ${limits.text} text characters`);
  if (component.type === "image") {
    state.images += 1;
    if (state.images > limits.images) fail(`surface exceeds ${limits.images} images`);
    if (!component.artifact) fail("image requires a local artifact reference");
  }
  if (component.action_id) state.actionIds.add(component.action_id);
  for (const key of ["children", "items"]) {
    if (key in component) {
      if (!Array.isArray(component[key]) || component[key].length > 32) {
        fail(`${component.type}.${key} must contain at most 32 components`);
      }
      for (const child of component[key]) validateComponent(child, state, depth + 1);
    }
  }
}

function validateSurface(surface) {
  if (!surface || Array.isArray(surface) || typeof surface !== "object") {
    fail("surface must be an object");
  }
  if (Buffer.byteLength(JSON.stringify(surface), "utf8") > limits.bytes) {
    fail(`surface exceeds ${limits.bytes} bytes`);
  }
  for (const key of Object.keys(surface)) {
    if (!allowedRootKeys.has(key)) fail(`unknown surface property: ${key}`);
  }
  if (surface.schema !== "openphone.surface.v1") fail("invalid surface schema");
  string(surface.surface_id, "surface_id", 128, true);
  if (!/^surface-[A-Za-z0-9._-]{1,120}$/.test(surface.surface_id)) {
    fail("invalid surface_id");
  }
  if (!Number.isInteger(surface.revision) || surface.revision < 1) {
    fail("revision must be a positive integer");
  }
  string(surface.session_id, "session_id", 160, true);
  string(surface.runtime, "runtime", 80, true);
  string(surface.title, "title", 160);
  if (!["full", "sheet", "inline"].includes(surface.presentation)) {
    fail("invalid presentation");
  }
  if (!["public", "personal", "sensitive", "restricted"].includes(surface.sensitivity)) {
    fail("invalid sensitivity");
  }
  if (!Number.isSafeInteger(surface.expires_at) || surface.expires_at < 0) {
    fail("expires_at must be a non-negative integer");
  }
  const actions = surface.actions;
  if (!actions || Array.isArray(actions) || typeof actions !== "object") {
    fail("actions must be an object");
  }
  if (Object.keys(actions).length > limits.actions) {
    fail(`surface exceeds ${limits.actions} actions`);
  }
  const state = { nodes: 0, text: 0, images: 0, actionIds: new Set() };
  validateComponent(surface.body, state);
  for (const [actionId, action] of Object.entries(actions)) {
    if (!/^[A-Za-z][A-Za-z0-9._-]{0,119}$/.test(actionId)) fail("invalid action id");
    if (!action || Array.isArray(action) || typeof action !== "object") {
      fail(`action ${actionId} must be an object`);
    }
    for (const key of Object.keys(action)) {
      if (!allowedActionKeys.has(key)) fail(`unknown action property: ${key}`);
    }
    string(action.label, `${actionId}.label`, 80, true);
    string(action.tool, `${actionId}.tool`, 80, true);
    string(action.reason, `${actionId}.reason`, 240, true);
    if (!action.params || Array.isArray(action.params) || typeof action.params !== "object") {
      fail(`${actionId}.params must be an object`);
    }
    const registered = actionsByTool.get(action.tool);
    if (!registered) fail(`${actionId}.tool is not registered`);
    const inputSchema = registered.input_schema_json ?? {};
    const properties = inputSchema.properties ?? {};
    for (const required of inputSchema.required ?? []) {
      if (required !== "reason" && !(required in action.params)) {
        fail(`${actionId} is missing required tool parameter ${required}`);
      }
    }
    for (const key of Object.keys(action.params)) {
      if (!(key in properties)) fail(`${actionId} has unknown tool parameter ${key}`);
    }
    if (registered.kind === "action" && action.requires_confirmation !== true) {
      fail(`${actionId} must disclose confirmation for a mutating tool`);
    }
  }
  for (const actionId of state.actionIds) {
    if (!(actionId in actions)) fail(`component references undeclared action: ${actionId}`);
  }
  for (const actionId of Object.keys(actions)) {
    if (!state.actionIds.has(actionId)) fail(`action is not referenced by UI: ${actionId}`);
  }
  return state;
}

if (schema.properties.schema.const !== "openphone.surface.v1") {
  fail("surface schema marker drifted");
}
if (outputSchema.properties.schema.const !== "openphone.assistant_output.v1") {
  fail("assistant output schema marker drifted");
}

const validFixtures = ["calendar-agenda.json", "message-summary.json"];
for (const name of validFixtures) {
  validateSurface(JSON.parse(fs.readFileSync(path.join(fixturesDir, name), "utf8")));
}

const invalidFixtures = [
  "invalid-external-image.json",
  "invalid-unknown-component.json",
  "invalid-unknown-action.json",
];
for (const name of invalidFixtures) {
  let rejected = false;
  try {
    validateSurface(JSON.parse(fs.readFileSync(path.join(fixturesDir, name), "utf8")));
  } catch {
    rejected = true;
  }
  if (!rejected) fail(`invalid fixture was accepted: ${name}`);
}

console.log("Adaptive surface contract checks passed.");
