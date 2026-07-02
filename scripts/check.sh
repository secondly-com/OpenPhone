#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  AGENTS.md
  README.md
  LICENSE
  .github/CONTRIBUTING.md
  .github/SECURITY.md
  docs/README.md
  docs/AI_FIRST_ENGINEERING.md
  docs/AGENT_RUNTIME_V1.md
  docs/ARCHITECTURE.md
  docs/BUILD.md
  docs/CAPABILITIES.md
  docs/DEVICE_SUPPORT.md
  docs/EMULATOR.md
  docs/GMS.md
  docs/LOCAL_AGENT_NOTES.md
  docs/LICENSING.md
  docs/runtime/hermes-integration.md
  docs/runtime/mcp-bridge.md
  docs/runtime/openclaw-integration.md
  docs/runtime/runtime-agent-protocol.md
  docs/runtime/security-model.md
  docs/legal/README.md
  docs/legal/COMMERCIAL.md
  docs/legal/LICENSE.noncommercial
  docs/legal/NOTICE
  docs/legal/THIRD_PARTY_NOTICES.md
  docs/RELEASE_PROCESS.md
  docs/TESTING.md
  docs/releases/README.md
  docs/releases/CHANGELOG.md
  docs/assets/github_hero.png
  docs/releases/0.0.1.md
  schemas/README.md
  schemas/action-request.schema.json
  schemas/action-registry.schema.json
  schemas/action-result.schema.json
  schemas/agent-eval-report.schema.json
  schemas/agent-job.schema.json
  schemas/agent-task.schema.json
  schemas/app-policy.schema.json
  schemas/audit-evidence.schema.json
  schemas/audit-event.schema.json
  schemas/audit-log.schema.json
  schemas/model-tool.schema.json
  schemas/ota-feed.schema.json
  schemas/screen-context.schema.json
  schemas/trajectory-event.schema.json
  .github/workflows/ci.yml
  .github/workflows/emulator.yml
  .github/workflows/eval.yml
  .github/workflows/gcp-lab.yml
  .github/workflows/release.yml
  .github/RUNNERS.md
  .github/ISSUE_TEMPLATE/bug_report.md
  .github/ISSUE_TEMPLATE/feature_request.md
  .github/pull_request_template.md
  docs/devices/MATRIX.md
  docs/devices/README.md
  docs/devices/tegu.md
  manifests/openphone.xml
  scripts/prepare-tegu-device-repos.sh
  scripts/prepare-tegu-dtb.sh
  scripts/generate-release-manifest.sh
  scripts/check-release-notes.sh
  scripts/generate-ota-feed.sh
  scripts/prepare-github-release.sh
  scripts/prepare-release-signing.sh
  scripts/collect-agent-eval.sh
  scripts/diagnose-device-connection.sh
  scripts/download-mindthegapps.sh
  scripts/generate-app-policy-override.sh
  scripts/repair-gms-location-permissions.sh
  scripts/sideload-user-gms.sh
  scripts/rotate-model-broker-secrets.sh
  scripts/push-assistant-apk.sh
  scripts/run-assistant-task.sh
  scripts/pull-latest-trajectory.sh
  scripts/check-runtime-protocol.sh
  scripts/smoke-test-openclaw-device-failures.sh
  scripts/smoke-test-openclaw-runtime.sh
  scripts/setup-model-broker-tls.sh
  scripts/sign-release-ota.sh
  scripts/validate-release-artifacts.sh
  scripts/validate-ota-feed.sh
  scripts/validate-audit-evidence-export.sh
  scripts/validate-agent-eval-report.sh
  scripts/validate-trajectory-export.sh
  scripts/smoke-test-model-broker.sh
  scripts/smoke-test-tegu-hardware.sh
  scripts/verify-tegu-device.sh
  scripts/verify-tegu-bootchain.sh
  services/model-broker/README.md
  services/model-broker/devices.example.json
  services/model-broker/deploy/README.md
  services/model-broker/deploy/nginx-openphone-model-broker.conf
  services/model-broker/deploy/openphone-model-broker.env.example
  services/model-broker/deploy/openphone-model-broker.service
  services/model-broker/openphone_model_broker.py
  services/model-broker/providers.example.json
  runtime/protocol/openphone-capabilities.json
  runtime/protocol/openphone-commands.json
  runtime/protocol/openphone-events.json
  runtime/protocol/openphone-runtime-tools.mjs
  runtime/protocol/openphone-runtime.schema.json
  runtime/protocol/validate-runtime-protocol.mjs
  integrations/adb/openphone-adb-transport.mjs
  integrations/cli/README.md
  integrations/cli/package.json
  integrations/cli/src/index.mjs
  tests/README.md
  tests/integrations/runtime-cli-contract.mjs
  tests/integrations/runtime-mcp-contract.mjs
  tests/integrations/openclaw-plugin-policy-contract.mjs
  tests/integrations/runtime-package-contract.mjs
  integrations/mcp-server/README.md
  integrations/mcp-server/package.json
  integrations/mcp-server/src/index.mjs
  integrations/openclaw-plugin/README.md
  integrations/openclaw-plugin/dist/index.d.ts
  integrations/openclaw-plugin/dist/index.js
  integrations/openclaw-plugin/openclaw.plugin.json
  integrations/openclaw-plugin/package.json
  integrations/openclaw-plugin/src/index.ts
  integrations/openclaw-plugin/src/openclaw-plugin-sdk.d.ts
  integrations/openclaw-plugin/tsconfig.json
  overlay/vendor/openphone/AndroidProducts.mk
  overlay/vendor/openphone/config/openphone_capabilities.json
  overlay/vendor/openphone/config/openphone_action_registry.json
  overlay/vendor/openphone/config/openphone_app_policy.json
  overlay/vendor/openphone/config/openphone_model_tools.json
  overlay/vendor/openphone/config/openphone_policy.json
  overlay/vendor/openphone/products/openphone_common.mk
  overlay/vendor/openphone/products/openphone_arm64.mk
  overlay/vendor/openphone/products/openphone_sdk_phone_arm64.mk
  overlay/vendor/openphone/products/openphone_sdk_phone_x86_64.mk
  overlay/vendor/openphone/products/openphone_tegu.mk
  scripts/bootstrap-android-build-host.sh
  scripts/build-emulator.sh
  scripts/run-emulator-smoke.sh
  scripts/run-emulator.sh
  scripts/lab/allocate-slot.sh
  scripts/lab/up.sh
  scripts/lab/down.sh
  scripts/lab/local-up.sh
  scripts/lab/local-down.sh
  scripts/lab/smoke.sh
  scripts/lab/prepare-local.sh
  scripts/lab/install-android-sdk-tools.sh
  scripts/lab/gcp/common.sh
  scripts/lab/gcp/setup-wif.sh
  scripts/lab/gcp/create-vm.sh
  scripts/lab/gcp/delete-vm.sh
  scripts/lab/gcp/bootstrap-vm.sh
  scripts/lab/gcp/prewarm-cache.sh
  scripts/lab/gcp/run-smoke.sh
  scripts/lab/gcp/seed-cache-from-boot-disk.sh
  overlay/packages/apps/OpenPhoneAssistant/Android.bp
  overlay/packages/apps/OpenPhoneAssistant/AndroidManifest.xml
  overlay/packages/apps/OpenPhoneAssistant/LICENSE
  overlay/packages/apps/OpenPhoneAssistant/res/drawable/ic_openphone_tile.xml
  overlay/packages/apps/OpenPhoneAssistant/res/xml/openphone_accessibility_service.xml
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/OpenPhoneAccessibilityService.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/OpenPhoneNotificationController.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/OpenPhoneQuickSettingsTileService.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/OpenPhoneTriggerReceiver.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/PointerOverlayController.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/IOpenPhoneAssistant.aidl
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/agent/FrameworkToolExecutor.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/agent/TrajectoryRecorder.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/model/ModelAdapter.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/model/ModelEndpointConfig.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/model/LocalHeuristicModelAdapter.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/model/OpenAiRealtimeAdapter.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/ota/OtaUpdateClient.java
  overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/policy/AppCapabilityPolicy.java
  patches/frameworks_base/0001-OpenPhone-add-agent-manager-framework-service.patch
  patches/frameworks_base/0002-OpenPhone-add-foreground-context-and-audit-mediation.patch
  patches/frameworks_base/0003-OpenPhone-add-task-scoped-input-action-execution.patch
  patches/frameworks_base/0004-OpenPhone-persist-agent-audit-log.patch
  patches/frameworks_base/0005-OpenPhone-add-pending-action-confirmation-flow.patch
  patches/frameworks_base/0006-OpenPhone-add-clipboard-action-execution.patch
  patches/frameworks_base/0007-OpenPhone-add-confirmed-share-action.patch
  patches/frameworks_base/0008-OpenPhone-add-task-screen-and-pointer-APIs.patch
  patches/frameworks_base/0009-OpenPhone-add-opt-in-screenshot-payloads.patch
  patches/frameworks_base/0010-OpenPhone-capture-screenshots-as-system-server.patch
  patches/frameworks_base/0011-OpenPhone-add-SystemUI-agent-QS-tile.patch
  patches/frameworks_base/0012-OpenPhone-add-mediated-open-url-action.patch
  patches/packages_apps_Settings/0001-OpenPhone-add-About-phone-version-surface.patch
  patches/packages_apps_Settings/0002-OpenPhone-add-settings-dashboard.patch
  patches/packages_apps_Settings/0003-OpenPhone-add-Settings-hosted-audit-and-grant-pages.patch
  patches/packages_apps_Settings/0004-OpenPhone-add-durable-task-grant-defaults.patch
  patches/system_sepolicy/0001-OpenPhone-label-agent-manager-service.patch
)

