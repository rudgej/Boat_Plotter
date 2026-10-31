// Inject KIP localStorage into the kiosk Chromium profile via CDP.
import { readFileSync } from 'node:fs';

const PORT = 9222;
const TARGET_URL = 'http://localhost:3000/@mxtommy/kip/';
const config = JSON.parse(readFileSync('/home/pi/kip-config.json', 'utf8'));

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
setTimeout(() => { log('TIMEOUT'); process.exit(2); }, 45000);

async function main() {
  let page = null;
  for (let i = 0; i < 20; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const targets = await res.json();
      page = targets.find((t) => t.type === 'page');
      if (page) break;
    } catch (e) { log('wait', i); }
    await new Promise((r) => setTimeout(r, 1000));
  }
  if (!page) { log('NO TARGET'); process.exit(3); }
  log('target', page.webSocketDebuggerUrl);

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  ws.onerror = (e) => { log('ws error', e && e.message ? e.message : String(e)); process.exit(4); };
  await new Promise((r) => setTimeout(r, 1200));
  if (ws.readyState !== 1) { log('ws not open, state', ws.readyState); process.exit(5); }
  log('ws open');

  let id = 1;
  const send = (method, params) => new Promise((resolve, reject) => {
    const mid = id++;
    const onmsg = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === mid) {
        ws.removeEventListener('message', onmsg);
        m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
      }
    };
    ws.addEventListener('message', onmsg);
    ws.send(JSON.stringify({ id: mid, method, params }));
  });

  // page is already loaded at TARGET_URL (chromium launched with it)
  await new Promise((r) => setTimeout(r, 6000));

  const expr = Object.entries(config)
    .map(([k, v]) => `localStorage.setItem(${JSON.stringify(k)}, ${JSON.stringify(JSON.stringify(v))})`)
    .join(';');
  log('setting localStorage');
  await send('Runtime.evaluate', { expression: expr, returnByValue: true });
  log('set ok');

  const check = await send('Runtime.evaluate', {
    expression: `JSON.stringify({app: !!localStorage.getItem('appConfig'), dash: !!localStorage.getItem('dashboardsConfig'), conn: localStorage.getItem('connectionConfig')})`,
    returnByValue: true,
  });
  log('verify', check.result.value);

  await send('Page.reload');
  await new Promise((r) => setTimeout(r, 3000));
  log('DONE');
  process.exit(0);
}
main().catch((e) => { log('ERR', e.message); process.exit(1); });
