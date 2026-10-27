#!/usr/bin/env node
// demo/mcp/call-tool.mjs — zero-dependency example MCP client (spec 9.1).
//
// Sends ONE raw JSON-RPC sequence over stdio to a spawned MCP server
// subprocess — initialize -> initialized -> (tools/list) -> tools/call —
// prints the server's tool result as pretty JSON, and exits. No MCP SDK, no
// npm packages: this file exists so a user can see a real tool-call
// round-trip without installing Claude Desktop/Cursor first (the same
// "no local client needed, we give you the command" posture the demos
// already have). For a richer interactive explorer, the MCP inspector is
// optional: `npx @modelcontextprotocol/inspector demo/mcp/call-tool.sh`.
//
// The spawned server is the mcp/ C++17 implementation's own binary (spec
// 14.7: the demo owns no second server implementation — there is no
// mcp/src/server.js to import; the binary IS the server), restricted to the
// demo's four pinned tools exactly like call-tool.sh.
//
// Usage: node call-tool.mjs [--server <fractalsql-postgresql-mcp>] [--tools] <tool> '<json-args>'

import { spawn } from 'node:child_process';
import { accessSync, constants as FsConstants } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const PINS = 'fractal_search,fractal_reason,fractal_agent_data_analyst,fractal_agent_diverse_portfolios';

const args = process.argv.slice(2);
let serverPath = process.env.FSQL_MCP_SERVER || null;
let listOnly = false;
const rest = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--server') { serverPath = args[++i]; continue; }
  if (args[i] === '--tools') { listOnly = true; continue; }
  rest.push(args[i]);
}
if (!serverPath) {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const names = process.platform === 'win32'
    ? ['fractalsql-postgresql-mcp.exe', 'fractalsql-postgresql-mcp']
    : ['fractalsql-postgresql-mcp'];
  const candidates = [
    path.join(here, '..', '..', 'mcp', ...names),   // repo-tree layout
    '/work/mcp/' + names[0],                        // compose layout (mcp at /work/mcp)
  ];
  for (const c of candidates) {
    try { accessSync(c, FsConstants.X_OK); serverPath = c; break; } catch {}
  }
}
if (!serverPath) {
  console.error(
    'demo/mcp: the mcp/ C++ server binary was not found.\n' +
    'Locally: cd mcp && make   (needs pkg-config libpq/openssl)\n' +
    'Compose: the mcp service builds it on first start; or pass --server.'
  );
  process.exit(2);
}
const [tool, rawJson] = rest;
if (!listOnly && (!tool || !rawJson)) {
  console.error(`usage: call-tool.mjs [--server <mcp-binary>] [--tools] <tool> '{"arg": value}'`);
  process.exit(2);
}
let toolArgs = {};
try { toolArgs = rawJson ? JSON.parse(rawJson) : {}; } catch (e) {
  console.error(`call-tool: the JSON arguments do not parse: ${e.message}`);
  process.exit(2);
}

const server = spawn(serverPath, ['--tool', PINS], { stdio: ['pipe', 'pipe', 'inherit'] });
let id = 1;
function send(obj) {
  server.stdin.write(`${JSON.stringify(obj)}\n`);
}

let buffer = '';
server.stdout.setEncoding('utf8');
server.stdout.on('data', (chunk) => { buffer += chunk; });
const nextMessage = () => new Promise((resolve) => {
  const tick = () => {
    const idx = buffer.indexOf('\n');
    if (idx < 0) return false;
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) return tick();
    try { resolve(JSON.parse(line)); return true; } catch { return tick(); }
  };
  if (tick()) return;
  const onData = () => { if (buffer.indexOf('\n') >= 0) { server.stdout.off('data', onData); tick(); } };
  server.stdout.on('data', onData);
  process.stdout.on('error', () => {});
});

const call = async (id, method, params) => {
  send({ jsonrpc: '2.0', id, method, params });
  for (;;) {
    const msg = await nextMessage();
    if (msg && msg.id === id) {
      if (msg.error) { console.error(`MCP error (${msg.error.code}): ${msg.error.message}`); process.exit(1); }
      return msg.result;
    }
    // notifications pass through
  }
};

const init = await call(id++, 'initialize', {
  protocolVersion: '2025-06-18',
  capabilities: {},
  clientInfo: { name: 'fractalsql-demo-client', version: '1.0.0' },
});
send({ jsonrpc: '2.0', method: 'notifications/initialized' });

if (listOnly) {
  const list = await call(id++, 'tools/list', {});
  for (const t of list?.tools ?? []) console.error(`${t.name}\n  ${t.description}\n`);
  console.log(JSON.stringify(list?.tools ?? [], null, 2));
} else {
  const result = await call(id++, 'tools/call', { name: tool, arguments: toolArgs });
  if (result?.isError) {
    console.error('(tool call returned isError:true — the engine\'s own error, verbatim, as designed, spec 1.6)');
  }
  // structuredContent is the parsed JSON object/array (spec 1.5); fall back
  // to the text content for LLM-text answers.
  const payload = result?.structuredContent ?? result?.content?.[0]?.text ?? result;
  if (typeof payload === 'string') console.log(payload);
  else console.log(JSON.stringify(payload, null, 2));
}
server.kill('SIGTERM');
setTimeout(() => server.kill('SIGKILL'), 1000).unref?.();
void init;