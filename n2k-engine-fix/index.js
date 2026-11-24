'use strict'

/*
 * n2k-engine-fix - Signal K plugin
 *
 * Corrects two defects in Signal K's NMEA 2000 ingest path, both confirmed on
 * the boat 2026-11-24 against the raw CAN bus (see nmea2000-live-bus.md).
 *
 * Defect 1 - fuel pressure is 1000x too high.
 *
 *   PGN 127489 byte 17-18 is "Fuel Pressure" with a resolution of 1000 Pa.
 *   canboatjs decodes it correctly: raw 344 -> 344000 Pa (3.44 bar).
 *   Signal K's data model then publishes 344000000 Pa (3520 bar).
 *
 *   Only this field is affected. oilPressure and boostPressure both have a
 *   resolution of 100 and come through correctly, so the scaling is not a
 *   general problem and cannot be fixed by changing the PGN definition.
 *   Measured proof:
 *
 *     canboatjs  fuelPressure 344000        raw 344 x 1000   correct
 *     Signal K   propulsion.*.fuel.pressure 344000000        x1000 too big
 *
 * Defect 2 - "not available" becomes zero.
 *
 *   When the engine gateway has no value for a field it sends 0xFFFF (16-bit)
 *   or 0x7F (8-bit). canboatjs omits those fields entirely, but Signal K
 *   publishes them as 0. A real zero and "no sensor" then look identical
 *   downstream, which is how the bogus low-oil-pressure warning was raised
 *   while the engine was merely switched off.
 *
 *   Coolant pressure is the clearest case: the gateway never supplies it, yet
 *   propulsion.*.coolantPressure reads 0 forever.
 *
 * The plugin re-publishes corrected values under its own source label
 * (n2k-engine-fix). It reads deltas from app.signalk and ignores its own, so it
 * cannot feed back on itself.
 *
 * Reversible: disable the plugin in Signal K settings, or delete
 * ~/.signalk/plugin-config-data/n2k-engine-fix.json and restart.
 */

const PLUGIN_ID = 'n2k-engine-fix'

// Paths that need dividing. Anchored so nothing else matches.
const FUEL_PRESSURE = /^propulsion\.(?:port|starboard|main)\.fuel\.pressure$/

// Fields the gateway never supplies, which Signal K publishes as 0.
const ZERO_MEANS_ABSENT = [
  /^propulsion\.(?:port|starboard|main)\.coolant\.pressure$/
]

// Measured on the boat: Signal K's value is exactly 1000x canboatjs' value,
// and canboatjs' value is the correct one in pascals.
const FUEL_PRESSURE_DIVISOR = 1000

module.exports = function (app) {
  const lastEmitted = new Map()
  let corrected = 0

  function isOwnUpdate (update) {
    const src = update && update.$source
    return typeof src === 'string' && src.indexOf(PLUGIN_ID) === 0
  }

  function emit (values) {
    if (!values.length) return
    app.handleMessage(PLUGIN_ID, {
      updates: [{ $source: PLUGIN_ID, values: values }]
    })
    corrected += values.length
  }

  // Decide what a path should read, given what Signal K just published.
  // Returns { path, value } or null when nothing needs changing.
  function correctionFor (path, value) {
    if (FUEL_PRESSURE.test(path)) {
      if (typeof value !== 'number' || !isFinite(value)) return null
      // Two decimal places is well below the 3.4 bar -> 344 kPa resolution.
      return { path: path, value: Math.round((value / FUEL_PRESSURE_DIVISOR) * 100) / 100 }
    }

    for (const re of ZERO_MEANS_ABSENT) {
      if (!re.test(path)) continue
      if (typeof value !== 'number') return null
      // Zero from this gateway means "no sensor wired", never a real reading.
      // Publish null so dashboards show "--" instead of a believable 0.
      return { path: path, value: value === 0 ? null : value }
    }

    return null
  }

  function onDelta (delta) {
    if (!delta || !Array.isArray(delta.updates)) return

    const out = []
    delta.updates.forEach((update) => {
      if (isOwnUpdate(update)) return
      if (!Array.isArray(update.values)) return

      update.values.forEach((v) => {
        if (!v || typeof v.path !== 'string') return

        const fix = correctionFor(v.path, v.value)
        if (!fix) return

        // Fuel pressure must be re-published on EVERY incoming update, not only
        // when the value changes. Signal K's engine re-evaluates the preferred
        // source each time the N2K provider publishes, so a change-only plugin
        // loses the path back to the uncorrected value between changes.
        // Coolant pressure is a one-off null, so it keeps the change guard to
        // avoid 2 Hz of pointless deltas.
        if (FUEL_PRESSURE.test(fix.path)) {
          out.push(fix)
          lastEmitted.set(fix.path, fix.value)
          return
        }

        // Only publish on change. The incoming rate is 2 Hz per engine, and
        // repeating identical deltas just makes history noisy.
        if (lastEmitted.has(fix.path) && lastEmitted.get(fix.path) === fix.value) return

        lastEmitted.set(fix.path, fix.value)
        out.push(fix)
      })
    })

    emit(out)
  }

  const plugin = {
    id: PLUGIN_ID,
    name: 'N2K engine data fixes',
    description:
      'Divides propulsion.*.fuel.pressure by 1000 (Signal K scales it wrongly) and ' +
      'publishes coolant pressure as null rather than 0 when the gateway has no sensor.',

    schema: {
      type: 'object',
      properties: {
        fuelPressureDivisor: {
          type: 'number',
          title: 'Fuel pressure divisor',
          description:
            'Signal K publishes fuel pressure this many times too large. Measured on the ' +
            'boat 2026-11-24 as exactly 1000. Do not change without measuring again.',
          default: 1000
        }
      }
    },

    start: function (settings) {
      const cfg = (settings && settings.configuration) || {}
      const divisor = Number(cfg.fuelPressureDivisor) > 0
        ? Number(cfg.fuelPressureDivisor)
        : FUEL_PRESSURE_DIVISOR
      if (divisor !== FUEL_PRESSURE_DIVISOR) {
        app.setPluginError(
          `fuelPressureDivisor is ${divisor}, but the measured correction is ` +
          `${FUEL_PRESSURE_DIVISOR}. Values will be wrong.`
        )
      }

      lastEmitted.clear()
      corrected = 0

      app.signalk.on('delta', onDelta)
      app.setPluginStatus('watching engine deltas, fuel pressure divisor ' + divisor)
      app.debug('n2k-engine-fix started')

      // Deliberate breadcrumb. Signal K's own plugin-status endpoint needs auth,
      // so without this there is no way to tell from the outside whether the
      // plugin loaded at all. Visible at
      // /signalk/v1/api/vessels/self/notifications/n2kEngineFix/status
      app.handleMessage(PLUGIN_ID, {
        updates: [
          {
            $source: PLUGIN_ID,
            values: [
              {
                path: 'notifications.n2kEngineFix.status',
                value: {
                  state: 'normal',
                  message: 'n2k-engine-fix running, fuel pressure divided by ' + divisor
                }
              }
            ]
          }
        ]
      })
    },

    stop: function () {
      app.signalk.removeListener('delta', onDelta)
      app.setPluginStatus(`stopped after ${corrected} corrected values`)
    }
  }

  return plugin
}
