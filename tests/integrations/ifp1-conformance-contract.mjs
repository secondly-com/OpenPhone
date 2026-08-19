#!/usr/bin/env node

// Runs the vendored ifp/1 conformance fixture corpus through the vendored
// TypeScript reference validator and state machine
// (runtime/protocol/ifp1/validator.ts, machine.ts). Verdicts must match the
// fixtures exactly — this is the OpenPhone side of spec section 11
// ("a surface is conformant when it passes the fixture corpus").

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

import { validateMessage } from "../../runtime/protocol/ifp1/validator.ts";
import { ConformanceMachine } from "../../runtime/protocol/ifp1/machine.ts";
import { paramsHash, toolNameFromCommand } from "../../runtime/protocol/ifp1/adapter.mjs";

const ifp1Root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../runtime/protocol/ifp1");
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(ifp1Root, file), "utf8"));

let cases = 0;

// --- fixtures/messages.json: single-message accept/reject verdicts ---------
const messages = readJson("fixtures/messages.json");
for (const c of messages.cases) {
  const result = validateMessage(c.message);
  if (c.expect === "accept") {
    assert.equal(result.ok, true, `${c.name}: expected accept, got ${result.errorClass}: ${result.detail}`);
  } else {
    assert.equal(result.ok, false, `${c.name}: expected reject, got accept`);
    assert.equal(result.errorClass, c.error_class, `${c.name}: ${result.detail ?? ""}`);
  }
  cases += 1;
}

// --- fixtures/sequences.json: stateful scenarios ----------------------------
const sequences = readJson("fixtures/sequences.json");
for (const scenario of sequences.scenarios) {
  const machine = new ConformanceMachine(sequences.initial_state.home_generation);
  scenario.steps.forEach((step, i) => {
    const result = machine.step(step.give);
    const expect = step.expect;
    const label = `${scenario.name} step ${i}`;
    assert.equal(result.verdict, expect.verdict, `${label}: error=${result.errorClass}`);
    if ("error_class" in expect) assert.equal(result.errorClass, expect.error_class, label);
    if ("action_state" in expect) assert.equal(result.actionState, expect.action_state, label);
    if ("stored" in expect) assert.equal(result.stored, expect.stored, label);
    if ("error_payload_includes" in expect) {
      assert.ok(result.errorPayload, label);
      for (const [key, value] of Object.entries(expect.error_payload_includes)) {
        assert.deepEqual(result.errorPayload[key], value, label);
      }
    }
  });
  cases += 1;
}

// --- fixtures/params-hash-vectors.json: canonical hashing (spec 8.1) --------
const vectors = readJson("fixtures/params-hash-vectors.json");
for (const vector of vectors.vectors) {
  assert.equal(paramsHash(vector.params), vector.params_hash, `params-hash vector: ${vector.name}`);
  cases += 1;
}

// --- openphone-tools.ifp1.json: manifest re-expresses all 37 commands -------
const toolsManifest = readJson("openphone-tools.ifp1.json");
const oldManifest = JSON.parse(
  fs.readFileSync(path.join(ifp1Root, "..", "openphone-commands.json"), "utf8"),
);
assert.equal(toolsManifest.ifp, "1");
assert.equal(toolsManifest.tools.length, oldManifest.commands.length);
assert.equal(toolsManifest.tools.length, 37, "the v0 manifest declares 37 commands");

const oldByName = new Map(oldManifest.commands.map((c) => [c.name, c]));
const seenTools = new Set();
for (const tool of toolsManifest.tools) {
  assert.ok(!seenTools.has(tool.tool), `duplicate ifp/1 tool: ${tool.tool}`);
  seenTools.add(tool.tool);

  const oldName = tool["x-openphone"].superseded_command;
  const old = oldByName.get(oldName);
  assert.ok(old, `ifp/1 tool ${tool.tool} references unknown old command ${oldName}`);
  assert.equal(tool.tool, toolNameFromCommand(old.name), `tool name must be old name minus prefix: ${oldName}`);
  assert.equal(tool.capability, `tool:${tool.tool}`, `capability declaration mismatch: ${tool.tool}`);
  assert.ok(["low", "medium", "high"].includes(tool.risk), `risk not in ifp/1 registry: ${tool.tool}`);
  assert.equal(tool.risk, old.risk, `risk must carry over from the v0 manifest: ${tool.tool}`);
  assert.deepEqual(tool.params_schema, old.input_schema, `params_schema must carry over: ${tool.tool}`);
  cases += 1;
}
for (const old of oldManifest.commands) {
  assert.ok(seenTools.has(toolNameFromCommand(old.name)), `old command not re-expressed: ${old.name}`);
}

// Risk levels must be consistent with the v0 confirmation policy they encode:
// every "always"-confirm command is high risk; every high-risk tool confirms.
for (const tool of toolsManifest.tools) {
  const old = oldByName.get(tool["x-openphone"].superseded_command);
  if (old.confirmation === "always") assert.equal(tool.risk, "high", `always-confirm must be high risk: ${tool.tool}`);
  if (tool.risk === "high") assert.equal(old.confirmation, "always", `high risk must always confirm: ${tool.tool}`);
}

console.log(`ifp/1 conformance contract passed (${cases} cases: ${messages.cases.length} messages, ${sequences.scenarios.length} sequences, ${vectors.vectors.length} hash vectors, ${toolsManifest.tools.length} tool mappings).`);
