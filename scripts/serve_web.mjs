import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve('web');
const types = { '.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript', '.js': 'text/javascript', '.css': 'text/css', '.wav': 'audio/wav' };
const server = http.createServer((req, res) => {
  try {
    const name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const target = path.resolve(root, '.' + (name === '/' ? '/index.html' : name));
    if (!target.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
    if (!fs.statSync(target).isFile()) { res.writeHead(404).end(); return; }
    res.setHeader('Content-Type', types[path.extname(target)] || 'application/octet-stream');
    fs.createReadStream(target).pipe(res);
  } catch { res.writeHead(404).end(); }
});
server.listen(8765, '127.0.0.1', () => console.log('MoonStretch: http://127.0.0.1:8765'));
