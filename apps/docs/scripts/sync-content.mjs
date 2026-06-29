import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const appRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const repoRoot = join(appRoot, '..', '..');
const sourceRoot = join(repoRoot, 'docs');
const targetRoot = join(appRoot, 'content', 'docs');

const includedExtensions = new Set(['.md']);
const includedNames = new Set(['meta.json']);
const skippedDirectories = new Set(['local-temp']);

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

  const titleMatch = markdown.match(/^#\s+(.+)$/m);
  const title = titleMatch?.[1]?.replace(/\s*#+\s*$/, '').trim();
  const fallback = relative(sourceRoot, sourcePath)
    .replace(/\.md$/, '')
    .split('/')
    .at(-1);
  const body = titleMatch
    ? markdown.replace(/^#\s+.+\n+/, '')
    : markdown;

  return `---\ntitle: ${JSON.stringify(title || fallback || 'Untitled')}\n---\n\n${body}`;
}

await rm(targetRoot, { recursive: true, force: true });
await copyDocs(sourceRoot);
