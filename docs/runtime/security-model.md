# Runtime Security Model

OpenPhone treats remote runtimes as powerful but not trusted. The phone remains
the authority for local capabilities, confirmations, and audit.

## Boundaries

- Remote runtimes can request tools only through `RuntimeToolBridge`.
- Tool grants come from the OpenPhone manifest and runtime adapter mapping.
- Mutating commands require Android confirmation unless the session explicitly
  uses `trusted_actions`; high-risk commands still require confirmation.
- Idempotency is scoped by runtime, session, tool, params digest, and key so one
  approval cannot approve a different request.
- OpenClaw device signing seeds are wrapped with AndroidKeyStore before being
  written to app-private storage. Legacy plaintext seed files are read for
  migration and removed after an encrypted write succeeds.
- The smoke-control receiver is disabled by default and additionally gates
  execution to `userdebug`/`eng` builds.
- Plain `ws://` runtime URLs are rejected unless they target local/private
  network hosts; public remote runtimes must use `wss://`.
- Structured UI is accepted only through an explicit assistant-output/surface
  event. The phone rejects runtime/session mismatches, stale revisions,
  unregistered tools, unknown components, excessive documents, remote image
  URLs, and sensitive cross-session artifacts before persistence or rendering.
- Surface actions are declarative bindings, not executable runtime code. They
  re-enter `RuntimeToolBridge`, including idempotency and Android-local
  confirmation.

## Prompt And Context Safety

Runtime context is treated as data. OpenPhone labels metadata and screen
preflight JSON as untrusted data in runtime prompts and redacts screenshot bytes
from prompt text. Actual screenshots are attached as image payloads when
requested.
