# Licensing

OpenPhone uses a dual-license model for OpenPhone-owned materials while keeping
upstream Android, LineageOS, Linux, vendor, and third-party licensing separate.

This document is an engineering policy for the repository. It is not legal
advice.

## License Model

OpenPhone-owned materials are licensed as follows:

- Non-commercial use: PolyForm Noncommercial License 1.0.0.
- Commercial use: separate written commercial license required.

The authoritative files are:

- [LICENSE](https://github.com/secondly-com/OpenPhone/blob/main/LICENSE):
  repository license summary and boundary statement.
- [LICENSE.noncommercial](legal/LICENSE.noncommercial): full PolyForm
  Noncommercial License 1.0.0 text.
- [COMMERCIAL.md](legal/COMMERCIAL.md): commercial licensing policy.
- [THIRD_PARTY_NOTICES.md](legal/THIRD_PARTY_NOTICES.md): third-party boundary
  notes.

Because commercial use is restricted, OpenPhone should be described as
`source-available`, not `open source` in the OSI sense.

## OpenPhone-Owned Materials

Unless a file says otherwise, the following are OpenPhone-owned materials:

- OpenPhone assistant app code and resources.
- `vendor/openphone` product, policy, config, and build metadata.
- OpenPhone docs, device notes, schemas, scripts, manifests, and project
  management files.
- OpenPhone-created patches, except where a patch modifies GPL-covered code or
  a file-specific upstream license requires different treatment.

Commercial users need a commercial license for OpenPhone-owned materials,
including commercial OEM, ODM, carrier, enterprise, hosted, managed, internal
business, pilot, proof-of-concept, and white-label uses.

## Android Build Metadata

OpenPhone-owned Android modules should use Soong license metadata with:

```text
legacy_restricted
```

Android's Soong license database does not currently define
`SPDX-license-identifier-PolyForm-Noncommercial-1.0.0` in the target branch.
Use `legacy_restricted` for module metadata and point `license_text` at the
module's OpenPhone license file. Do not mark OpenPhone-owned modules as
Apache-2.0, MIT, BSD, or another permissive license unless that is an
intentional file-specific override.

## Upstream Code

OpenPhone does not relicense upstream code. AOSP, LineageOS, Linux kernel,
device trees, vendor extraction scripts, and third-party dependencies keep
their original licenses.

When OpenPhone patches existing upstream files, preserve existing copyright and
license notices. If the target file is GPL-covered, GPL obligations control for
that modification.

## GPL

GPL-covered components, especially kernel code, remain GPL-covered. Any
distributed GPL modifications must satisfy GPL source obligations. Do not put
non-commercial restrictions on GPL-covered code.

## Vendor Blobs

Vendor blobs may be proprietary. Prefer extraction scripts unless
redistribution is clearly permitted.

Every supported device should document:

- Blob source.
- Blob version.
- Whether blobs are hosted or extracted.
- Redistribution notes.

## Contributions

External contributions require the contributor policy in
[CONTRIBUTING.md](https://github.com/secondly-com/OpenPhone/blob/main/.github/CONTRIBUTING.md). The key requirement is that contributors
must agree that OpenPhone may distribute their contribution under both the
public non-commercial license and separate commercial licenses.
