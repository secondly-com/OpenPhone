#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schema = readJson("schemas/openphone-island-state.schema.json");

function read(relative) {
  return fs.readFileSync(path.join(root, relative), "utf8");
}

function readJson(relative) {
  return JSON.parse(read(relative));
}

function fail(message) {
  throw new Error(message);
}

function validate(value, label) {
  if (!value || Array.isArray(value) || typeof value !== "object") {
    fail(`${label} must be an object`);
  }
  for (const required of schema.required) {
    if (!(required in value)) fail(`${label} is missing ${required}`);
  }
  for (const key of Object.keys(value)) {
    if (!(key in schema.properties)) fail(`${label} has unknown property ${key}`);
  }
  for (const [key, property] of Object.entries(schema.properties)) {
    if (!(key in value)) continue;
    const item = value[key];
    if (property.type === "string" && typeof item !== "string") {
      fail(`${label}.${key} must be a string`);
    }
    if (property.type === "boolean" && typeof item !== "boolean") {
      fail(`${label}.${key} must be a boolean`);
    }
    if (property.type === "integer" && !Number.isSafeInteger(item)) {
      fail(`${label}.${key} must be an integer`);
    }
    if ("const" in property && item !== property.const) {
      fail(`${label}.${key} must equal ${property.const}`);
    }
    if (property.enum && !property.enum.includes(item)) {
      fail(`${label}.${key} is outside its enum`);
    }
    if (typeof item === "string" && property.maxLength
        && item.length > property.maxLength) {
      fail(`${label}.${key} is too long`);
    }
    if (Number.isSafeInteger(item) && property.minimum !== undefined
        && item < property.minimum) {
      fail(`${label}.${key} is below its minimum`);
    }
    if (Number.isSafeInteger(item) && property.maximum !== undefined
        && item > property.maximum) {
      fail(`${label}.${key} is above its maximum`);
    }
  }
  const compactCopy = [
    value.label,
    value.title,
    value.detail,
  ].join("\n").toLowerCase();
  if (compactCopy.includes("bearer ")
      || compactCopy.includes("api_key")
      || compactCopy.includes("access_token")
      || compactCopy.includes("private key")
      || compactCopy.includes("password=")) {
    fail(`${label} contains secret-like material`);
  }
  if (Buffer.byteLength(JSON.stringify(value), "utf8") > 16 * 1024) {
    fail(`${label} exceeds the Binder payload bound`);
  }
}

for (const name of ["idle.json", "needs-review.json"]) {
  validate(readJson(`tests/fixtures/island/${name}`), name);
}
for (const name of [
  "invalid-mode.json",
  "invalid-secret.json",
  "invalid-oversized.json",
]) {
  let rejected = false;
  try {
    validate(readJson(`tests/fixtures/island/${name}`), name);
  } catch {
    rejected = true;
  }
  if (!rejected) fail(`invalid island fixture was accepted: ${name}`);
}

const frameworkPatch = read(
  "patches/frameworks_base/0020-OpenPhone-add-durable-island-state-contract.patch",
);
for (const marker of [
  "IOpenPhoneIslandStateListener",
  "registerIslandStateListener",
  "publishIslandState",
  "MAX_ISLAND_STATE_BYTES",
  "enforceAssistantIslandPublisher",
  "RemoteCallbackList",
]) {
  if (!frameworkPatch.includes(marker)) {
    fail(`framework island contract is missing ${marker}`);
  }
}

const systemUiPatch = read(
  "patches/frameworks_base/0021-OpenPhone-render-compact-island-in-SystemUI.patch",
);
for (const marker of [
  "TYPE_STATUS_BAR_SUB_PANEL",
  "FLAG_NOT_TOUCH_MODAL",
  "isDeviceLocked",
  "Unlock to review private activity",
  "STATE_STALE_MS",
  "postStartActivityDismissingKeyguard",
  "dp(110)",
  "dp(34)",
  "\"AI\",",
  "\"◎ \" + state.liveRuns",
  "background.setColor(0xff000000)",
]) {
  if (!systemUiPatch.includes(marker)) {
    fail(`SystemUI island renderer is missing ${marker}`);
  }
}
for (const forbidden of [
  "FLAG_WATCH_OUTSIDE_TOUCH",
  "WindowManager.LayoutParams.MATCH_PARENT",
  ".confirmAction(",
]) {
  if (systemUiPatch.includes(forbidden)) {
    fail(`SystemUI island renderer contains forbidden behavior: ${forbidden}`);
  }
}

const pointerSource = read(
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/PointerOverlayController.java",
);
const ensureStart = pointerSource.indexOf("private void ensureIslandWindow()");
const ensureEnd = pointerSource.indexOf("private void handleIslandTap", ensureStart);
const ensureIsland = pointerSource.slice(ensureStart, ensureEnd);
if (ensureIsland.indexOf("isSystemUiOwned()") < 0
    || ensureIsland.indexOf("isSystemUiOwned()")
      > ensureIsland.indexOf("TYPE_SYSTEM_ERROR")) {
  fail("assistant island window is not gated behind SystemUI ownership");
}
const pointerStart = pointerSource.indexOf("private void ensurePointerLayer()");
const pointerEnd = pointerSource.indexOf("private void ensureIslandWindow()", pointerStart);
const pointerLayer = pointerSource.slice(pointerStart, pointerEnd);
if (!pointerLayer.includes("FLAG_NOT_TOUCHABLE")) {
  fail("assistant pointer visualization must remain non-touchable");
}

const repositorySource = read(
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/island/IslandStateRepository.java",
);
for (const forbidden of ["mTranscriptText", "mReplyText"]) {
  if (repositorySource.includes(forbidden)) {
    fail(`island projection carries forbidden rich content: ${forbidden}`);
  }
}
if (!repositorySource.includes("ro.openphone.systemui_island")
    || !read("overlay/vendor/openphone/products/openphone_common.mk")
      .includes("ro.openphone.systemui_island=true")) {
  fail("SystemUI island product ownership is not enabled");
}

console.log("SystemUI island contract checks passed.");
