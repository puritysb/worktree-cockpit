#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const source = join(root, 'fm-helper', 'wtcp-fm-helper.swift');
const out = join(root, 'assets', 'fm-helper', 'wtcp-fm-helper');
const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
const target = `${arch}-apple-macos26.0`;

if (process.platform !== 'darwin') {
  console.log('[fm-helper] skipped: darwin only');
  process.exit(0);
}

mkdirSync(dirname(out), { recursive: true });
const swiftc = execFileSync('/usr/bin/xcrun', ['--find', 'swiftc'], { encoding: 'utf8' }).trim();
// swiftc is run directly (not via `xcrun swiftc`), so SDKROOT isn't set and the
// stdlib can't be found ("unable to load standard library for target ..."). Pass
// the SDK path explicitly so the build is reproducible from the npm lifecycle.
const sdk = execFileSync('/usr/bin/xcrun', ['--sdk', 'macosx', '--show-sdk-path'], { encoding: 'utf8' }).trim();
execFileSync(swiftc, ['-parse-as-library', '-sdk', sdk, '-target', target, source, '-o', out], { stdio: 'inherit' });
chmodSync(out, 0o755);
console.log(`[fm-helper] built ${out}`);
