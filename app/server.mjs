import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const appRoot = fileURLToPath(new URL('./', import.meta.url));
const config = await readFile(path.join(root, 'supabase/config.toml'), 'utf8');
if (!/^project_id = "project_saas_local"$/m.test(config)) throw new Error('Unexpected local project');
const cli = path.join(root, 'node_modules/supabase/dist/supabase.js');
const statusResult = spawnSync(process.execPath, [cli, 'status', '--output', 'json'], {
  cwd: root, encoding: 'utf8', timeout: 20000, windowsHide: true,
});
if (statusResult.status !== 0) throw new Error('Start Supabase Local first: npm run local:start');
const status = JSON.parse(statusResult.stdout);
if (status.API_URL !== 'http://127.0.0.1:54321' || !status.ANON_KEY) {
  throw new Error('The app only accepts the project_saas_local API at 127.0.0.1:54321');
}

const files = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/projects.mjs', ['projects.mjs', 'text/javascript; charset=utf-8']],
  ['/leads.mjs', ['leads.mjs', 'text/javascript; charset=utf-8']],
  ['/managed-options.mjs', ['managed-options.mjs', 'text/javascript; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/style.css', ['style.css', 'text/css; charset=utf-8']],
  ['/lead-detail.css', ['lead-detail.css', 'text/css; charset=utf-8']],
  ['/fonts.css', ['fonts.css', 'text/css; charset=utf-8']],
]);
const fontRoot = path.join(root, 'node_modules/@fontsource-variable/inter/files');
const fontNames = new Set([
  'inter-latin-wght-normal.woff2',
  'inter-latin-ext-wght-normal.woff2',
  'inter-vietnamese-wght-normal.woff2',
]);
const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Content-Security-Policy', "default-src 'self'; connect-src 'self' http://127.0.0.1:54321; style-src 'self'; script-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'");
  if (pathname === '/config') {
    response.setHeader('Content-Type', 'application/json; charset=utf-8');
    response.end(JSON.stringify({ apiUrl: status.API_URL, anonKey: status.ANON_KEY }));
    return;
  }
  const fontName = pathname.startsWith('/fonts/') ? pathname.slice('/fonts/'.length) : null;
  const entry = files.get(pathname);
  if (!entry && !fontNames.has(fontName)) { response.writeHead(404); response.end('Not found'); return; }
  try {
    const body = await readFile(fontName ? path.join(fontRoot, fontName) : path.join(appRoot, entry[0]));
    response.setHeader('Content-Type', fontName ? 'font/woff2' : entry[1]);
    response.end(body);
  } catch { response.writeHead(500); response.end('Cannot load app'); }
});
const port = Number(process.env.PROJECT_APP_PORT || 4173);
server.listen(port, '127.0.0.1', () => console.log(`Project app: http://127.0.0.1:${port}`));