for file in "${required[@]}"; do
  [[ -f "$root/$file" ]] || {
    printf 'missing required file: %s\n' "$file" >&2
    exit 1
  }
done

for script in "$root"/scripts/*.sh "$root"/scripts/lab/*.sh "$root"/scripts/lab/gcp/*.sh; do
  [[ -e "$script" ]] || continue
  bash -n "$script"
done

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$root/manifests/openphone.xml"
  xmllint --noout "$root/overlay/packages/apps/OpenPhoneAssistant/AndroidManifest.xml"
  xmllint --noout "$root/overlay/vendor/openphone/config/privapp-permissions-openphone.xml"
  xmllint --noout "$root/overlay/vendor/openphone/config/sysconfig-openphone.xml"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' "$root"
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
scan_roots = [
    root / "docs",
    root / "overlay",
]
for scan_root in scan_roots:
    for path in sorted(scan_root.rglob("*.json")):
        with path.open("r", encoding="utf-8") as handle:
            json.load(handle)
PY
  python3 - <<'PY' "$root"
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
capability_path = root / "overlay/vendor/openphone/config/openphone_capabilities.json"
policy_path = root / "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/policy/PolicyEngine.java"
capability_config = json.loads(capability_path.read_text(encoding="utf-8"))
capabilities = capability_config.get("capabilities", [])
expected = {}
valid_risks = {"low", "medium", "high"}
valid_defaults = {"task_grant", "confirm", "explicit_confirm"}
for capability in capabilities:
    capability_id = capability.get("id")
    risk = capability.get("risk")
    default = capability.get("default")
    if not capability_id:
        raise SystemExit("capability entry missing id")
    if capability_id in expected:
        raise SystemExit(f"duplicate capability id: {capability_id}")
    if risk not in valid_risks:
        raise SystemExit(f"invalid risk for {capability_id}: {risk}")
    if default not in valid_defaults:
        raise SystemExit(f"invalid default for {capability_id}: {default}")
    expected[capability_id] = risk

policy_source = policy_path.read_text(encoding="utf-8")
actual = {}
for capability_id, risk_name in re.findall(
        r'risks\.put\("([^"]+)",\s*CapabilityRisk\.([A-Z]+)\)', policy_source):
    actual[capability_id] = risk_name.lower()

missing = sorted(set(expected) - set(actual))
if missing:
    raise SystemExit("PolicyEngine missing capabilities: " + ", ".join(missing))

mismatched = []
for capability_id, expected_risk in sorted(expected.items()):
    actual_risk = actual.get(capability_id)
    if actual_risk != expected_risk:
        mismatched.append(f"{capability_id}: registry={expected_risk} policy={actual_risk}")
if mismatched:
    raise SystemExit("PolicyEngine risk mismatch: " + "; ".join(mismatched))

tool_path = root / "overlay/vendor/openphone/config/openphone_model_tools.json"
action_registry_path = root / "overlay/vendor/openphone/config/openphone_action_registry.json"
app_policy_path = root / "overlay/vendor/openphone/config/openphone_app_policy.json"
action_registry_schema_path = root / "schemas/action-registry.schema.json"
action_schema_path = root / "schemas/action-request.schema.json"
audit_schema_path = root / "schemas/audit-event.schema.json"
screen_schema_path = root / "schemas/screen-context.schema.json"
trajectory_schema_path = root / "schemas/trajectory-event.schema.json"
executor_path = root / "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/agent/FrameworkToolExecutor.java"
adapter_path = root / "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/model/OpenAiRealtimeAdapter.java"
trajectory_path = root / "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/agent/TrajectoryRecorder.java"
accessibility_path = root / "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/OpenPhoneAccessibilityService.java"
ota_client_path = root / "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/ota/OtaUpdateClient.java"
app_capability_policy_path = root / "overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/policy/AppCapabilityPolicy.java"
tool_config = json.loads(tool_path.read_text(encoding="utf-8"))
action_registry_config = json.loads(action_registry_path.read_text(encoding="utf-8"))
app_policy_config = json.loads(app_policy_path.read_text(encoding="utf-8"))
action_registry_schema = json.loads(action_registry_schema_path.read_text(encoding="utf-8"))
action_schema = json.loads(action_schema_path.read_text(encoding="utf-8"))
audit_schema = json.loads(audit_schema_path.read_text(encoding="utf-8"))
screen_schema = json.loads(screen_schema_path.read_text(encoding="utf-8"))
trajectory_schema = json.loads(trajectory_schema_path.read_text(encoding="utf-8"))
tools = tool_config.get("tools", [])
actions = action_registry_config.get("actions", [])
action_types = set(action_schema["properties"]["type"]["enum"])
audit_event_types = set(audit_schema["properties"]["event_type"]["enum"])
trajectory_event_types = set(trajectory_schema["properties"]["event"]["enum"])
tool_capabilities = set(expected)
tool_names = {}
valid_kinds = {"observe", "action", "control"}
for tool in tools:
    name = tool.get("name")
    capability = tool.get("capability")
    kind = tool.get("kind")
    if not name:
        raise SystemExit("model tool entry missing name")
    if name in tool_names:
        raise SystemExit(f"duplicate model tool: {name}")
    if capability not in tool_capabilities:
        raise SystemExit(f"model tool {name} references unknown capability: {capability}")
    if kind not in valid_kinds:
        raise SystemExit(f"model tool {name} has invalid kind: {kind}")
    if not isinstance(tool.get("requires_reason"), bool):
        raise SystemExit(f"model tool {name} requires_reason must be boolean")
    tool_names[name] = tool

if action_registry_config.get("version") != action_registry_schema["properties"]["version"]["const"]:
    raise SystemExit("action registry version mismatch")
valid_action_kinds = set(action_registry_schema["properties"]["actions"]["items"]
                         ["properties"]["kind"]["enum"])
valid_action_risks = set(action_registry_schema["properties"]["actions"]["items"]
                         ["properties"]["risk_class"]["enum"])
valid_authorization = set(action_registry_schema["properties"]["actions"]["items"]
                          ["properties"]["authorization_policy"]["enum"])
valid_callers = set(action_registry_schema["properties"]["actions"]["items"]
                    ["properties"]["allowed_callers"]["items"]["enum"])
action_names = {}
tool_to_actions = {}
for action in actions:
    name = action.get("name")
    model_tool = action.get("model_tool")
    if not name:
        raise SystemExit("action registry entry missing name")
    if name in action_names:
        raise SystemExit(f"duplicate action registry action: {name}")
    if not re.match(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$", name):
        raise SystemExit(f"invalid action registry action name: {name}")
    if model_tool not in tool_names:
        raise SystemExit(f"action {name} references unknown model tool: {model_tool}")
    tool = tool_names[model_tool]
    if action.get("kind") != tool.get("kind"):
        raise SystemExit(f"action {name} kind mismatch with model tool {model_tool}")
    required_capabilities = action.get("required_capabilities")
    if not isinstance(required_capabilities, list) or not required_capabilities:
        raise SystemExit(f"action {name} missing required capabilities")
    if tool.get("capability") not in required_capabilities:
        raise SystemExit(f"action {name} missing model tool capability "
                         f"{tool.get('capability')}")
    unknown_capabilities = sorted(set(required_capabilities) - tool_capabilities)
    if unknown_capabilities:
        raise SystemExit(f"action {name} references unknown capabilities: "
                         + ", ".join(unknown_capabilities))
    primary_capability = tool.get("capability")
    capability_entry = next(
        capability for capability in capabilities
        if capability.get("id") == primary_capability)
    if action.get("risk_class") != capability_entry.get("risk"):
        raise SystemExit(f"action {name} risk mismatch for {primary_capability}: "
                         f"action={action.get('risk_class')} "
                         f"capability={capability_entry.get('risk')}")
    if action.get("authorization_policy") != capability_entry.get("default"):
        raise SystemExit(f"action {name} auth policy mismatch for {primary_capability}: "
                         f"action={action.get('authorization_policy')} "
                         f"capability={capability_entry.get('default')}")
    if action.get("kind") not in valid_action_kinds:
        raise SystemExit(f"action {name} invalid kind: {action.get('kind')}")
    if action.get("risk_class") not in valid_action_risks:
        raise SystemExit(f"action {name} invalid risk: {action.get('risk_class')}")
    if action.get("authorization_policy") not in valid_authorization:
        raise SystemExit(f"action {name} invalid auth policy")
    callers = action.get("allowed_callers")
    if not isinstance(callers, list) or not callers:
        raise SystemExit(f"action {name} missing allowed callers")
    unknown_callers = sorted(set(callers) - valid_callers)
    if unknown_callers:
        raise SystemExit(f"action {name} unknown callers: " + ", ".join(unknown_callers))
    audit_type = action.get("audit_event_type")
    if audit_type not in audit_event_types:
        raise SystemExit(f"action {name} references unknown audit event: {audit_type}")
    for schema_field in ("input_schema_json", "output_schema_json"):
        schema_value = action.get(schema_field)
        if not isinstance(schema_value, dict):
            raise SystemExit(f"action {name} {schema_field} must be an object")
    # The registry generates every model tool surface (prompt catalog,
    # Realtime tool definitions, allowlists, reason enforcement), so input
    # schemas must be complete and consistent with model_tools.json.
    if not action.get("description"):
        raise SystemExit(f"action {name} missing description")
    input_schema = action["input_schema_json"]
    input_properties = input_schema.get("properties")
    if not isinstance(input_properties, dict):
        raise SystemExit(f"action {name} input schema missing properties object")
    input_required = input_schema.get("required")
    if not isinstance(input_required, list):
        raise SystemExit(f"action {name} input schema missing required array")
    unknown_required = sorted(set(input_required) - set(input_properties))
    if unknown_required:
        raise SystemExit(f"action {name} requires unknown inputs: "
                         + ", ".join(unknown_required))
    for property_name, property_schema in input_properties.items():
        if not isinstance(property_schema, dict) or not property_schema.get("type"):
            raise SystemExit(f"action {name} input {property_name} missing type")
        if not property_schema.get("description"):
            raise SystemExit(f"action {name} input {property_name} missing description")
    terminal_tools = {"finish_task", "fail_task"}
    schema_requires_reason = "reason" in input_required and model_tool not in terminal_tools
    if schema_requires_reason != tool["requires_reason"]:
        raise SystemExit(
            f"action {name} reason mismatch: input schema implies "
            f"{schema_requires_reason} but model tool {model_tool} declares "
            f"{tool['requires_reason']}")
    if not action.get("executor_service"):
        raise SystemExit(f"action {name} missing executor_service")
    action_names[name] = action
    tool_to_actions.setdefault(model_tool, []).append(name)

missing_actions_for_tools = sorted(set(tool_names) - set(tool_to_actions))
if missing_actions_for_tools:
    raise SystemExit("action registry missing model tools: "
                     + ", ".join(missing_actions_for_tools))
duplicate_tool_actions = sorted(
    f"{tool}: {', '.join(names)}"
    for tool, names in tool_to_actions.items()
    if len(names) != 1)
if duplicate_tool_actions:
    raise SystemExit("action registry must map each model tool exactly once: "
                     + "; ".join(duplicate_tool_actions))

executor_source = executor_path.read_text(encoding="utf-8")
executor_cases = set(re.findall(r'case "([^"]+)":', executor_source))
missing_executor = sorted(set(tool_names) - executor_cases)
if missing_executor:
    raise SystemExit("FrameworkToolExecutor missing model tools: "
                     + ", ".join(missing_executor))

# Cloud adapters must derive tool surfaces from the action registry via
# ToolCatalog instead of hand-maintained per-tool name allowlists.
responses_adapter_path = (root / "overlay/packages/apps/OpenPhoneAssistant/src/org/"
                          "openphone/assistant/model/OpenAiResponsesAgentAdapter.java")
tool_catalog_path = (root / "overlay/packages/apps/OpenPhoneAssistant/src/org/"
                     "openphone/assistant/actions/ToolCatalog.java")
if not tool_catalog_path.exists():
    raise SystemExit("ToolCatalog.java is missing; adapters need registry-driven tools")
for adapter_file in (adapter_path, responses_adapter_path):
    source = adapter_file.read_text(encoding="utf-8")
    if "ToolCatalog" not in source:
        raise SystemExit(f"{adapter_file.name} must use ToolCatalog for tool surfaces")
    name_allowlist = re.findall(r'"([a-z_]+)"\.equals\(toolName\)\s*\|\|', source)
    if len(set(name_allowlist)) > 8:
        raise SystemExit(
            f"{adapter_file.name} reintroduces a hardcoded tool-name allowlist "
            f"({len(set(name_allowlist))} tools); derive it from the action registry")
adapter_source = adapter_path.read_text(encoding="utf-8")
for stale_capability in ("content.share", "input.text"):
    if stale_capability in adapter_source:
        raise SystemExit(f"OpenAI adapter contains stale capability id: {stale_capability}")
if "Intent.ACTION_VIEW" in executor_source or "startActivity(" in executor_source:
    raise SystemExit("FrameworkToolExecutor must not launch web intents directly")
if "missing_reason:" not in executor_source or "requiresModelReason" not in executor_source:
    raise SystemExit("FrameworkToolExecutor must enforce reason-required model tools")
if "ToolCatalog" not in executor_source:
    raise SystemExit("FrameworkToolExecutor must derive reason enforcement from ToolCatalog")

product_makefile = (root / "overlay/vendor/openphone/products/openphone_common.mk").read_text(
    encoding="utf-8")
for copied_config in (
        "openphone_action_registry.json",
        "openphone_app_policy.json",
        "openphone_capabilities.json",
        "openphone_model_tools.json",
        "openphone_policy.json"):
    if copied_config not in product_makefile:
        raise SystemExit(f"product makefile does not install {copied_config}")

valid_app_policy_decisions = {"inherit", "allow", "confirm", "explicit_confirm", "deny"}
valid_app_policy_match = {"exact", "prefix"}
if app_policy_config.get("version") != 1:
    raise SystemExit("app policy version must be 1")
if app_policy_config.get("default_decision") not in valid_app_policy_decisions:
    raise SystemExit("app policy has invalid default_decision")
overrides = app_policy_config.get("package_overrides")
if not isinstance(overrides, list):
    raise SystemExit("app policy package_overrides must be an array")
for index, override in enumerate(overrides):
    package = override.get("package")
    if not package:
        raise SystemExit(f"app policy override {index} missing package")
    if override.get("match") not in valid_app_policy_match:
        raise SystemExit(f"app policy override {index} has invalid match")
    if override.get("decision") not in valid_app_policy_decisions - {"inherit"}:
        raise SystemExit(f"app policy override {index} has invalid decision")
    if not override.get("reason"):
        raise SystemExit(f"app policy override {index} missing reason")
    capabilities = override.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        raise SystemExit(f"app policy override {index} has no capabilities")
    unknown = sorted(set(capabilities) - tool_capabilities)
    if unknown:
        raise SystemExit(f"app policy override {index} references unknown capabilities: "
                         + ", ".join(unknown))

app_policy_source = app_capability_policy_path.read_text(encoding="utf-8")
for marker in (
        "app_policy.json",
        "openphone_app_policy_overrides",
        "Settings.Secure",
        "package_overrides",
        "settings_secure",
        "explicit_confirm",
        "deny"):
    if marker not in app_policy_source:
        raise SystemExit("AppCapabilityPolicy missing expected marker: " + marker)
if app_policy_source.find("secureOverrides") > app_policy_source.find("policy()"):
    raise SystemExit("AppCapabilityPolicy must evaluate Settings.Secure overrides before seed policy")

emitted_actions = set(re.findall(r'action\("([^"]+)"\)', executor_source))
emitted_actions.update({"back", "home", "recents"})
missing_actions = sorted(emitted_actions - action_types)
if missing_actions:
    raise SystemExit("action-request schema missing executor action types: "
                     + ", ".join(missing_actions))

framework_patch_source = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted((root / "patches/frameworks_base").glob("*.patch"))
)
for action_type in emitted_actions:
    if f'"{action_type}".equals(type)' not in framework_patch_source:
        raise SystemExit(f"framework patch stack missing action handling for: {action_type}")
for action_type, capability in {
    "open_url": "network.use",
    "share": "share.content",
    "copy": "clipboard.write",
    "paste": "clipboard.read",
    "open_app": "apps.launch",
}.items():
    if action_type in emitted_actions and capability not in framework_patch_source:
        raise SystemExit(f"framework patch stack missing capability {capability} "
                         f"for action {action_type}")

recorded_audit_events = set(re.findall(r'recordAudit\("([^"]+)"', framework_patch_source))
missing_audit_events = sorted(recorded_audit_events - audit_event_types)
if missing_audit_events:
    raise SystemExit("audit-event schema missing framework event types: "
                     + ", ".join(missing_audit_events))

trajectory_source = trajectory_path.read_text(encoding="utf-8")
if "openphone.trajectory_event.v1" not in trajectory_source:
    raise SystemExit("TrajectoryRecorder events must include schema marker")
recorded_trajectory_events = set(re.findall(r'append\("([^"]+)"', trajectory_source))
missing_trajectory_events = sorted(recorded_trajectory_events - trajectory_event_types)
if missing_trajectory_events:
    raise SystemExit("trajectory-event schema missing recorder event types: "
                     + ", ".join(missing_trajectory_events))

screen_properties = set(screen_schema["properties"])
element_properties = set(screen_schema["properties"]["interactive_elements"]["items"]["properties"])
window_properties = set(screen_schema["properties"]["windows"]["items"]["properties"])
expected_screen_fields = {
    "source", "timestamp_ms", "visible_text", "interactive_elements", "risk_flags",
    "windows", "foreground_package", "root_packages",
}
expected_element_fields = {
    "id", "kind", "label", "bounds", "enabled", "focused",
    "view_id", "window_id", "sensitive", "risk_hint",
}
expected_window_fields = {"id", "type", "focused", "active", "bounds"}
for field in sorted(expected_screen_fields - screen_properties):
    raise SystemExit(f"screen-context schema missing root field emitted by accessibility path: {field}")
for field in sorted(expected_element_fields - element_properties):
    raise SystemExit(f"screen-context schema missing element field emitted by accessibility path: {field}")
for field in sorted(expected_window_fields - window_properties):
    raise SystemExit(f"screen-context schema missing window field emitted by accessibility path: {field}")
accessibility_source = accessibility_path.read_text(encoding="utf-8")
for risk_flag in (
        "ui_tree_unavailable",
        "visible_text_empty",
        "interactive_elements_empty",
        "sensitive_input_visible",
        "account_or_payment_hint_visible"):
    if risk_flag not in accessibility_source:
        raise SystemExit(f"accessibility source missing expected risk flag: {risk_flag}")

ota_client_source = ota_client_path.read_text(encoding="utf-8")
for expected_ota_fragment in (
        "schema_version",
        "requires_wipe",
        "release_notes_url",
        "Downloads",
        "SHA-256",
        "MessageDigest",
        "MediaStore.Downloads.EXTERNAL_CONTENT_URI"):
    if expected_ota_fragment not in ota_client_source:
        raise SystemExit("OTA update client missing expected behavior marker: "
                         + expected_ota_fragment)
PY
  python3 - <<'PY' "$root/services/model-broker/openphone_model_broker.py"
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
  "$root/scripts/smoke-test-model-broker.sh"
  tmp_env="$(mktemp)"
  cp "$root/services/model-broker/deploy/openphone-model-broker.env.example" "$tmp_env"
  "$root/scripts/rotate-model-broker-secrets.sh" --env-file "$tmp_env" >/dev/null
  python3 - <<'PY' "$tmp_env"
import pathlib
import sys

values = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        values[key] = value
for key in ("OPENPHONE_BROKER_TOKEN_SECRET", "OPENPHONE_BROKER_ADMIN_TOKENS"):
    value = values.get(key, "")
    if len(value) < 40:
        raise SystemExit(f"{key} was not rotated to a strong-looking value")
if values.get("OPENAI_API_KEY") != "":
    raise SystemExit("rotation changed OPENAI_API_KEY")
PY
  rm -f "$tmp_env" "$tmp_env".bak.*
  tmp_env="$(mktemp)"
  cp "$root/services/model-broker/deploy/openphone-model-broker.env.example" "$tmp_env"
  "$root/scripts/rotate-model-broker-secrets.sh" \
    --env-file "$tmp_env" \
    --provider-key sk-openphone-check-provider-key-abcdefghijklmnopqrstuvwxyz >/dev/null
  python3 - <<'PY' "$tmp_env"
import pathlib
import sys

values = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        values[key] = value
if values.get("OPENAI_API_KEY") != "sk-openphone-check-provider-key-abcdefghijklmnopqrstuvwxyz":
    raise SystemExit("provider rotation did not update OPENAI_API_KEY")
if values.get("OPENPHONE_BROKER_TOKEN_SECRET") != "":
    raise SystemExit("provider rotation changed OPENPHONE_BROKER_TOKEN_SECRET")
if values.get("OPENPHONE_BROKER_ADMIN_TOKENS") != "":
    raise SystemExit("provider rotation changed OPENPHONE_BROKER_ADMIN_TOKENS")
PY
  rm -f "$tmp_env" "$tmp_env".bak.*
  tmp_nginx="$(mktemp)"
  tmp_tls_stderr="$(mktemp)"
  "$root/scripts/setup-model-broker-tls.sh" \
    --domain broker.example.com \
    --email ops@example.com \
    --output "$tmp_nginx" >/dev/null 2>"$tmp_tls_stderr"
  grep -q 'server_name broker.example.com;' "$tmp_nginx" || {
    printf 'TLS setup helper did not render broker domain\n' >&2
    exit 1
  }
  grep -q 'certbot --nginx -d broker.example.com' "$tmp_tls_stderr" || {
    printf 'TLS setup helper did not print certbot command\n' >&2
    exit 1
  }
  rm -f "$tmp_nginx" "$tmp_tls_stderr"
  tmp_signing="$(mktemp -d)"
  "$root/scripts/prepare-release-signing.sh" \
    --keys-dir "$tmp_signing/openphone-keys" >/dev/null
  mkdir -p "$tmp_signing/android/build/make/tools/releasetools" "$tmp_signing/out"
  [[ -f "$tmp_signing/openphone-keys/key-map.txt" ]] || {
    printf 'release signing helper did not create key-map.txt\n' >&2
    exit 1
  }
  grep -q 'build/make/target/product/security/platform=platform' \
    "$tmp_signing/openphone-keys/key-map.txt" || {
    printf 'release signing helper did not include platform key mapping\n' >&2
    exit 1
  }
  "$root/scripts/sign-release-ota.sh" \
    --android-dir "$tmp_signing/android" \
    --keys-dir "$tmp_signing/openphone-keys" \
    --target-files "$tmp_signing/input-target_files.zip" \
    --output-dir "$tmp_signing/out" \
    --name check \
    --dry-run > "$tmp_signing/sign-dry-run.txt"
  grep -q 'sign_target_files_apks' "$tmp_signing/sign-dry-run.txt" || {
    printf 'release signing wrapper did not print sign_target_files_apks command\n' >&2
    exit 1
  }
  grep -q 'ota_from_target_files' "$tmp_signing/sign-dry-run.txt" || {
    printf 'release signing wrapper did not print ota_from_target_files command\n' >&2
    exit 1
  }
  rm -rf "$tmp_signing"
  tmp_feed="$(mktemp -d)"
  printf 'fake zip payload' > "$tmp_feed/openphone-check-ota.zip"
  "$root/scripts/generate-ota-feed.sh" \
    --version 0.0.1-check \
    --channel check \
    --device tegu \
    --artifact "$tmp_feed/openphone-check-ota.zip" \
    --base-url https://downloads.example/openphone \
    --release-notes-url https://example.test/openphone/check \
    --output "$tmp_feed/ota-feed.json" \
    --requires-wipe >/dev/null
  "$root/scripts/validate-ota-feed.sh" "$tmp_feed/ota-feed.json" "$tmp_feed" >/dev/null
  rm -rf "$tmp_feed"
  tmp_policy="$(mktemp -d)"
  "$root/scripts/generate-app-policy-override.sh" \
    --package com.example.sensitive \
    --match prefix \
    --capability input.perform \
    --capability screen.capture \
    --decision explicit_confirm \
    --reason "check override generation" \
    --output "$tmp_policy/override.json" >/dev/null
  python3 - <<'PY' "$tmp_policy/override.json" "$root/overlay/vendor/openphone/config/openphone_capabilities.json"
import json
import pathlib
import sys

override = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
capabilities = {
    item["id"]
    for item in json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))["capabilities"]
}
if override["version"] != 1:
    raise SystemExit("override version must be 1")
if override["default_decision"] != "inherit":
    raise SystemExit("override default_decision must be inherit")
entries = override["package_overrides"]
if len(entries) != 1:
    raise SystemExit("override generator should emit exactly one entry")
entry = entries[0]
if entry["package"] != "com.example.sensitive":
    raise SystemExit("override package mismatch")
if entry["match"] != "prefix":
    raise SystemExit("override match mismatch")
if entry["decision"] != "explicit_confirm":
    raise SystemExit("override decision mismatch")
unknown = sorted(set(entry["capabilities"]) - capabilities)
if unknown:
    raise SystemExit("override references unknown capabilities: " + ", ".join(unknown))
PY
  rm -rf "$tmp_policy"
  tmp_trace="$(mktemp -d)"
  mkdir -p "$tmp_trace/session"
  printf '\xff\xd8\xff\xd9' > "$tmp_trace/session/screenshot_000.jpg"
  cat > "$tmp_trace/session/events.jsonl" <<'EOF'
{"schema":"openphone.trajectory_event.v1","index":0,"timestamp_ms":1000,"event":"task_started","payload":{"task_id":"task-check","goal":"check","provider":"local","model":"local","cloud_model":false,"disclosure":"none"}}
{"schema":"openphone.trajectory_event.v1","index":1,"timestamp_ms":1001,"event":"tool_call","payload":{"tool":"get_screen","arguments":{"reason":"check"}}}
{"schema":"openphone.trajectory_event.v1","index":2,"timestamp_ms":1002,"event":"tool_result","payload":{"tool":"get_screen","result":{"status":"ok","screenshot":{"mime_type":"image/jpeg","encoding":"base64","data":"<stored:screenshot_000.jpg>","file":"screenshot_000.jpg","bytes":4}}}}
{"schema":"openphone.trajectory_event.v1","index":3,"timestamp_ms":1003,"event":"agent_result","payload":{"duration_ms":3,"result":{"status":"task.finished"}}}
EOF
  "$root/scripts/validate-trajectory-export.sh" "$tmp_trace/session" >/dev/null
  python3 - <<'PY' "$tmp_trace/session" "$tmp_trace/session.zip"
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(target, "w") as archive:
    for item in source.rglob("*"):
        if item.is_file():
            archive.write(item, pathlib.Path("session") / item.relative_to(source))
PY
  "$root/scripts/validate-trajectory-export.sh" "$tmp_trace/session.zip" >/dev/null
  rm -rf "$tmp_trace"
  tmp_audit="$(mktemp -d)"
  cat > "$tmp_audit/openphone-audit.json" <<'EOF'
{
  "schema": "openphone.audit_evidence.v1",
  "exported_at_ms": 1000,
  "redaction": "api keys, tokens, secrets, and base64 screenshot data removed",
  "service_status": {
    "state": "available",
    "service": "openphone_agent"
  },
  "audit": {
    "events": [
      {
        "timestamp_elapsed_ms": 100,
        "event_type": "task_started",
        "task_id": "task-check",
        "capability": "tasks.observe",
        "decision": "allow_task_scoped",
        "caller_uid": 1000,
        "detail": "check",
        "input_recorded": false
      }
    ],
    "durable": true,
    "source": "system_server.openphone_agent"
  }
}
EOF
  "$root/scripts/validate-audit-evidence-export.sh" "$tmp_audit/openphone-audit.json" >/dev/null
  rm -rf "$tmp_audit"
  tmp_eval="$(mktemp -d)"
  mkdir -p "$tmp_eval/session"
  printf '\xff\xd8\xff\xd9' > "$tmp_eval/session/screenshot_000.jpg"
  cat > "$tmp_eval/session/events.jsonl" <<'EOF'
{"schema":"openphone.trajectory_event.v1","index":0,"timestamp_ms":1000,"event":"task_started","payload":{"task_id":"task-check","goal":"Tell me what screen I am on.","provider":"local","model":"local","cloud_model":false,"disclosure":"none"}}
{"schema":"openphone.trajectory_event.v1","index":1,"timestamp_ms":1001,"event":"tool_call","payload":{"tool":"get_screen","arguments":{"reason":"observe current screen"}}}
{"schema":"openphone.trajectory_event.v1","index":2,"timestamp_ms":1002,"event":"tool_result","payload":{"tool":"get_screen","result":{"status":"ok","screenshot":{"mime_type":"image/jpeg","encoding":"base64","data":"<stored:screenshot_000.jpg>","file":"screenshot_000.jpg","bytes":4}}}}
{"schema":"openphone.trajectory_event.v1","index":3,"timestamp_ms":1003,"event":"agent_result","payload":{"duration_ms":3,"result":{"status":"task.finished"}}}
EOF
  python3 - <<'PY' "$tmp_eval/session" "$tmp_eval/openphone-trajectory.zip"
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(target, "w") as archive:
    for item in source.rglob("*"):
        if item.is_file():
            archive.write(item, pathlib.Path("session") / item.relative_to(source))
PY
  cat > "$tmp_eval/openphone-audit.json" <<'EOF'
{
  "schema": "openphone.audit_evidence.v1",
  "exported_at_ms": 1000,
  "redaction": "api keys, tokens, secrets, and base64 screenshot data removed",
  "service_status": {
    "state": "available",
    "service": "openphone_agent"
  },
  "audit": {
    "events": [
      {
        "timestamp_elapsed_ms": 100,
        "event_type": "task_started",
        "task_id": "task-check",
        "capability": "tasks.observe",
        "decision": "allow_task_scoped",
        "caller_uid": 1000,
        "detail": "check",
        "input_recorded": false
      }
    ],
    "durable": true,
    "source": "system_server.openphone_agent"
  }
}
EOF
  assistant_version_code="$(
    sed -n 's/.*android:versionCode="\([^"]*\)".*/\1/p' \
      "$root/overlay/packages/apps/OpenPhoneAssistant/AndroidManifest.xml" | head -1
  )"
  assistant_version_name="$(
    sed -n 's/.*android:versionName="\([^"]*\)".*/\1/p' \
      "$root/overlay/packages/apps/OpenPhoneAssistant/AndroidManifest.xml" | head -1
  )"
  python3 - <<'PY' \
    "$tmp_eval/agent-eval.json" \
    "$assistant_version_code" \
    "$assistant_version_name"
