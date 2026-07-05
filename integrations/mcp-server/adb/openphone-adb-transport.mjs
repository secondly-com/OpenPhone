import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_ADB_TIMEOUT_MS = 15000;

const moduleDir = path.dirname(fileURLToPath(import.meta.url));
// The transport ships in two layouts: packaged (adb/ next to runtime/) and
// repo source (integrations/adb/ two levels above runtime/).
const MANIFEST_CANDIDATES = [
  path.resolve(moduleDir, "../runtime/protocol/openphone-commands.json"),
  path.resolve(moduleDir, "../../runtime/protocol/openphone-commands.json"),
];

export class OpenPhoneAdbTransport {
  constructor(options = {}) {
    this.adb = options.adb ?? process.env.ADB ?? "adb";
    this.serial = options.serial ?? process.env.ANDROID_SERIAL ?? "";
    this.dryRun = Boolean(options.dryRun ?? process.env.OPENPHONE_DRY_RUN);
    this.allowStateful = options.allowStateful != null
      ? Boolean(options.allowStateful)
      : truthySetting(process.env.OPENPHONE_ADB_ALLOW_STATEFUL);
    this.timeoutMs = Number(options.timeoutMs ?? process.env.OPENPHONE_ADB_TIMEOUT_MS)
      || DEFAULT_ADB_TIMEOUT_MS;
    this.confirmations = confirmationMap(options.commands ?? loadManifestCommands());
  }

  runtimeList() {
    const status = this.runtimeStatus();
    const openClawEnabled = truthySetting(status.openclaw_enabled);
    const openClawUrl = String(status.openclaw_url ?? "").trim();
    return {
      runtimes: [
        { name: "builtin", label: "Phone", local: true, configured: true },
        {
          name: "openclaw",
          label: status.openclaw_label || "OpenClaw",
          local: false,
          enabled: openClawEnabled,
          configured: openClawEnabled && openClawUrl.length > 0,
          url: openClawUrl,
        },
      ],
    };
  }

  runtimeStatus() {
    return {
      chat_runtime: this.settingGet("openphone_assistant_brain", "builtin"),
      volume_runtime: this.settingGet("openphone_volume_runtime", "builtin"),
      background_runtime: this.settingGet("openphone_background_runtime", "builtin"),
      runtimes_enabled: this.settingGet("openphone_runtimes_enabled", "0"),
      openclaw_enabled: this.settingGet("openphone_runtime_openclaw_enabled", "0"),
      openclaw_url: this.settingGet("openphone_runtime_openclaw_url", ""),
      openclaw_label: this.settingGet("openphone_runtime_openclaw_label", "OpenClaw"),
    };
  }

  runtimeSelect({ chat, volume, background }) {
    const changes = {};
    if (chat) {
      changes.chat_runtime = cleanRuntime(chat);
      this.settingPut("openphone_assistant_brain", changes.chat_runtime);
    }
    if (volume) {
      changes.volume_runtime = cleanRuntime(volume);
      this.settingPut("openphone_volume_runtime", changes.volume_runtime);
    }
    if (background) {
      changes.background_runtime = cleanRuntime(background);
      this.settingPut("openphone_background_runtime", changes.background_runtime);
    }
    return { ok: true, changes };
  }

  configureOpenClaw({ url, token, label, enabled = true }) {
    const changes = {};
    this.settingPut("openphone_runtimes_enabled", enabled ? "1" : "0");
    this.settingPut("openphone_runtime_openclaw_enabled", enabled ? "1" : "0");
    changes.runtimes_enabled = enabled;
    if (url != null) {
      this.settingPut("openphone_runtime_openclaw_url", url);
      changes.openclaw_url = url;
    }
    if (token != null) {
      this.settingPut("openphone_runtime_openclaw_token", token);
      changes.openclaw_token_set = token.length > 0;
    }
    if (label != null) {
      this.settingPut("openphone_runtime_openclaw_label", label);
      changes.openclaw_label = label;
    }
    return { ok: true, changes };
  }

