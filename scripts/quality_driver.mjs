import fs from 'node:fs';
import { run } from '../_build/js/release/build/bridge/bridge.js';

try {
  const response = JSON.parse(run(fs.readFileSync(0, 'utf8')));
  if (response.error) throw new Error(response.error);
  process.stdout.write(JSON.stringify(response));
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