import json
import pathlib
import sys

path, version_code, version_name = sys.argv[1:]
payload = {
    "schema": "openphone.agent_eval_report.v1",
    "eval_id": "eval-1-observe-current-screen",
    "goal": "Tell me what screen I am on.",
    "device": {
        "codename": "tegu",
        "sku": "GTF7P",
        "serial_redacted": True,
        "slot": "_a",
    },
    "build": {
        "openphone_version": "0.1.0-dev",
        "assistant_version_code": int(version_code),
        "assistant_version_name": version_name,
    },
    "model": {
        "provider": "local",
        "name": "local",
        "transport": "local",
        "cloud": False,
    },
    "result": {
        "status": "pass",
        "summary": "Sample report validates eval evidence packaging.",
    },
    "evidence": {
        "trajectory": "openphone-trajectory.zip",
        "audit": "openphone-audit.json",
        "notes": "Generated by scripts/check.sh.",
    },
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
  "$root/scripts/validate-agent-eval-report.sh" \
    "$tmp_eval/agent-eval.json" "$tmp_eval" >/dev/null
  rm -rf "$tmp_eval"
fi

if grep -R "SPDX-license-identifier-Apache-2.0" \
    "$root/overlay/vendor/openphone" \
    "$root/overlay/packages/apps/OpenPhoneAssistant" >/dev/null 2>&1; then
  printf 'OpenPhone-owned overlay modules must not be marked Apache-2.0\n' >&2
  exit 1
fi

"$root/scripts/check-runtime-protocol.sh"
"$root/scripts/check-assistant-java.sh"

printf 'OpenPhone repo checks passed.\n'
