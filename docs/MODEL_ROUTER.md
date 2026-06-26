# OpenPhone Model Router

OpenPhone uses an Android-local model router for bring-your-own-key and
self-hosted model endpoints. The router is not a required extra server. It is
the Android-side model abstraction that lets the same agent runtime call
OpenAI, Ollama, Qwen Omni realtime runtimes, OpenAI-compatible
chat-completions servers, or the optional remote OpenPhone broker.

## Runtime Shape

```text
OpenPhone Assistant on Android
  -> ModelAdapter / ModelEndpointConfig
  -> selected provider endpoint
     - OpenAI Responses
     - OpenAI-compatible /v1/chat/completions
     - Ollama /api/chat
     - Qwen Omni /v1/chat/completions + /v1/realtime
     - optional remote OpenPhone broker
```

The phone still owns screen capture, UI-tree context, policy checks, action
execution, audit, and trajectory recording. The selected model endpoint only
receives model prompts, task-scoped screen context, screenshots when enabled,
and tool-result history.

## Provider Modes

- `local_heuristic`: no network model call. This is a limited deterministic
  fallback for simple development tasks.
- `openai_responses`: direct OpenAI BYOK. The phone stores the OpenAI key and
  calls the Responses and transcription endpoints directly.
- `openai_compatible_chat`: direct BYOK/self-hosted chat-completions endpoint.
  The phone sends OpenAI-compatible `/v1/chat/completions` requests.
- `ollama_chat`: direct Ollama endpoint. The phone sends `/api/chat` requests.
- `qwen_omni_realtime`: direct Qwen Omni endpoint. The phone sends
  OpenAI-compatible `/v1/chat/completions` requests for typed tasks and uses
  an OpenAI-style `/v1/realtime` WebSocket for live voice.
- `remote_broker`: optional remote OpenPhone broker. This remains useful for
  server-side provider-key custody, fleets, central policy, and request limits,
  but it is not required for BYOK.

## Request Translation

The OpenPhone agent code builds one Responses-shaped internal request with:

- model id,
- prompt text,
- optional `input_image` screenshot data URLs,
- metadata,
- max output tokens.

The Android router then translates at the HTTP boundary:

```text
OpenAI / remote broker:
  internal Responses request -> /v1/responses

OpenAI-compatible:
  internal Responses request -> /v1/chat/completions
  provider response -> {"output_text":"..."}

Ollama:
  internal Responses request -> /api/chat
  provider response -> {"output_text":"..."}

Qwen Omni:
  internal Responses request -> /v1/chat/completions for typed tasks
  live voice -> ws://.../v1/realtime multimodal session
```

The rest of the agent loop continues to parse model text exactly as before.
For autonomous tasks, that text must contain the JSON action decision expected
by the existing OpenPhone agent prompt.

## Current Implementation

Android settings expose provider selection, endpoint URL, model id, and keys
where needed. Settings are stored in assistant-private preferences so foreground
chat/tasks, AI Sheet screen answers, background jobs, and watcher semantic
judgment all read the same provider configuration.

The HTTP router currently supports:

- OpenAI Responses requests.
- Remote broker Responses requests.
- OpenAI-compatible chat-completions requests, including vision content using
  `image_url` message parts.
- Ollama chat requests, including vision images using Ollama message `images`.
- Qwen Omni realtime sessions through the shared `MultimodalSession`
  abstraction. OpenAI Realtime and Qwen Omni now use the same activity-level
  lifecycle, transcript callbacks, tool-result callbacks, cancellation path,
  and UI state.

Classic voice transcription is available for OpenAI and the optional remote
broker. Ollama and generic OpenAI-compatible model endpoints can run typed chat
and tasks, but they do not provide transcription until a provider-specific STT
adapter is added.

Live realtime voice no longer assumes one provider-specific class at the
activity boundary. `MultimodalSession` is the app-level contract:

```text
AssistantActivityBackend
  -> MultimodalSession
     - OpenAiRealtimeVoiceSession
     - GeminiLiveVoiceSession
     - QwenOmniRealtimeSession
```

OpenAI Realtime uses server-side turn detection. Qwen Omni through vLLM-Omni
uses a simpler OpenAI-style WebSocket flow: the phone sends
`input_audio_buffer.append`, performs an explicit
`input_audio_buffer.commit`, and accepts `response.audio.delta` events whose
audio payload can be in `audio` rather than `delta`. The Android session
handles both shapes behind the same callback interface.

