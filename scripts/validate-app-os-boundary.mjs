#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const assistant = path.join(
  root,
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant",
);

function read(relative) {
  return fs.readFileSync(path.join(root, relative), "utf8");
}

function fail(message) {
  throw new Error(message);
}

function sourceFiles(relativeDirectory) {
  const files = [];
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(entryPath);
      } else if (entry.isFile()
          && (entry.name.endsWith(".java") || entry.name.endsWith(".kt"))) {
        files.push(entryPath);
      }
    }
  }
  visit(path.join(assistant, relativeDirectory));
  return files;
}

const portableDirectories = ["actions", "model", "orchestrator", "runtime", "surface"];
const forbiddenPortableMarkers = [
  "import android.openphone.",
  "FrameworkToolExecutor",
  "OpenPhoneOsToolGateway",
];

for (const directory of portableDirectories) {
  for (const file of sourceFiles(directory)) {
    const source = fs.readFileSync(file, "utf8");
    for (const marker of forbiddenPortableMarkers) {
      if (source.includes(marker)) {
        fail(`${path.relative(root, file)} crosses the app/OS boundary via ${marker}`);
      }
    }
  }
}

const contract = read(
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/platform/PhoneToolGateway.java",
);
for (const marker of [
  "String profile()",
  "boolean isAvailable()",
  "boolean supportsTool(String toolName)",
  "String startTask(String taskJson)",
  "String executeTool(String taskId, String toolName, JSONObject arguments)",
  "String confirmAction(String pendingActionId, boolean approved)",
]) {
  if (!contract.includes(marker)) {
    fail(`PhoneToolGateway is missing ${marker}`);
  }
}
if (contract.includes("android.openphone")) {
  fail("PhoneToolGateway must remain independent of hidden OpenPhone APIs");
}

const osGateway = read(
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/platform/OpenPhoneOsToolGateway.java",
);
for (const marker of [
  "implements PhoneToolGateway",
  "import android.openphone.OpenPhoneAgentManager",
  "new FrameworkToolExecutor",
  'PROFILE = "openphone_os"',
]) {
  if (!osGateway.includes(marker)) {
    fail(`OpenPhone OS gateway is missing ${marker}`);
  }
}

const runtimeBridge = read(
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/runtime/RuntimeToolBridge.java",
);
for (const marker of [
  "mPhoneGateway.startTask",
  "mPhoneGateway.executeTool",
  "mPhoneGateway.confirmAction",
  "mPhoneGateway.supportsTool",
]) {
  if (!runtimeBridge.includes(marker)) {
    fail(`RuntimeToolBridge does not route through ${marker}`);
  }
}

console.log("App/OS boundary contract checks passed.");
