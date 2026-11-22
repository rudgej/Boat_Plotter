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
 *   notifications.seakeeper             {state, message}
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
    },

    stop: function () {
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
