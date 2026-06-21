'use strict';
// Persistent render sidecar for mdrender.nvim.
//
// Spawns and OWNS a chrome-headless-shell child and talks to it over the Chrome
// DevTools Protocol (Node's built-in WebSocket + fetch — no npm dependencies).
// Reads one JSON request per line on stdin, writes one JSON response per line on
// stdout, and keeps the page loaded between requests so it can capture just the
// *visible clip* of a (possibly very long) document cheaply.
//
// Owning chrome here (rather than letting Neovim spawn it) means chrome can't be
// orphaned: when Neovim exits — cleanly OR by crash — our stdin closes and we
// kill chrome and exit. We also clean up on SIGTERM/SIGINT and if chrome dies.
//
//   req:  {"html":"/abs/page.html","reload":true,"clipY":0,"clipH":680,
//          "width":760,"scale":2,"out":"/abs/out.png"}
//   resp: {"ok":true,"out":"...","docW":760,"docH":11914} | {"ok":false,"err":"..."}
//
// Emits "READY" on stderr once connected.  Env: MDR_CHROME = chrome binary path.
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawn } = require('child_process');

const CHROME = process.env.MDR_CHROME;
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mdr-chrome-'));

let chrome;
let ws;
let msgId = 0;
const pending = new Map();
let eventWaiters = [];
let down = false;

function cleanup(code) {
  if (down) return;
  down = true;
  try {
    if (chrome) chrome.kill('SIGKILL');
  } catch (_) {}
  try {
    fs.rmSync(profile, { recursive: true, force: true });
  } catch (_) {}
  process.exit(code || 0);
}

function send(method, params) {
  const id = ++msgId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params: params || {} }));
  });
}

function waitEvent(method, timeoutMs) {
  return new Promise((resolve) => {
    const w = { method, resolve };
    eventWaiters.push(w);
    if (timeoutMs) {
      setTimeout(() => {
        const i = eventWaiters.indexOf(w);
        if (i >= 0) {
          eventWaiters.splice(i, 1);
          resolve(null);
        }
      }, timeoutMs);
    }
  });
}

// Spawn chrome and resolve once it prints its DevTools websocket URL.
function startChrome() {
  return new Promise((resolve, reject) => {
    chrome = spawn(
      CHROME,
      [
        '--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
        '--allow-file-access-from-files', '--remote-allow-origins=*',
        '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank',
      ],
      { stdio: ['ignore', 'ignore', 'pipe'] }
    );
    chrome.on('error', reject);
    chrome.on('exit', () => cleanup(1));
    let buf = '';
    const to = setTimeout(() => reject(new Error('chrome start timeout')), 15000);
    chrome.stderr.on('data', (d) => {
      buf += d;
      // Only match once the whole line has arrived, so a chunk boundary in the
      // middle of the URL (e.g. mid-port) can't resolve a truncated URL.
      const m = buf.match(/ws:\/\/\S+(?=\s)/);
      if (m) {
        clearTimeout(to);
        resolve(m[0]);
      }
    });
  });
}

async function connect() {
  const browserWs = await startChrome();
  const port = new URL(browserWs).port;
  // Create a page target and connect to it (Page.* needs a page, not browser).
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new`, { method: 'PUT' })).json();
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });
  ws.addEventListener('close', () => cleanup(1));
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) p.reject(new Error(m.error.message));
      else p.resolve(m.result);
    } else if (m.method) {
      const still = [];
      for (const w of eventWaiters) {
        if (w.method === m.method) w.resolve(m.params);
        else still.push(w);
      }
      eventWaiters = still;
    }
  });
  await send('Page.enable');
}

async function handle(req) {
  if (req.reload) {
    await send('Emulation.setDeviceMetricsOverride', {
      width: req.width || 760,
      height: 1200,
      deviceScaleFactor: 1,
      mobile: false,
    });
    const loaded = waitEvent('Page.loadEventFired', 6000);
    await send('Page.navigate', { url: 'file://' + req.html });
    await loaded;
  }
  const metrics = await send('Page.getLayoutMetrics');
  const cs = metrics.cssContentSize || metrics.contentSize;
  const docW = Math.ceil(cs.width);
  const docH = Math.ceil(cs.height);
  const clip = {
    x: 0,
    y: Math.max(0, Math.min(req.clipY || 0, Math.max(0, docH - (req.clipH || docH)))),
    width: req.width || docW,
    height: req.clipH || docH,
    scale: req.scale || 1,
  };
  const shot = await send('Page.captureScreenshot', {
    format: 'png',
    captureBeyondViewport: true,
    clip: clip,
  });
  fs.writeFileSync(req.out, Buffer.from(shot.data, 'base64'));
  return { ok: true, out: req.out, docW: docW, docH: docH, clipY: clip.y };
}

process.on('SIGTERM', () => cleanup(0));
process.on('SIGINT', () => cleanup(0));

(async () => {
  await connect();
  process.stderr.write('READY\n');
  const rl = readline.createInterface({ input: process.stdin });
  // When Neovim exits (clean or crash), stdin closes — tear chrome down too.
  rl.on('close', () => cleanup(0));
  for await (const line of rl) {
    if (!line.trim()) continue;
    let req;
    try {
      req = JSON.parse(line);
    } catch (_) {
      continue;
    }
    try {
      process.stdout.write(JSON.stringify(await handle(req)) + '\n');
    } catch (e) {
      process.stdout.write(JSON.stringify({ ok: false, err: String((e && e.message) || e) }) + '\n');
    }
  }
})().catch((e) => {
  process.stderr.write('FATAL ' + e + '\n');
  cleanup(1);
});
