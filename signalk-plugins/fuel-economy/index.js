/**
 * signalk-fuel-economy
 *
 * Computes litres per nautical mile over a rolling 30 s window:
 *
 *   L/NM = (port fuel rate + starboard fuel rate, averaged over 30 s, in L/h)
 *          / (SOG averaged over 30 s, in kn)
 *
 * Publishes the result to:
 *   propulsion.main.fuel.economy      (a plain number, L/NM)
 *
 * Suppressed below ~1 kn SOG so the number doesn't blow up to infinity at idle.
 * Ships with the Signal K server, configured/enabled like any other plugin.
 */
module.exports = function (app) {
  const plugin = {};

  plugin.id = 'fuel-economy';
  plugin.name = 'Fuel Economy (L/NM)';
  plugin.description =
    'Rolling 30 s litres-per-nautical-mile = (port+starboard fuel rate) / SOG';

  const WINDOW_MS = 30000;
  const MIN_SOG_MS = 0.5;      // ~1 kn — below this, don't publish
  const OUTPUT_PATH = 'propulsion.main.fuel.economy';
  const MS_TO_KNOTS = 1.9438445;
  const M3S_TO_LPH = 3.6e6;    // m^3/s -> L/h

  const fuelBuf = [];           // {t, v} total fuel rate in L/h
  const sogBuf = [];            // {t, v} SOG in m/s
  const unsubscribes = [];
  let emitTimer = null;

  function prune(buf, now) {
    while (buf.length && now - buf[0].t > WINDOW_MS) buf.shift();
  }

  function mean(buf) {
    if (!buf.length) return null;
    let sum = 0;
    for (const x of buf) sum += x.v;
    return sum / buf.length;
  }

  function totalFuelLph() {
    let lph = 0;
    let ok = false;
    for (const side of ['port', 'starboard']) {
      const v = app.getSelfPath('propulsion.' + side + '.fuel.rate.value');
      if (typeof v === 'number') {
        lph += v * M3S_TO_LPH;
        ok = true;
      }
    }
    return ok ? lph : null;
  }

  function recompute() {
    const now = Date.now();
    prune(fuelBuf, now);
    prune(sogBuf, now);
    const avgFuel = mean(fuelBuf);
    const avgSog = mean(sogBuf);
    if (avgFuel == null || avgSog == null || avgSog < MIN_SOG_MS) return;

    const lnm = avgFuel / (avgSog * MS_TO_KNOTS);
    app.handleMessage(plugin.id, {
      context: 'vessels.' + app.selfId,
      updates: [{
        values: [{ path: OUTPUT_PATH, value: Math.round(lnm * 100) / 100 }]
      }]
    });
  }

  plugin.schema = {}

  plugin.start = function () {
    const now = Date.now();
    const f0 = totalFuelLph();
    if (f0 != null) fuelBuf.push({ t: now, v: f0 });
    const s0 = app.getSelfPath('navigation.speedOverGround.value');
    if (typeof s0 === 'number') sogBuf.push({ t: now, v: s0 });

    for (const key of ['propulsion.port.fuel.rate', 'propulsion.starboard.fuel.rate']) {
      unsubscribes.push(app.streambundle.getSelfStream(key).onValue(() => {
        const lph = totalFuelLph();
        if (lph != null) fuelBuf.push({ t: Date.now(), v: lph });
        recompute();
      }));
    }

    unsubscribes.push(
      app.streambundle.getSelfStream('navigation.speedOverGround').onValue((p) => {
        const v = p && typeof p === 'object' ? p.value : p;
        if (typeof v === 'number') sogBuf.push({ t: Date.now(), v: v });
        recompute();
      })
    );

    // keep the value fresh even in steady conditions
    emitTimer = setInterval(recompute, 1000);
  };

  plugin.stop = function () {
    if (emitTimer) clearInterval(emitTimer);
    emitTimer = null;
    unsubscribes.forEach((f) => f());
    unsubscribes.length = 0;
  };

  return plugin;
};
