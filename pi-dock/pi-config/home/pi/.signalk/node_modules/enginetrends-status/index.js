"use strict";

/*
 * enginetrends-status
 *
 * Signal K 2.x refuses a PUT to any path no provider has registered (the same
 * reason signalk-holding-tank-paths exists). The engine-trends daemon publishes
 * its per-engine readout under engineHealth.*, so those paths must be
 * registered here for the PUTs to be accepted.
 *
 * The daemon is the only writer. This plugin just accepts the value, emits it
 * with its own $source, and tells Signal K the PUT completed.
 */

const PLUGIN_ID = 'enginetrends-status';

// Keep these in step with engine-trends.py (PARAMS / PARAM_ORDER and
// ENGINE_KEYS). Configuration may override them.
const DEFAULT_ENGINES = ['port', 'starboard'];
const DEFAULT_PARAMS = [
  'rpm',
  'coolant',
  'oilTemp',
  'oilPressure',
  'boost',
  'fuel'
];

function buildPaths(engines, params) {
  const paths = [];
  engines.forEach((engine) => {
    paths.push(`engineHealth.${engine}.band`);
    paths.push(`engineHealth.${engine}.status`);
    paths.push(`engineHealth.${engine}.message`);
    params.forEach((param) => {
      const base = `engineHealth.${engine}.${param}`;
      paths.push(`${base}.current`);
      paths.push(`${base}.baseline`);
      paths.push(`${base}.baselineStatus`);
      paths.push(`${base}.baselineText`);
      paths.push(`${base}.currentText`);
      paths.push(`${base}.readout`);
    });
  });
  return paths;
}

module.exports = function (app) {
  const plugin = {
    id: PLUGIN_ID,
    name: 'Engine Trends Status',
    description:
      'Holds engineHealth.* readout values written by the engine-trends daemon',
    schema: {
      type: 'object',
      properties: {
        engines: {
          type: 'array',
          title: 'Engine keys (propulsion.<key>)',
          default: DEFAULT_ENGINES
        },
        params: {
          type: 'array',
          title: 'Parameters',
          default: DEFAULT_PARAMS
        }
      }
    },

    start: function (settings) {
      const cfg = (settings && settings.configuration) || {};
      const engines =
        Array.isArray(cfg.engines) && cfg.engines.length
          ? cfg.engines
          : DEFAULT_ENGINES;
      const params =
        Array.isArray(cfg.params) && cfg.params.length
          ? cfg.params
          : DEFAULT_PARAMS;

      const paths = buildPaths(engines, params);

      paths.forEach((p) => {
        app.registerPutHandler('vessels.self', p, (context, path, value, cb) => {
          app.handleMessage(PLUGIN_ID, {
            updates: [{ $source: PLUGIN_ID, values: [{ path, value }] }]
          });
          cb({ state: 'COMPLETED', statusCode: 200 });
          return { state: 'PENDING' };
        });
      });

      app.setPluginStatus(`engine-trends: ${paths.length} paths registered`);
    },

    stop: function () {}
  };

  return plugin;
};