Qwen Omni phone-control parity depends on the served runtime. If the runtime
supports OpenAI-compatible realtime function/tool calls, the same OpenPhone
tool executor path can be used. If it only supports audio/text realtime, live
Qwen Omni can still act as a speech-to-speech multimodal session, while typed
tool-using tasks continue through `/v1/chat/completions`.

## Model Roles

The current Android router stores one primary model id per provider. That is
enough for text chat, task planning, and VLM calls when the selected endpoint
accepts images. BYO model support should evolve from one model id into a
profile with explicit roles:

- `planner`: text reasoning, tool selection, JSON action decisions.
- `vision`: screenshot and UI-image understanding.
- `stt`: speech-to-text for classic push-to-talk voice.
- `tts`: optional text-to-speech for spoken replies.
- `realtime`: full-duplex audio session when a provider supports a live
  multimodal API.

Provider presets can fill those roles in two ways:

- A specialist profile maps roles to separate models, for example local Ollama
  Qwen for `planner`/`vision`, faster-whisper for `stt`, and a separate TTS
  service for `tts`.
- An omni profile maps multiple roles to one model only when the provider API
  actually supports those modalities in one session, for example a realtime
  multimodal endpoint that accepts audio, screen images, text, tools, and
  returns spoken audio.

The agent loop should not care which profile shape is selected. It asks for a
role capability, and the router chooses either the single omni session or the
specialist adapter for that role. If an endpoint advertises vision but not
audio, voice falls back to the classic pipeline: `stt -> planner/vision -> tts`.
If an endpoint advertises realtime audio and tools, live voice can use the
single realtime adapter directly.

The current implementation already has the app-level realtime role interface.
The next cleanup is to store separate role slots in settings instead of using
one provider mode plus one model id.

## Multimodal Testing

The direct Ollama route has been smoke-tested with text-only Qwen and image
VLM Qwen models over `adb reverse`:

- `qwen2.5:0.5b`: Android shell reached host Ollama and completed a text chat
  request.
- `qwen2.5vl:3b`: Android shell reached host Ollama, sent an image in the
  Ollama message `images` array, and read the expected title text.
- `qwen3-vl:2b`: Android shell reached host Ollama, sent the same image
  request, and read the expected title text.

This verifies the Android-to-Ollama request shape used by the router. It does
not verify the updated settings UI on device unless a fresh assistant APK is
built and installed from this checkout.

## Endpoint Examples

OpenAI-compatible:

```text
Provider: OpenAI-compatible
Base URL: https://model.example.com/v1
Model: Qwen/Qwen2.5-VL-7B-Instruct
API key: <optional or provider-specific>
```

The base URL may also be the full endpoint:

```text
https://model.example.com/v1/chat/completions
```

Ollama:

```text
Provider: Ollama
Ollama URL: http://192.168.1.20:11434
Model: qwen2.5vl:7b
```

The URL may also be the full endpoint:

```text
http://192.168.1.20:11434/api/chat
```

Qwen Omni through vLLM-Omni:

```text
Provider: Qwen Omni
Qwen Omni URL: http://192.168.1.20:8091
Model: Qwen/Qwen3-Omni-30B-A3B-Instruct
API key: <optional or provider-specific>
```

The URL may also be the full realtime WebSocket endpoint:

```text
ws://192.168.1.20:8091/v1/realtime
```

For vLLM-Omni, a typical server shape is:

```text
vllm serve Qwen/Qwen3-Omni-30B-A3B-Instruct --omni --port 8091
```

## Cleanup Plan

1. Keep the existing remote Python broker as an optional deployment path.
2. Treat Android `ModelEndpointConfig` as the source of truth for selected
   provider mode, endpoint URL, model id, and key material.
3. Route all assistant model surfaces through the same stored config:
   foreground chat/tasks, AI Sheet screen answers, background jobs, and watcher
   semantic judgment.
4. Keep provider translation at the adapter boundary so the agent prompt,
   tool loop, policy layer, and action executor stay provider-neutral.
5. Add provider-specific transcription adapters next for Whisper/faster-whisper
   or OpenAI-compatible STT endpoints.
6. Add first-class role settings for `planner`, `vision`, `stt`, `tts`, and
   `realtime` so a true omni model can fill multiple roles and specialist
   models can fill them separately.
7. Add a native on-device inference adapter later if the target hardware can
   run a useful text/vision model locally.

## Security Notes

BYOK direct mode stores provider credentials on the device. The current
implementation keeps them in assistant-private storage and avoids writing them
to trajectories or logs. A production hardening pass should move secret storage
to Android Keystore-backed storage and add explicit export/clear controls.

The app allows cleartext HTTP for direct local-network endpoints so Ollama can
work out of the box. Internet-facing endpoints should use HTTPS.
