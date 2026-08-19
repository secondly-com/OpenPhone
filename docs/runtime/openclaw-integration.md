# OpenClaw Integration

OpenClaw support is intentionally split between Android and an installable
OpenClaw plugin.

## Android Adapter

Path:

```text
overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/runtime/adapters/openclaw/
```

Responsibilities:

- Connect to an OpenClaw gateway.
- Authenticate as an OpenPhone Android node.
- Convert phone attention requests into stock OpenClaw `agent.request` events.
- Convert OpenClaw `node.invoke.request` events into generic
  `RuntimeToolRequest`s.
- Return tool results through `node.invoke.result`.
- Send confirmation required/resolved events through existing node event paths.
- Map `openphone.surface.present|replace|dismiss` node events to the generic
  runtime surface lifecycle, accepting only explicit assistant-output
  envelopes.
- Map local surface invocation, result, and dismissal events back to
  `openphone.surface.*` node events.
- Mark active phone sessions failed and leave their last accepted surface
  inspectable if the gateway disconnects before completion.

The adapter should not define OpenClaw core policy. Policy belongs in the plugin.
Surface validation, rendering, revision checks, and phone-tool execution remain
Android responsibilities rather than plugin or gateway responsibilities.

## Plugin

Path:

```text
integrations/openclaw-plugin/
```

Responsibilities:

- Register OpenPhone Android node command policy.
- Keep screen/app reads separate from private reads and dangerous actions.
- Use existing OpenClaw plugin and node-invoke policy surfaces.

This keeps OpenPhone out of OpenClaw core while still giving OpenClaw a
reviewable integration point.

## Validation

The live smoke script runs against a booted OpenPhone Android target and a real
OpenClaw gateway with the OpenPhone plugin installed:

```sh
ANDROID_SERIAL=emulator-5584 \
OPENPHONE_OPENCLAW_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
scripts/smoke-test-openclaw-runtime.sh
```

The OpenPhone SDK phone emulator is a valid target for this smoke. It proves
that Android connects to OpenClaw as an OpenPhone node, the plugin exposes the
approved command surface, and OpenClaw can invoke `openphone.screen.get`.

Physical Pixel 9a validation is still required for hardware buttons, radio,
camera, fingerprint, recovery/OTA, and release acceptance.
