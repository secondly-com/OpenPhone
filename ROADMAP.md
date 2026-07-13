# OpenPhone Roadmap

Work is organized into five milestone tracks. Each links to a GitHub
milestone with the full issue list. If you want to contribute, pick an issue
from a track that matches your interests — `good first issue` labels mark
entry-level work, and the [no-build contribution
path](docs/contributing/no-build.md) covers what you can do without an
Android build host.

Tracking issue: [#97](https://github.com/secondly-com/OpenPhone/issues/97).

## [M1: Safety & Policy Hardening](https://github.com/secondly-com/OpenPhone/milestone/1)

Fix policy-bypass and confirmation gaps across the assistant, watchers, and
the ADB/MCP surface. In progress — capability inference now fails closed and
the external ADB/MCP transport refuses state-changing tools by default.
Must land before wider distribution.

## [M2: Testability & Decomposition](https://github.com/secondly-com/OpenPhone/milestone/2)

Break up the assistant god classes, add a JUnit harness, and cover
pure-logic classes with tests. Started — thread-safety fixes are under
review; decomposition has not begun.

## [M3: Upstream Durability](https://github.com/secondly-com/OpenPhone/milestone/3)

Fork `frameworks_base`, add patch-apply canary CI against LineageOS
upstream, and write a LineageOS-bump runbook so upstream bumps stop being
high-risk events. Not started; post-0.1.

## [M4: Provider & Runtime Maturity](https://github.com/secondly-com/OpenPhone/milestone/4)

Broker streaming, rate limiting, and provider dispatch; MCP spec
compliance; runtime protocol versioning; a shared runtime-protocol package.
In progress — MCP stdio framing and broker rate-limiter fixes have landed.

## [M5: Contributor Experience & Community](https://github.com/secondly-com/OpenPhone/milestone/5)

Prebuilt emulator images, a documented no-build contribution path, and
community infrastructure (Discussions, roadmap, contribution docs). In
progress.

---

Updated quarterly. Horizons are directional, not commitments.
