#!/usr/bin/env node
// 通过本地 godot-mcp（stdio）运行一个 Godot 场景，等待进程自行退出后保存输出。
// 用法：node scripts/mcp_run_scene.mjs --project <godot_project> --scene res://x.tscn --log <输出日志>
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDir, '..');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) {
      continue;
    }
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

function fail(message) {
  console.error(`[mcp_run_scene] ${message}`);
  process.exit(1);
}

const args = parseArgs(process.argv.slice(2));
const project = resolve(args.project ?? join(root, 'godot_project'));
const scene = args.scene ?? 'res://hotreload_c_test.tscn';
const logPath = resolve(args.log ?? join(root, 'out', 'logs', 'godot_mcp_scene.log'));
const rawLog = resolve(args['raw-log'] ?? join(root, 'out', 'logs', 'godot_mcp_scene_raw.log'));
// Godot 路径：--godot > GODOT_BIN > 仓库内 .tools/godot45；都找不到时报错（见 docs/04 §8）。
const godotPath = resolve(
  args.godot ?? process.env.GODOT_BIN ?? join(root, '.tools', 'godot45', 'Godot_v4.5-stable_win64_console.exe'),
);
const quitAfter = String(args['quit-after'] ?? '200');
const timeoutMs = Number(args.timeout ?? 120) * 1000;
const serverPath = join(root, '.tools', 'godot-mcp', 'build', 'index.js');
const sdkDir = join(root, '.tools', 'godot-mcp', 'node_modules', '@modelcontextprotocol', 'sdk', 'dist');

for (const [label, path] of [
  ['godot-mcp 服务', serverPath],
  ['godot-mcp SDK', sdkDir],
  ['Godot 可执行文件', godotPath],
  ['Godot 工程', join(project, 'project.godot')],
]) {
  if (!existsSync(path)) {
    fail(`缺少${label}: ${path}（安装方式见 docs/04 §8；Godot 可用 --godot 或 GODOT_BIN 指定）`);
  }
}

mkdirSync(dirname(logPath), { recursive: true });
mkdirSync(dirname(rawLog), { recursive: true });

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function extractText(result) {
  const item = result?.content?.find((entry) => entry.type === 'text');
  return item?.text ?? '';
}

const { Client } = await import(pathToFileURL(join(sdkDir, 'client', 'index.js')).href);
const { StdioClientTransport } = await import(pathToFileURL(join(sdkDir, 'client', 'stdio.js')).href);

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [serverPath],
  env: {
    ...globalThis.process.env,
    GODOT_PATH: godotPath,
    GODOT_MCP_HEADLESS: '1',
    GODOT_MCP_NO_DEBUG: '1',
    GODOT_MCP_LOG_FILE: rawLog,
    GODOT_MCP_QUIT_AFTER: quitAfter,
  },
  stderr: 'inherit',
});
const client = new Client({ name: 'leanclr-hotreload-runner', version: '1.0.0' }, { capabilities: {} });

let output = [];
let errors = [];
let exited = false;

try {
  await client.connect(transport);
  console.log(`[mcp_run_scene] run_project scene=${scene}`);
  await client.callTool({ name: 'run_project', arguments: { projectPath: project, scene } });

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(500);
    let result;
    try {
      result = await client.callTool({ name: 'get_debug_output', arguments: {} });
    } catch {
      continue;
    }
    if (result?.isError) {
      continue;
    }
    let payload;
    try {
      payload = JSON.parse(extractText(result));
    } catch {
      continue;
    }
    output = payload.output ?? [];
    errors = payload.errors ?? [];
    if (payload.exited) {
      exited = true;
      break;
    }
  }

  if (!exited) {
    console.log('[mcp_run_scene] 超时，停止 Godot');
    try {
      const result = await client.callTool({ name: 'stop_project', arguments: {} });
      const payload = JSON.parse(extractText(result));
      output = payload.finalOutput ?? output;
      errors = payload.finalErrors ?? errors;
    } catch {
      // 进程可能已退出，忽略停止失败。
    }
  }
} catch (error) {
  console.error(`[mcp_run_scene] 失败: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
} finally {
  await client.close().catch(() => {});
}

const clean = [];
for (const line of [...output, ...errors]) {
  const text = String(line).replace(/\r$/, '');
  if (text.trim().length > 0) {
    clean.push(text);
  }
}
writeFileSync(logPath, `${clean.join('\n')}\n`, 'utf8');
console.log(`[mcp_run_scene] exited=${exited} lines=${clean.length} log=${logPath}`);

if (!exited) {
  process.exitCode = 1;
}
