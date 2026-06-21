'use strict';
// Persistent render sidecar for mdrender.nvim.
//
// Connects to a warm chrome-headless-shell over the Chrome DevTools Protocol
// using Node's built-in WebSocket + fetch (Node 21+/22+; no npm dependencies).
// Reads one JSON request per line on stdin and writes one JSON response per
// line on stdout. It keeps the page loaded between requests so it can capture
// just the *visible clip* of a (possibly very long) document cheaply.
//
//   req:  {"html":"/abs/page.html","reload":true,"clipY":0,"clipH":680,
//          "width":760,"scale":2,"out":"/abs/out.png"}
//   resp: {"ok":true,"out":"...","docW":760,"docH":11914}
//        |{"ok":false,"err":"..."}
//
// Emits "READY" on stderr once connected.
const fs = require('fs');
const readline = require('readline');

const PORT = parseInt(process.env.MDR_CDP_PORT || '9222', 10);
let ws;
let msgId = 0;
const pending = new Map();
let eventWaiters = [];

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

async function connect() {
  // Reuse an existing page target if there is one, else create it.
  let target;
  try {
    const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    target = list.find((t) => t.type === 'page');
  } catch (_) {}
  if (!target) {
    const r = await fetch(`http://127.0.0.1:${PORT}/json/new`, { method: 'PUT' });
    target = await r.json();
  }
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', rej, { once: true });
  });
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
    // Lay the page out at exactly the requested width so the clip aligns and
    // the measured height is correct. Capture resolution is set via clip.scale.
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
  const scale = req.scale || 1;
  const clip = {
    x: 0,
    y: Math.max(0, Math.min(req.clipY || 0, Math.max(0, docH - (req.clipH || docH)))),
    width: req.width || docW,
    height: req.clipH || docH,
    scale: scale,
  };
  const shot = await send('Page.captureScreenshot', {
    format: 'png',
    captureBeyondViewport: true,
    clip: clip,
  });
  fs.writeFileSync(req.out, Buffer.from(shot.data, 'base64'));
  return { ok: true, out: req.out, docW: docW, docH: docH, clipY: clip.y };
}

(async () => {
  await connect();
  process.stderr.write('READY\n');
  const rl = readline.createInterface({ input: process.stdin });
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
  process.exit(1);
});
