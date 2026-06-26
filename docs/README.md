# OpenPhone Documentation

This is the public documentation map for OpenPhone. Start here for current
build, architecture, release, device, and policy docs.

## Start Here

- [Architecture](ARCHITECTURE.md) - system layers, OS services, agent runtime,
  and current implementation boundaries.
- [Model Router](MODEL_ROUTER.md) - Android-local BYOK model routing for
  OpenAI, OpenAI-compatible endpoints, Ollama, Qwen Omni realtime endpoints,
  and the optional remote broker.
- [Build](BUILD.md) - Android repo sync, patch application, generic build, and
  Pixel 9a build commands.
- [Testing](TESTING.md) - repository checks, physical device smoke tests,
  assistant evals, and trajectory validation.
- [Capability Model](CAPABILITIES.md) - named capabilities, risk levels, and
  policy configuration.

## Device And Release Docs

- [Device Support](DEVICE_SUPPORT.md)
- [Device Matrix](devices/MATRIX.md)
- [Pixel 9a Notes](devices/tegu.md)
- [Pixel 9a Boot Chain](TEGU_BOOTCHAIN.md)
- [Google Mobile Services Notes](GMS.md)
- [Release Process](RELEASE_PROCESS.md)
- [0.0.1 Release Notes](releases/0.0.1.md)
- [Changelog](releases/CHANGELOG.md)

## Schemas

Machine-readable runtime contracts live in [../schemas](../schemas). They are
used by repository checks and validators for action requests, model tools,
screen context, audit events, trajectories, OTA feeds, and agent eval reports.

## Licensing

- [Licensing Notes](LICENSING.md)
- [Legal Index](legal/README.md)
- [Commercial Licensing](legal/COMMERCIAL.md)
- [Contribution Terms](../.github/CONTRIBUTING.md)
- [Security Policy](../.github/SECURITY.md)
