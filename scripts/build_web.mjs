import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
execFileSync('moon', ['build', '--target', 'js', '--release', 'bridge'], { stdio: 'inherit' });
fs.copyFileSync('_build/js/release/build/bridge/bridge.js', 'web/engine.js');
fs.mkdirSync('web/licenses', { recursive: true });
fs.copyFileSync('LICENSE', 'web/licenses/MoonStretch-LICENSE');
fs.copyFileSync('LICENSE', 'web/licenses/LICENSE');
fs.copyFileSync('THIRD_PARTY.md', 'web/licenses/THIRD_PARTY.md');
for (const name of fs.readdirSync('licenses')) fs.copyFileSync(`licenses/${name}`, `web/licenses/${name}`);
// These files belong to the distributed engine. Missing attribution is a build
// failure, not an optional documentation warning.
for (const name of ['moonbit-core-LICENSE', 'moonbit-core-NOTICE', 'MoonWavKit-LICENSE']) {
  if (!fs.readFileSync(`licenses/${name}`).equals(fs.readFileSync(`web/licenses/${name}`)))
    throw new Error(`Distribution notice differs from source: ${name}`);
}
console.log('Built web/engine.js from the MoonBit DSP sources.');