  invoke(command, args = {}) {
    if (this.dryRun) {
      return { ok: true, dry_run: true, command, args };
    }
    const refusal = this.refuseStateful(command);
    if (refusal) {
      return refusal;
    }
    switch (command) {
      case "openphone.screen.get":
      case "canvas.snapshot":
        return this.screenGet(args);
      case "openphone.screen.understand_local":
      case "openphone.local.screen_understanding":
        return this.screenUnderstandLocal(args);
      case "openphone.apps.search":
      case "device.apps":
        return this.appsSearch(args);
      case "openphone.app.open":
        return this.openApp(args);
      case "openphone.url.open":
        return this.openUrl(args);
      case "openphone.ui.tap":
        return this.tap(args);
      case "openphone.ui.swipe":
        return this.swipe(args);
      case "openphone.ui.type_text":
        return this.typeText(args);
      case "openphone.input.press_key":
        return this.pressKey(args);
      case "openphone.clipboard.set":
        return this.setClipboard(args);
      default:
        return {
          ok: false,
          error: {
            code: "unsupported_adb_tool",
            message: `${command} is listed in the runtime manifest but is not implemented by the ADB transport yet.`,
          },
        };
    }
  }

  refuseStateful(command) {
    const confirmation = this.confirmations.get(command) ?? "none";
    if (confirmation === "none" || this.allowStateful) {
      return null;
    }
    return {
      ok: false,
      error: {
        code: "stateful_tool_refused",
        message: `${command} changes device state (manifest confirmation: "${confirmation}") `
          + "and the ADB transport cannot ask the user for confirmation. "
          + "Set OPENPHONE_ADB_ALLOW_STATEFUL=1 (or pass allowStateful: true) to opt in, "
          + "or set OPENPHONE_DRY_RUN=1 to explore without touching the device.",
      },
    };
  }

  screenGet(args = {}) {
    const activity = this.shell(["dumpsys", "window"], { allowFailure: true });
    this.shell(["uiautomator", "dump", "/sdcard/window.xml"], { allowFailure: true });
    const uiTreeXml = this.exec(["exec-out", "cat", "/sdcard/window.xml"], {
      allowFailure: true,
    }).toString("utf8");
    const result = {
      ok: true,
      foreground: focusedWindow(activity),
      ui_tree_xml: uiTreeXml.trim(),
      visible_text: visibleText(uiTreeXml),
    };
    if (args.include_screenshot) {
      result.screenshot_png_base64 = this.exec(["exec-out", "screencap", "-p"])
        .toString("base64");
    }
    return result;
  }

  screenUnderstandLocal(args = {}) {
    const screen = this.screenGet({ include_screenshot: false });
    const maxVisible = Math.max(1, Number(args.max_visible_text ?? 80));
    return {
      ok: true,
      foreground: screen.foreground,
      visible_text: screen.visible_text.slice(0, maxVisible),
      interactive_hint: "ADB transport returns raw accessibility text; Android runtime provides richer local understanding.",
    };
  }

  appsSearch(args = {}) {
    const query = String(args.query ?? "").toLowerCase();
    const limit = Math.max(1, Number(args.limit ?? 80));
    const raw = this.shell(["pm", "list", "packages"], { allowFailure: true });
    const packages = raw.split(/\r?\n/gu)
      .map((line) => line.replace(/^package:/u, "").trim())
      .filter(Boolean)
      .filter((pkg) => !query || pkg.toLowerCase().includes(query))
      .slice(0, limit)
      .map((pkg) => ({ package: pkg }));
    return { ok: true, packages };
  }

  openApp(args = {}) {
    const pkg = args.package || args.package_name;
    if (!pkg) {
      return missing("package");
    }
    this.shell(["monkey", "-p", String(pkg), "1"]);
    return { ok: true, package: String(pkg) };
  }

  openUrl(args = {}) {
    const url = args.url;
    if (!url) {
      return missing("url");
    }
    this.shell(["am", "start", "-a", "android.intent.action.VIEW", "-d", String(url)]);
    return { ok: true, url: String(url) };
  }

  tap(args = {}) {
    const x = numberArg(args.x, "x");
    const y = numberArg(args.y, "y");
    this.shell(["input", "tap", String(x), String(y)]);
    return { ok: true, x, y };
  }

  swipe(args = {}) {
    const startX = numberArg(args.start_x ?? args.x1, "start_x");
    const startY = numberArg(args.start_y ?? args.y1, "start_y");
    const endX = numberArg(args.end_x ?? args.x2, "end_x");
    const endY = numberArg(args.end_y ?? args.y2, "end_y");
    const duration = Math.max(0, Number(args.duration_ms ?? 250));
    this.shell(["input", "swipe", String(startX), String(startY),
      String(endX), String(endY), String(duration)]);
    return { ok: true, start_x: startX, start_y: startY, end_x: endX, end_y: endY, duration_ms: duration };
  }

