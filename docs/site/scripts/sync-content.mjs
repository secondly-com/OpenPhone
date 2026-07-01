import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const appRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = join(appRoot, '..', '..');
const sourceRoot = join(repoRoot, 'docs');
const targetRoot = join(appRoot, 'content', 'docs');

const includedExtensions = new Set(['.md']);
const includedNames = new Set(['meta.json']);
const skippedDirectories = new Set(['local-temp', 'site']);
const skippedFiles = new Set(['LOCAL_AGENT_NOTES.md', 'README.md']);

const titleOverrides = {
  'index.md': 'OpenPhone',
  'quickstart.md': 'Quickstart',
  'BUILD.md': 'Build',
  'EMULATOR.md': 'Emulator',
  'ARCHITECTURE.md': 'Architecture',
  'CAPABILITIES.md': 'Capabilities',
  'AGENT_RUNTIME_V1.md': 'Agent Runtime',
  'AI_FIRST_ENGINEERING.md': 'AI-First Engineering',
  'DEVICE_SUPPORT.md': 'Device Support',
  'TEGU_BOOTCHAIN.md': 'Pixel 9a Boot Chain',
  'GMS.md': 'Google Mobile Services',
  'TESTING.md': 'Testing',
  'RELEASE_PROCESS.md': 'Release Process',
  'LICENSING.md': 'Licensing',
  'contribution-guide.md': 'Contributing',
  'devices/MATRIX.md': 'Device Matrix',
  'devices/tegu.md': 'Pixel 9a (tegu)',
  'devices/index.md': 'Devices',
  'legal/index.md': 'Legal',
  'legal/COMMERCIAL.md': 'Commercial Licensing',
  'legal/THIRD_PARTY_NOTICES.md': 'Third-Party Notices',
  'releases/index.md': 'Releases',
  'releases/history.md': 'Release History',
  'releases/0.0.1.md': 'v0.0.1 Release Notes',
  'runtime/runtime-agent-protocol.md': 'Runtime Agent Protocol',
  'runtime/security-model.md': 'Runtime Security Model',
  'runtime/mcp-bridge.md': 'MCP Bridge',
  'runtime/openclaw-integration.md': 'OpenClaw Integration',
  'runtime/hermes-integration.md': 'Hermes Integration',
};

async function copyDocs(sourceDir) {
  const entries = await readdir(sourceDir, { withFileTypes: true });

  for (const entry of entries) {
    const sourcePath = join(sourceDir, entry.name);
    const targetPath = join(targetRoot, relative(sourceRoot, sourcePath));

    if (entry.isDirectory()) {
      if (skippedDirectories.has(entry.name)) continue;
      await copyDocs(sourcePath);
      continue;
    }

    if (!entry.isFile()) continue;
    if (skippedFiles.has(entry.name)) continue;
    if (!includedNames.has(entry.name) && !includedExtensions.has(extname(entry.name))) continue;

    await mkdir(dirname(targetPath), { recursive: true });

    if (extname(entry.name) === '.md') {
      await writeFile(targetPath, await withFrontmatter(sourcePath));
    } else {
      await cp(sourcePath, targetPath);
    }
  }
}

async function withFrontmatter(sourcePath) {
  const markdown = await readFile(sourcePath, 'utf8');
  if (markdown.startsWith('---\n')) return markdown;

  const relPath = relative(sourceRoot, sourcePath);
  const titleMatch = markdown.match(/^#\s+(.+)$/m);
  const override = titleOverrides[relPath];
  const fromHeading = titleMatch?.[1]?.replace(/\s*#+\s*$/, '').trim();
  const fallback = relPath.replace(/\.md$/, '').split('/').at(-1);
  const title = override || fromHeading || fallback || 'Untitled';
  const body = titleMatch
    ? markdown.replace(/^#\s+.+\n+/, '')
    : markdown;

  return `---\ntitle: ${JSON.stringify(title)}\n---\n\n${body}`;
}

await rm(targetRoot, { recursive: true, force: true });
await copyDocs(sourceRoot);
