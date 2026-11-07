const PORT = 9223;
const log = (...a) => console.log(...a);
setTimeout(() => { log('TIMEOUT'); process.exit(2); }, 30000);

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

  const expr = `(async()=>{try{const c=await navigator.requestMediaKeySystemAccess('com.widevine.alpha',[{initDataTypes:['cenc'],audioCapabilities:[{contentType:'audio/mp4;codecs="mp4a.40.2"'}],videoCapabilities:[{contentType:'video/mp4;codecs="avc1.42E01E"'}],distinctiveIdentifier:'optional',persistentState:'optional'}]);return 'EME OK: '+c.keySystem;}catch(e){return 'EME FAIL: '+e.name+' :: '+e.message;}})()`;
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  log('RESULT', r.result.value);
  process.exit(0);
}
main().catch((e) => { log('ERR', e.message); process.exit(1); });
