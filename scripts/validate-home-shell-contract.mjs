#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function read(relative) {
  return fs.readFileSync(path.join(root, relative), "utf8");
}

function fail(message) {
  throw new Error(message);
}

const activity = read(
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/OpenPhoneHomeActivity.kt",
);
for (const marker of [
  "setDecorFitsSystemWindows(false)",
  "LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS",
  "BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE",
  "WindowInsets.Type.statusBars()",
  "WindowInsets.Type.navigationBars()",
  "override fun onWindowFocusChanged",
]) {
  if (!activity.includes(marker)) {
    fail(`AI Home immersive window contract is missing ${marker}`);
  }
}

const homeTheme = read(
  "overlay/packages/apps/OpenPhoneAssistant/res/values/styles.xml",
);
for (const marker of [
  '<item name="android:windowFullscreen">true</item>',
  '<item name="android:windowLayoutInDisplayCutoutMode">always</item>',
]) {
  if (!homeTheme.includes(marker)) {
    fail(`AI Home cold-start theme is missing ${marker}`);
  }
}

const homeCompose = read(
  "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/OpenPhoneHomeComposeHost.kt",
);
for (const forbidden of ["statusBarsPadding", "navigationBarsPadding"]) {
  if (homeCompose.includes(forbidden)) {
    fail(`AI Home still reserves Android system-bar space: ${forbidden}`);
  }
}

const frameworkOverlay = read(
  "overlay/vendor/openphone/overlay/frameworks/base/core/res/res/values/config.xml",
);
if (!frameworkOverlay.includes(
  '<bool name="config_disableLockscreenByDefault">true</bool>',
)) {
  fail("OpenPhone does not disable the non-secure lockscreen by default");
}
for (const forbidden of [
  "config_enableCredentialFactoryResetProtection",
  "config_supportsInsecureLockScreen",
  "config_disableWeaverOnUnsecuredUsers",
]) {
  if (frameworkOverlay.includes(forbidden)) {
    fail(`lockscreen overlay weakens an unrelated security control: ${forbidden}`);
  }
}

console.log("AI Home immersive-shell contract checks passed.");
