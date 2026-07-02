# Releases

OpenPhone releases are developer previews until `1.0.0`.

## Where Releases Live

- GitHub Releases: `https://github.com/secondly-com/OpenPhone/releases`
- Release workflow: [../../.github/workflows/release.yml](../../.github/workflows/release.yml)
- Release process: [../RELEASE_PROCESS.md](../RELEASE_PROCESS.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Current draft notes: [0.0.2.md](0.0.2.md)

## Pipeline

The public release pipeline is manual by design:

1. Run repository CI with [ci.yml](../../.github/workflows/ci.yml).
2. Run physical device evals with [eval.yml](../../.github/workflows/eval.yml)
   when a Pixel 9a validation device is available.
3. Update [CHANGELOG.md](CHANGELOG.md) and the target versioned release notes.
4. Trigger [release.yml](../../.github/workflows/release.yml) from GitHub
   Actions with a version such as `v0.0.1`, the release-notes file,
   prerelease setting, and whether the release should become Latest.
5. Release validation checks that the release notes file is
   `docs/releases/<version>.md` and that `docs/releases/CHANGELOG.md` contains
   an exact heading for that version.
6. The GCP release lab builds the OTA, runs the required emulator gate, stages
   the artifact, generates checksums/manifests, validates the release
   directory, and uploads the OTA plus metadata to GitHub Releases.
7. Release notes should link to device support, flashing notes, known issues,
   and validation evidence.

## Latest Release Policy

Preview builds should normally set `make_latest=false`. Set `make_latest=true`
only when the build is the release visitors should see as the current default
download. Use `legacy` only when intentionally delegating latest-selection to
GitHub's older semver/date behavior.

## Artifact Expectations

A device preview release should include:

- OTA ZIP.
- `SHA256SUMS`.
- `ARTIFACTS.md`.
- Release notes.
- Known issues.
- Supported device/codename.
- Required wipe/upgrade notes.
- Validation summary for boot, assistant package, OpenPhone services, and
  hardware smoke checks.

OpenPhone does not publish Google apps, Google Mobile Services packages, vendor
blobs without redistribution rights, private signing keys, private firmware, or
provider API keys.