  typeText(args = {}) {
    const text = args.text;
    if (text == null) {
      return missing("text");
    }
    this.shell(["input", "text", adbInputText(String(text))]);
    return { ok: true, text: String(text) };
  }

  pressKey(args = {}) {
    const key = String(args.key ?? args.keycode ?? "").trim();
    if (!key) {
      return missing("key");
    }
    this.shell(["input", "keyevent", normalizeKey(key)]);
    return { ok: true, key };
  }

  setClipboard(args = {}) {
    const text = args.text;
    if (text == null) {
      return missing("text");
    }
    this.shell(["cmd", "clipboard", "set", String(text)]);
    return { ok: true };
  }

  settingGet(key, fallback = "") {
    if (this.dryRun) {
      return fallback;
    }
    const value = this.shell(["settings", "get", "secure", key], { allowFailure: true }).trim();
    return value === "" || value === "null" ? fallback : value;
  }

  settingPut(key, value) {
    if (this.dryRun) {
      return;
    }
    this.shell(["settings", "put", "secure", key, String(value)]);
  }

  shell(args, options = {}) {
    return this.exec(["shell", ...args], options).toString("utf8").trim();
  }

  exec(args, options = {}) {
    const fullArgs = [];
    if (this.serial) {
      fullArgs.push("-s", this.serial);
    }
    fullArgs.push(...args);
    try {
      return execFileSync(this.adb, fullArgs, {
        timeout: this.timeoutMs,
        stdio: ["ignore", "pipe", options.allowFailure ? "pipe" : "inherit"],
      });
    } catch (error) {
      if (options.allowFailure) {
        return Buffer.from(error.stdout?.toString() || error.stderr?.toString() || "");
      }
      throw error;
    }
  }
}

export function loadManifestCommands(candidates = MANIFEST_CANDIDATES) {
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      const manifest = JSON.parse(fs.readFileSync(candidate, "utf8"));
      return manifest.commands ?? [];
    }
  }
  throw new Error("openphone-commands.json manifest not found next to the ADB transport");
}

export function confirmationMap(commands) {
  const out = new Map();
  for (const command of commands) {
    const confirmation = command.confirmation ?? "none";
    out.set(command.name, confirmation);
    for (const alias of command.aliases ?? []) {
      out.set(alias, confirmation);
    }
  }
  return out;
}

export function cleanRuntime(value) {
  const clean = String(value ?? "").trim().toLowerCase();
  if (clean === "phone" || clean === "local" || clean === "builtin") {
    return "builtin";
  }
  if (clean === "openclaw") {
    return "openclaw";
  }
  throw new Error(`unsupported runtime: ${value}`);
}

function numberArg(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    throw new Error(`${name} must be a number`);
  }
  return Math.round(number);
}

function missing(name) {
  return {
    ok: false,
    error: {
      code: "missing_argument",
      message: `${name} is required`,
    },
  };
}

function truthySetting(value) {
  const clean = String(value ?? "").trim().toLowerCase();
  return clean === "1" || clean === "true" || clean === "yes";
}

function adbInputText(text) {
  return text
    .replace(/%/gu, "\\%")
    .replace(/\s/gu, "%s")
    .replace(/'/gu, "\\'");
}

function normalizeKey(key) {
  const upper = key.toUpperCase().replace(/^KEYCODE_/u, "");
  const known = new Set(["BACK", "HOME", "ENTER", "TAB", "DEL", "ESCAPE", "DPAD_UP",
    "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "VOLUME_UP", "VOLUME_DOWN"]);
  if (/^\d+$/u.test(upper)) {
    return upper;
  }
  return known.has(upper) ? `KEYCODE_${upper}` : key;
}

function focusedWindow(dumpsysWindow) {
  const line = String(dumpsysWindow ?? "")
    .split(/\r?\n/gu)
    .find((item) => item.includes("mCurrentFocus") || item.includes("mFocusedApp"));
  return line ? line.trim() : "";
}

function visibleText(xml) {
  const out = [];
  for (const match of String(xml ?? "").matchAll(/text="([^"]*)"/gu)) {
    const text = decodeXml(match[1]).trim();
    if (text) {
      out.push(text);
    }
  }
  return [...new Set(out)];
}

function decodeXml(value) {
  return value
    .replace(/&quot;/gu, "\"")
    .replace(/&apos;/gu, "'")
    .replace(/&lt;/gu, "<")
    .replace(/&gt;/gu, ">")
    .replace(/&amp;/gu, "&");
}
