const PORT = 9223;
const log = (...a) => console.log(...a);
setTimeout(() => { log('TIMEOUT'); process.exit(2); }, 40000);

async function main() {
  let page = null;
  for (let i = 0; i < 20; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const t = await r.json();
      page = t.find((x) => x.type === 'page');
      if (page) break;
    } catch (e) {}
    await new Promise((r) => setTimeout(r, 1000));
  }
  if (!page) { log('NO TARGET'); process.exit(3); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => setTimeout(r, 1200));
  if (ws.readyState !== 1) { log('ws not open', ws.readyState); process.exit(5); }
  let id = 1;
  const send = (m, p) => new Promise((res, rej) => {
    const mid = id++;
    const onm = (ev) => {
      const mm = JSON.parse(ev.data);
      if (mm.id === mid) { ws.removeEventListener('message', onm); mm.error ? rej(new Error(JSON.stringify(mm.error))) : res(mm.result); }
    };
    ws.addEventListener('message', onm);
    ws.send(JSON.stringify({ id: mid, method: m, params: p }));
  });
  const consoleMsgs = [];
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.method === 'Runtime.consoleAPICalled') {
      consoleMsgs.push(m.params.type + ': ' + m.params.args.map(a => a.value || a.description || '').join(' '));
    } else if (m.method === 'Log.entryAdded') {
      consoleMsgs.push('LOG[' + m.params.entry.level + ']: ' + m.params.entry.text);
    }
  });
  await send('Runtime.enable', {});
  await send('Log.enable', {});
  await send('Page.enable', {});

  log('page loaded, waiting...');
  await new Promise((r) => setTimeout(r, 6000));

  // find and click the play button
  const clicked = await send('Runtime.evaluate', {
    expression: `(()=>{const b=document.querySelector('[data-testid="control-button-playpause"], button[aria-label="Play"], button[aria-label="Pause"]'); if(b){b.click(); return 'clicked: '+b.getAttribute('aria-label');} return 'no play button found';})()`,
    returnByValue: true,
  });
  log('CLICK', clicked.result.value);

  await new Promise((r) => setTimeout(r, 8000));

  // check state: is there a pause button now?
  const state = await send('Runtime.evaluate', {
    expression: `(()=>{const p=document.querySelector('button[aria-label="Pause"]'); const t=document.querySelector('[data-testid="playback-position"], [data-testid="playback-progressbar"]'); return JSON.stringify({pauseBtn: !!p, hasProgress: !!t});})()`,
    returnByValue: true,
  });
  log('STATE', state.result.value);

  log('--- console (last 40) ---');
  consoleMsgs.slice(-40).forEach((m) => log(m));
  process.exit(0);
}
main().catch((e) => { log('ERR', e.message); process.exit(1); });
