/**
 * fetch-params.ts
 *
 * Launcher for the SABR parameter fetcher. Delegates to the implementation in
 * lib-origin so both share the same YouTubeDL.resolve_sabr_url code path.
 *
 * Usage (set as SABR_FETCH_CMD for SabrLiveTests.swift):
 *
 *   SABR_FETCH_CMD="npx ts-node -r tsconfig-paths/register \
 *     --project /Users/illusion/dev/Illusi/lib-origin/tsconfig.json \
 *     /Users/illusion/dev/Illusi/lib-origin/tools/sabr-fetch-params.ts jNQXAC9IVRw" \
 *   swift test --filter SabrLiveTests
 *
 * Or run directly from lib-origin:
 *   cd /Users/illusion/dev/Illusi/lib-origin
 *   npx ts-node -r tsconfig-paths/register tools/sabr-fetch-params.ts [videoId]
 */

import { execFileSync } from 'child_process';
import path from 'path';

const LIB_ORIGIN = '/Users/illusion/dev/Illusi/lib-origin';
const SCRIPT = path.join(LIB_ORIGIN, 'tools', 'sabr-fetch-params.ts');
const VIDEO_ID = process.argv[2] ?? 'jNQXAC9IVRw';

const result = execFileSync(
  'npx',
  ['ts-node', '-r', 'tsconfig-paths/register', SCRIPT, VIDEO_ID],
  { cwd: LIB_ORIGIN, stdio: ['ignore', 'pipe', 'inherit'] }
);

process.stdout.write(result);
