# shared/contracts

Platform-neutral contracts that both the iOS and Android OpenPhone agents
consume. This directory is the single source of truth for the pieces that must
stay identical across platforms, extracted here to lower the eventual
main-repo merge cost (see `IOS_PLAN.md` Tier 3 / Gate F).

This is purely additive. It does not change any runtime behavior; the iOS
daemon still embeds these definitions in `ios/agentd/src/main.m`. When the
daemon's tool surface, decision schema, or capability list changes, update the
matching file here in the same change.

## Files

| File | Source of truth | Consumed by |
|---|---|---|
| `model-tools.json` | `OPModelToolNames()` / `OPModelToolCapability()` / `OPModelToolDrivesUI()` in `ios/agentd/src/main.m` | Model/Realtime tool registration on both platforms |
| `model-decision.v3.schema.json` | `OPModelParseDecision` in `ios/agentd/src/main.m` | Model decision parser/validator on both platforms |
| `capabilities.json` | Canonical capability + risk list (mirrors `contracts/protocol/openphone-capabilities.json`) | Policy/consent gating on both platforms |

## Relationship to `contracts/`

`contracts/` is the incoming Android mirror (schemas + protocol snapshots) used
to keep iOS aligned during private development. `shared/contracts/` is the
outgoing, deduplicated set both platforms are meant to build against after the
merge. As the merge proceeds, `contracts/` collapses into this directory.

## Consumption check

Both platforms can consume these as plain JSON:

- **iOS:** the daemon already hard-codes the same values in `main.m`; a build
  or test step can diff the embedded list against `model-tools.json` to catch
  drift.
- **Android:** load `model-tools.json` to register the tool surface and
  `capabilities.json` to drive consent, then validate model output against
  `model-decision.v3.schema.json`.
