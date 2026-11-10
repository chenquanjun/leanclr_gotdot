#!/usr/bin/env node
// 代码包本地 HTTP 源：静态服务 manifest.json 与程序集 DLL。
// 用法：node scripts/code_pkg_server.mjs --root out/packages [--port 18080] [--host 127.0.0.1]
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve } from 'node:path';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDir, '..');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) continue;
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) {
      out[key.slice(2)] = true;
    } else {
      out[key.slice(2)] = value;
      i += 1;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const serverRoot = resolve(args.root ?? join(root, 'out', 'packages'));
const port = Number(args.port ?? 18080);
const host = String(args.host ?? '127.0.0.1');

const contentTypes = {
  '.json': 'application/json; charset=utf-8',
  '.dll': 'application/octet-stream',
  '.pdb': 'application/octet-stream',
  '.bin': 'application/octet-stream',
};

if (!existsSync(serverRoot)) {
  console.error(`[code_pkg_server] 根目录不存在: ${serverRoot}`);
  process.exit(1);
}

const server = createServer((req, res) => {
  const urlPath = decodeURIComponent((req.url ?? '/').split('?')[0]);
  const relative = normalize(urlPath).replace(/^([/\\])+/, '');
  const target = resolve(serverRoot, relative);
  if (!target.startsWith(serverRoot)) {
    res.writeHead(403);
    res.end('forbidden');
    return;
  }
  if (!existsSync(target) || !statSync(target).isFile()) {
    console.log(`[code_pkg_server] 404 ${urlPath}`);
    res.writeHead(404);
    res.end('not found');
    return;
  }
  const type = contentTypes[extname(target).toLowerCase()] ?? 'application/octet-stream';
  const baseName = target.split(/[/\\]/).pop() ?? '';
  // CDN 语义：manifest 必须可刷新；内容哈希命名的 DLL 不可变，可长缓存。
  const cacheControl = baseName === 'manifest.json'
    ? 'no-cache, max-age=0, must-revalidate'
    : (extname(target).toLowerCase() === '.dll' ? 'public, max-age=31536000, immutable' : 'no-store');
  res.writeHead(200, {
    'Content-Type': type,
    'Content-Length': statSync(target).size,
    'Cache-Control': cacheControl,
  });
  console.log(`[code_pkg_server] 200 ${req.url} (${statSync(target).size} B, cache=${cacheControl})`);
  createReadStream(target).pipe(res);
});

server.listen(port, host, () => {
  console.log(`[code_pkg_server] listening http://${host}:${port}/ root=${serverRoot}`);
});

function shutdown() {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
