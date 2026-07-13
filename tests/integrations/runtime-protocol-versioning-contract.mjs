#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  RUNTIME_PROTOCOL_VERSION_RANGE,
  assertSupportedRuntimeProtocolVersion,
  isSupportedRuntimeProtocolVersion,
  loadCommands,
  runtimeProtocolInfo,
  validateCommandDeprecations,
} from "../../runtime/protocol/openphone-runtime-tools.mjs";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "openphone-protocol-versioning-"));

function writeManifest(manifest) {
  const file = path.join(tempDir, `manifest-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(file, JSON.stringify(manifest));
  return file;
}

try {
  // The published range is a well-formed inclusive integer range covering v1.
  assert.ok(Number.isInteger(RUNTIME_PROTOCOL_VERSION_RANGE.min_version));
  assert.ok(Number.isInteger(RUNTIME_PROTOCOL_VERSION_RANGE.max_version));
  assert.ok(
    RUNTIME_PROTOCOL_VERSION_RANGE.min_version <= RUNTIME_PROTOCOL_VERSION_RANGE.max_version,
  );
  assert.ok(isSupportedRuntimeProtocolVersion(1));

  // Range membership checks.
  assert.equal(isSupportedRuntimeProtocolVersion(1, { min_version: 1, max_version: 2 }), true);
  assert.equal(isSupportedRuntimeProtocolVersion(2, { min_version: 1, max_version: 2 }), true);
  assert.equal(isSupportedRuntimeProtocolVersion(3, { min_version: 1, max_version: 2 }), false);
  assert.equal(isSupportedRuntimeProtocolVersion(0, { min_version: 1, max_version: 2 }), false);
  assert.equal(isSupportedRuntimeProtocolVersion("1", { min_version: 1, max_version: 2 }), false);
  assert.equal(isSupportedRuntimeProtocolVersion(1.5, { min_version: 1, max_version: 2 }), false);
  assert.equal(
    isSupportedRuntimeProtocolVersion(undefined, { min_version: 1, max_version: 2 }),
    false,
  );

  assert.doesNotThrow(() => assertSupportedRuntimeProtocolVersion(1));
  assert.throws(
    () => assertSupportedRuntimeProtocolVersion(99),
    /unsupported runtime protocol version: 99/u,
  );

  // The handshake advertisement mirrors the supported range.
  const info = runtimeProtocolInfo();
  assert.equal(info.name, "openphone-runtime-protocol");
  assert.equal(info.min_version, RUNTIME_PROTOCOL_VERSION_RANGE.min_version);
  assert.equal(info.max_version, RUNTIME_PROTOCOL_VERSION_RANGE.max_version);

  // The real manifest loads under the default range.
  const realCommands = loadCommands();
  assert.ok(realCommands.length > 10);

  // No shipped command is deprecated yet.
  assert.ok(realCommands.every((command) => command.deprecated !== true));

  // A v1 manifest loads; an out-of-range version is rejected.
  const command = {
    name: "openphone.example.old",
    description: "example",
    input_schema: { type: "object" },
    output_schema: { type: "object" },
  };
  assert.ok(loadCommands(writeManifest({ version: 1, commands: [command] })));
  assert.throws(
    () => loadCommands(writeManifest({ version: 99, commands: [command] })),
    /supported version/u,
  );
  assert.throws(
    () => loadCommands(writeManifest({ version: 0, commands: [command] })),
    /supported version/u,
  );
  assert.throws(
    () => loadCommands(writeManifest({ version: 1 })),
    /commands\[\]/u,
  );

  // A wider caller-supplied range accepts newer manifest versions.
  assert.ok(loadCommands(
    writeManifest({ version: 2, commands: [command] }),
    { versionRange: { min_version: 1, max_version: 2 } },
  ));

  // Deprecation metadata: valid shapes are accepted.
  const supersededManifest = writeManifest({
    version: 1,
    commands: [
      { ...command, deprecated: true, superseded_by: "openphone.example.new" },
      { ...command, name: "openphone.example.new" },
    ],
  });
  const deprecatedCommands = loadCommands(supersededManifest);
  assert.equal(deprecatedCommands[0].deprecated, true);
  assert.equal(deprecatedCommands[0].superseded_by, "openphone.example.new");

  // superseded_by may reference an alias of another command.
  assert.ok(loadCommands(writeManifest({
    version: 1,
    commands: [
      { ...command, deprecated: true, superseded_by: "example.new" },
      { ...command, name: "openphone.example.new", aliases: ["example.new"] },
    ],
  })));

  // superseded_by must reference an existing command.
  assert.throws(
    () => validateCommandDeprecations([
      { ...command, deprecated: true, superseded_by: "openphone.example.missing" },
    ]),
    /superseded_by references unknown command/u,
  );

  // superseded_by requires deprecated=true.
  assert.throws(
    () => validateCommandDeprecations([
      { ...command, superseded_by: "openphone.example.new" },
      { ...command, name: "openphone.example.new" },
    ]),
    /superseded_by requires deprecated=true/u,
  );

  // superseded_by must not point at the command itself (or its aliases).
  assert.throws(
    () => validateCommandDeprecations([
      { ...command, deprecated: true, superseded_by: "openphone.example.old" },
    ]),
    /must reference another command/u,
  );

  // deprecated must be a boolean when present.
  assert.throws(
    () => validateCommandDeprecations([{ ...command, deprecated: "yes" }]),
    /deprecated must be a boolean/u,
  );

  // superseded_by must be a non-empty string when present.
  assert.throws(
    () => validateCommandDeprecations([{ ...command, deprecated: true, superseded_by: "" }]),
    /superseded_by must be a non-empty string/u,
  );

  // loadCommands enforces deprecation metadata too.
  assert.throws(
    () => loadCommands(writeManifest({
      version: 1,
      commands: [{ ...command, deprecated: true, superseded_by: "openphone.example.missing" }],
    })),
    /superseded_by references unknown command/u,
  );
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
