# App and OS Boundary

OpenPhone has one product experience with two possible phone capability
profiles:

- **OpenPhone App** uses Android public APIs and user-granted roles and
  permissions. It is the future Play-distributable profile.
- **OpenPhone OS** adds a privileged execution adapter, framework services,
  SystemUI surfaces, keyguard configuration, and system policy enforcement.

Most product logic should be shared. The OS layer should remain a small,
auditable authority rather than becoming a second assistant implementation.

## Dependency Direction

```text
AI Home / generated surfaces / model and runtime adapters
                         |
                         v
                PhoneToolGateway
                    /         \
                   v           v
        public Android app   OpenPhone OS adapter
        implementation      (framework Binder client)
                                  |
                                  v
                       system_server / SystemUI
```

Code above `PhoneToolGateway` must not import `android.openphone` hidden APIs,
construct `FrameworkToolExecutor`, or decide that a privileged action is
authorized. It may request a registered tool, show review UI, and interpret a
structured result.

The gateway reports a stable profile and whether each tool is supported. A
smaller implementation must deny an unsupported tool explicitly; it must not
silently fall back to accessibility automation or a lower-risk action.

## Source Ownership

| Layer | Current source | Responsibility |
| --- | --- | --- |
| Portable product | `assistant/actions`, `model`, `orchestrator`, `runtime`, `surface`, and Compose UI | Conversation, model adapters, tool requests, adaptive UI, runtime sessions, and user review presentation |
| Phone boundary | `assistant/platform/PhoneToolGateway.java` | Stable app-to-phone execution contract and capability-profile seam |
| OpenPhone OS adapter | `assistant/platform/OpenPhoneOsToolGateway.java` and `assistant/agent/FrameworkToolExecutor.java` | Translate registered tools into the hidden OpenPhone framework manager and Android integrations |
| OS authority | `patches/frameworks_base`, Settings patches, SystemUI patches, and SELinux policy | Screen/input authority, secure confirmation, durable audit, island rendering, keyguard-aware behavior, and privileged state |

The current privileged APK is still the only build artifact. This boundary is
the first extraction step, not a claim that the APK can already be uploaded to
Google Play.

## Capability Placement

The public app profile can own AI Home as a user-selected launcher, immersive
window UI, voice and text interaction, generated surfaces, model/runtime
adapters, local history, public Android intents, and scheduled work that fits
normal Android limits.

The OS profile remains authoritative for:

- SystemUI-owned island and keyguard-safe rendering;
- non-secure lock-screen defaults and global hardware gestures;
- silent screen context and capture;
- cross-app input and task control;
- secure settings and other signature/privileged operations;
- tamper-resistant confirmation, policy, and audit storage;
- stronger direct-boot and always-available execution guarantees.

Public Android roles or APIs can cover some phone, SMS, notification, calendar,
contact, and launcher features. Their availability must be represented as
capabilities of the active gateway, never inferred from the package name.

## Extraction Sequence

Keep this work in reviewable follow-up changes:

1. Route runtime and adaptive-surface execution through `PhoneToolGateway`.
2. Split `FrameworkToolExecutor` into public-Android tools and OS-only tools,
   with both implementations preserving the same result contract.
3. Move settings and durable stores behind app-owned configuration/storage
   interfaces instead of reading arbitrary `Settings.Secure` keys in portable
   packages.
4. Add separate app manifests and build targets: a public-SDK Play profile and
   the current platform-signed `system_ext` profile.
5. Add a machine-readable capability matrix and run the same runtime/surface
   contract suite against both profiles.

Until those steps are complete, changes must keep the existing OpenPhone OS
behavior green and must not weaken framework confirmation or audit paths to
make the app profile easier to implement.
