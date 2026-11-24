"use strict";

/*
 * seakeeper-signalk
 *
 * Bridges the SeaKeeper gyro into Signal K.
 *
 * The SeaKeeper speaks MQTT over WebSocket on port 9001 of its own address. We
 * hold exactly ONE MQTT connection and republish into Signal K once a second.
 * The gyro's own web page holds two of the four MQTT slots, so the budget is
 * page 2 + this plugin 1 = 3 of 4, leaving one spare for tools.
 *
 * The unit publishes status about 4 times a second; we deliberately sample it
 * down to 1 Hz because nothing downstream needs faster and a stored history at
 * 4 Hz would quadruple for no benefit.
 *
 * Paths published:
 *   navigation.attitude.roll            radians (SeaKeeper sends degrees)
 *   propulsion.gyro.powerEnabled        bool
 *   propulsion.gyro.stabilizeAvailable  bool  - the SHIP button may be pressed
 *   propulsion.gyro.stabilizeEnabled    bool
 *   propulsion.gyro.targetRpm           rpm   - flywheel_crt_selected_speed
 *   propulsion.gyro.rpm                 rpm   - flywheel_speed (actual)
 *   propulsion.gyro.sequence            string - what the sequence is doing
 *   notifications.seakeeper             {state, message}
 *
 * Commands (PUT propulsion.gyro.control):
 *   {"state":"on"}   low speed if cold, power, wait for ready, stabilise, full
 *   {"state":"off"}  stop stabilising, then power down
 *
 * Commands are published on the ONE connection this plugin already holds, so
 * driving the gyro costs no extra session. The PUT returns immediately - a cold
 * spin-up takes about 20 minutes - and progress is published as
 * propulsion.gyro.sequence.
 */

const PLUGIN_ID = 'seakeeper-signalk';

const DEFAULTS = {
  host: '192.168.0.2',
  port: 9001,
  instance: 1,
  rateHz: 1,
  staleSeconds: 10
};

/*
 * signalk-server ships its own copy of mqtt, so there is nothing to download if
 * we borrow it. Installing a second copy under ~/.signalk/node_modules works
 * too, and is preferred when present because it survives a signalk upgrade.
 */
function loadMqtt() {
  try {
    return require('mqtt');
  } catch (e) {
    /* fall through */
  }
  try {
    const { createRequire } = require('module');
    const fromServer = createRequire(
      '/usr/lib/node_modules/signalk-server/package.json'
    );
    return fromServer('mqtt');
  } catch (e) {
    return null;
  }
}

module.exports = function (app) {
  let client = null;
  let timer = null;
  let latest = { status: null, alarm: null };
  let lastMessageAt = 0;
  let lastState = '';

  function setState(state) {
    if (state === lastState) {
      return;
    }
    lastState = state;
    app.setPluginStatus(state);
  }

  function publish() {
    const cfg = app.__seakeeperCfg || DEFAULTS;
    const now = Date.now();

    // Never republish a value the unit has stopped sending: a frozen gauge on a
    // stabiliser is worse than an obvious gap.
    if (!lastMessageAt || now - lastMessageAt > cfg.staleSeconds * 1000) {
      setState(
        `no data from ${cfg.host} for ${cfg.staleSeconds}s - not publishing`
      );
      return;
    }

    const values = [];
    const s = latest.status;
    const a = latest.alarm;

    if (s) {
      // SeaKeeper reports roll in degrees; Signal K attitude is radians.
      if (typeof s.boat_roll_angle === 'number') {
        values.push({
          path: 'navigation.attitude.roll',
          value: (s.boat_roll_angle * Math.PI) / 180
        });
      }
      // Mixed types on purpose: these three arrive as 1/0 or true/false.
      values.push({
        path: 'propulsion.gyro.powerEnabled',
        value: !!s.power_enabled
      });
      values.push({
        path: 'propulsion.gyro.stabilizeAvailable',
        value: !!s.stabilize_available
      });
      values.push({
        path: 'propulsion.gyro.stabilizeEnabled',
        value: !!s.stabilize_enabled
      });
      if (typeof s.flywheel_crt_selected_speed === 'number') {
        values.push({
          path: 'propulsion.gyro.targetRpm',
          value: s.flywheel_crt_selected_speed
        });
      }
      if (typeof s.flywheel_speed === 'number') {
        values.push({ path: 'propulsion.gyro.rpm', value: s.flywheel_speed });
      }
      // The control path also carries a value, so a dashboard switch bound to
      // it shows whether the gyro is running rather than sitting blank. Toggling
      // it PUTs back to this same path.
      values.push({
        path: 'propulsion.gyro.control',
        value: !!s.stabilize_enabled
      });
    }

    if (a) {
      // The key really is misspelled in the unit's own payload.
      const list = Array.isArray(a.alarming_seekepers) ? a.alarming_seekepers : [];
      values.push({
        path: 'notifications.seakeeper',
        value: {
          state: list.length ? 'alarm' : 'normal',
          message: list.length
            ? `SeaKeeper alarm (${list.length})`
            : 'No active alarms'
        }
      });
    }

    if (!values.length) {
      setState('connected, waiting for the first status message');
      return;
    }

    app.handleMessage(PLUGIN_ID, {
      updates: [{ $source: PLUGIN_ID, values }]
    });

    const bits = values
      .filter((v) => v.path.startsWith('propulsion.gyro.'))
      .map((v) => `${v.path.split('.').pop()}=${v.value}`)
      .join(' ');
    setState(`live: ${bits}`);
  }

  function handleMessage(topic, payload) {
    let msg;
    try {
      msg = JSON.parse(payload.toString());
    } catch (e) {
      app.debug(`unparseable payload on ${topic}`);
      return;
    }
    lastMessageAt = Date.now();
    if (topic === `seakeeper/status/${app.__seakeeperCfg.instance}`) {
      latest.status = msg;
    } else if (topic === 'seakeeper/alarm') {
      latest.alarm = msg;
    }
  }

  // ---------------------------------------------------------------- sequence

  let sequence = 'idle';
  let sequenceRunning = false;
  let stopping = false;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // Mixed types by design: stabilize_available is a JSON boolean when false,
  // while the others are always numbers.
  const on = (v) => v === true || v === 1 || v === '1';

  function setSequence(state) {
    sequence = state;
    app.setPluginStatus(`sequence: ${state}`);
    app.handleMessage(PLUGIN_ID, {
      updates: [
        {
          $source: PLUGIN_ID,
          values: [{ path: 'propulsion.gyro.sequence', value: state }]
        }
      ]
    });
  }

  function send(payload) {
    const cfg = app.__seakeeperCfg || DEFAULTS;
    if (!client) {
      throw new Error('not connected to the unit');
    }
    const body = JSON.stringify(payload);
    app.debug(`publish ${body}`);
    client.publish(`seakeeper/request/${cfg.instance}`, body, { qos: 0 });
  }

  // Commands are QoS 0, so nothing is confirmed by publishing. Every step is
  // checked against the status stream instead. An alarm stops the sequence
  // before stabilise is ever published.
  async function waitFor(predicate, label, timeoutMs) {
    const started = Date.now();
    for (;;) {
      if (stopping) {
        throw new Error('plugin stopping');
      }
      const alarms = latest.alarm && latest.alarm.alarming_seekepers;
      if (Array.isArray(alarms) && alarms.length) {
        throw new Error(`alarm: ${JSON.stringify(alarms[0])}`);
      }
      if (predicate(latest.status)) {
        return;
      }
      if (Date.now() - started > timeoutMs) {
        throw new Error(`timeout waiting for ${label}`);
      }
      await sleep(500);
    }
  }

  async function spinUp() {
    const cfg = app.__seakeeperCfg || DEFAULTS;
    const s = latest.status || {};

    if (on(s.stabilize_enabled)) {
      // Already stabilising. Re-publishing stabilize is harmless - the unit
      // ignores it - but the useful action if it is still on the low target is
      // to ask for full speed. Returning early here used to leave a gyro that
      // was stabilising at 7600 sitting at 7600.
      if (s.flywheel_crt_selected_speed !== 0) {
        send({ flywheel_speed: 0 });
        setSequence('already-stabilising, full speed requested');
      } else {
        setSequence('already-stabilising');
      }
      return;
    }

    const rpm = typeof s.flywheel_speed === 'number' ? s.flywheel_speed : 0;
    const minTarget =
      typeof s.flywheel_min_speed === 'number' ? s.flywheel_min_speed : 7600;

    if (on(s.power_enabled)) {
      // Already spinning. Ask for the low target only if it is not already at or
      // above it: commanding 7600 at 8000 would drop the speed for no reason.
      // The unit copes either way, but there is nothing to gain from the dip.
      if (rpm < minTarget) {
        send({ flywheel_speed: 1 });
      }
      setSequence('already-running, waiting to be ready');
    } else {
      send({ flywheel_speed: 1 });
      send({ power: 1 });
      setSequence('spinning-up');
      await waitFor(
        (m) => m && on(m.power_enabled),
        'power on',
        30000
      );
      setSequence('waiting to be ready');
    }

    // The unit's own readiness signal - the SHIP button appearing. Not a speed
    // threshold and not a fixed delay.
    await waitFor(
      (m) => m && on(m.stabilize_available),
      'ready to stabilise',
      (cfg.readyTimeoutSeconds || 3600) * 1000
    );

    send({ stabilize: 1 });
    await waitFor(
      (m) => m && on(m.stabilize_enabled),
      'stabilising',
      30000
    );

    // Done as soon as the high-speed target is selected. There is no reason to
    // watch it reach 9700 - the unit does that on its own.
    send({ flywheel_speed: 0 });
    setSequence('done');
  }

  async function spinDown() {
    const s = latest.status || {};

    if (on(s.stabilize_enabled)) {
      send({ stabilize: 0 });
      await waitFor(
        (m) => m && !on(m.stabilize_enabled),
        'stabilise off',
        30000
      );
    }

    if (on(s.power_enabled)) {
      send({ power: 0 });
      // The flywheel coasts for a long time; waiting for it is not useful.
    }

    setSequence('off');
  }

  async function runSequence(action) {
    if (sequenceRunning) {
      return `already running (${sequence})`;
    }
    sequenceRunning = true;
    try {
      if (action === 'on') {
        await spinUp();
      } else {
        await spinDown();
      }
      return null;
    } catch (e) {
      setSequence(`failed: ${e.message}`);
      return e.message;
    } finally {
      sequenceRunning = false;
    }
  }

  // Accept whatever a dashboard switch sends. KIP, for one, wraps values as
  // {value: 1, units: ...} rather than sending a bare boolean, so guessing a
  // single shape would make the switch silently do nothing.
  function readAction(value) {
    if (value && typeof value === 'object') {
      if (typeof value.state === 'string') {
        return value.state.toLowerCase();
      }
      if (typeof value.on === 'boolean') {
        return value.on ? 'on' : 'off';
      }
      if (value.value !== undefined) {
        return readAction(value.value);
      }
    }
    if (typeof value === 'string') {
      return value.toLowerCase();
    }
    if (typeof value === 'boolean') {
      return value ? 'on' : 'off';
    }
    if (typeof value === 'number') {
      return value !== 0 ? 'on' : 'off';
    }
    return null;
  }

  const plugin = {
    id: PLUGIN_ID,
    name: 'SeaKeeper',
    description:
      'Publishes SeaKeeper gyro status into Signal K at 1 Hz, using one MQTT connection to the unit',

    schema: {
      type: 'object',
      properties: {
        host: {
          type: 'string',
          title: 'SeaKeeper address',
          description: 'Address the unit advertises on port 9001',
          default: DEFAULTS.host
        },
        port: { type: 'number', title: 'Port', default: DEFAULTS.port },
        instance: {
          type: 'number',
          title: 'Seakeeper instance',
          description: 'Used to build seakeeper/status/<instance>',
          default: DEFAULTS.instance
        },
        rateHz: {
          type: 'number',
          title: 'Publish rate (Hz)',
          description: '1 is plenty; the unit itself sends about 4 per second',
          default: DEFAULTS.rateHz
        },
        staleSeconds: {
          type: 'number',
          title: 'Stop publishing after (seconds of silence)',
          default: DEFAULTS.staleSeconds
        },
        readyTimeoutSeconds: {
          type: 'number',
          title: 'Give up waiting to become ready after (seconds)',
          description:
            'A cold unit takes about 20 minutes to report it can stabilise. ' +
            'The spin-up stops waiting after this and reports failure rather ' +
            'than engaging stabilisation on a unit that never became ready.',
          default: 3600
        }
      }
    },

    start: function (settings) {
      const cfg = Object.assign(
        {},
        DEFAULTS,
        (settings && settings.configuration) || {}
      );
      app.__seakeeperCfg = cfg;

      const mqtt = loadMqtt();
      if (!mqtt) {
        app.setPluginError(
          'mqtt module not found (install mqtt into the plugin directory)'
        );
        return;
      }

      const url = `ws://${cfg.host}:${cfg.port}/mqtt`;
      app.setPluginStatus(`connecting to ${url}`);

      client = mqtt.connect(url, {
        clientId: `${PLUGIN_ID}-${cfg.instance}`,
        protocolVersion: 4,
        clean: true,
        keepalive: 30,
        connectTimeout: 8000,
        reconnectPeriod: 5000
      });

      client.on('connect', () => {
        app.setPluginStatus(`connected to ${url}, subscribing`);
        client.subscribe(
          [`seakeeper/status/${cfg.instance}`, 'seakeeper/alarm'],
          { qos: 0 }
        );
      });

      client.on('message', handleMessage);

      client.on('error', (err) => {
        app.setPluginError(`mqtt: ${err.message}`);
      });

      client.on('close', () => {
        // Deliberately not an error: the unit reboots and the link drops. The
        // client reconnects on its own and the stale guard stops the data.
        setState('connection closed, retrying');
      });

      const period = Math.max(250, Math.round(1000 / (cfg.rateHz || 1)));
      timer = setInterval(publish, period);
      app.setPluginStatus(`starting, publishing at ${cfg.rateHz || 1} Hz`);

      // Publish the sequence state up front so the path always exists. Without
      // this a reader cannot tell "idle" from "path not implemented", and the
      // first thing an automation does is read it.
      setSequence('idle');

      // Commands go out on the connection this plugin already holds, so driving
      // the gyro costs no extra session. The PUT returns at once: a cold
      // spin-up takes about 20 minutes and no HTTP client waits that long.
      if (typeof app.registerPutHandler === 'function') {
        app.registerPutHandler(
          'vessels.self',
          'propulsion.gyro.control',
          // Signal K uses the handler's RETURN VALUE as the reply, and also
          // calls any callback it was handed - so returning undefined makes it
          // read .state off nothing and answer 500. Return the reply, and return
          // it immediately: the sequence runs in the background because a cold
          // spin-up takes twenty minutes and no HTTP client waits that long.
          (context, path, value) => {
            const action = readAction(value);
            if (action !== 'on' && action !== 'off') {
              return {
                state: 'COMPLETED',
                statusCode: 400,
                message: 'expected {"value":{"state":"on"}} or "off"'
              };
            }
            runSequence(action).then((err) => {
              if (err) {
                app.setPluginError(`sequence: ${err}`);
              }
            });
            return { state: 'COMPLETED', statusCode: 200 };
          },
          PLUGIN_ID
        );
      } else {
        app.setPluginError(
          'registerPutHandler is unavailable - too old a signalk-server'
        );
      }
    },

    stop: function () {
      stopping = true;
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
      if (client) {
        client.end(true);
        client = null;
      }
      lastState = '';
    }
  };

  return plugin;
};
