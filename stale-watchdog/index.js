'use strict'

/*
 * stale-watchdog - Signal K plugin
 *
 * Signal K has no concept of data expiry: it keeps the last value forever and
 * never marks it stale, so a dead GPS keeps showing its final speed. This
 * plugin watches the age of the last update for a set of feeds and raises a
 * notification when one goes quiet.
 *
 * Design notes:
 *
 *  - Staleness is measured by AGE OF LAST UPDATE, never by whether the value
 *    changed. Depth legitimately sits rock-steady for minutes at anchor, and a
 *    simulator may repeat a canned number at 5 Hz - both are alive. Only
 *    silence is stale.
 *
 *  - Timeouts are generous multiples of the real transmit rate (engine 20 Hz,
 *    GPS 5 Hz, depth/wind 1-3 Hz). A 2 second threshold would false-alarm on a
 *    single dropped frame; 15-20 s means ~15+ missed frames, which is
 *    unambiguous.
 *
 *  - A group is only armed once it has actually delivered data, so booting the
 *    server does not produce a wall of alerts for feeds that have not started
 *    yet. If a feed never arrives at all, that is reported after a grace
 *    period instead.
 *
 *  - Scope is deliberately narrow. A frozen depth reading is a grounding risk;
 *    a frozen wind reading is an inconvenience. Feeds whose silence is normal
 *    (engine off, empty battery bank) are not watched at all, because an alarm
 *    that fires during ordinary operation trains the crew to ignore alarms.
 */

const PLUGIN_ID = 'stale-watchdog'
const TICK_MS = 2000

// Last-seen times are persisted so the watchdog survives a Signal K restart.
// This matters because the failure it watches for - a lost CAN or serial feed -
// is exactly what makes signalk-server throw ERR_SOCKET_DGRAM_NOT_RUNNING and
// get restarted by systemd. Without persistence the watchdog wakes up with no
// history, decides nothing is wrong, and stays quiet through the outage.
const fs = require('fs')
const os = require('os')
const path = require('path')

const STATE_FILE = path.join(
  process.env.HOME || os.homedir(),
  '.signalk',
  'stale-watchdog-state.json'
)
const STATE_MAX_AGE_MS = 60 * 60 * 1000   // ignore state older than an hour
/*
 * Timeouts are set from measured intervals on the boat (tools/measure-rates.py,
 * 2026-11-19):
 *
 *   depth        1.07 s median, 1.12 s max   ->  6 s = ~6 missed transmissions
 *   position     0.27 s median, 0.29 s max   ->  3 s = ~11 missed
 *   speed/course 0.27 s median, 0.30 s max   ->  4 s = ~13 missed
 *   wind         0.54 s median, 4.01 s MAX   -> 10 s = room for the long gaps
 *
 * Wind is the only feed with irregular timing: its normal rate is ~2 Hz but it
 * stalls for up to 4 s, so anything near 6 s would flap. Depth is only 1 Hz, so
 * a very short timeout would be exhausted by a couple of dropped transmissions.
 */
const GROUPS = [
  {
    id: 'depth',
    label: 'Depth',
    // Safety-critical: the only feed where a frozen number can put the boat on
    // the rocks. Loudest state, and the value is blanked rather than left
    // showing a lie.
    state: 'alarm',
    timeout: 6,
    alsoNull: true,
    paths: ['environment.depth.belowTransducer']
  },
  {
    id: 'position',
    label: 'Position',
    // Split out from the rest of navigation so it can be tighter: a frozen
    // position is worse than a frozen course readout.
    state: 'warn',
    timeout: 3,
    alsoNull: false,
    paths: ['navigation.position']
  },
  {
    id: 'navigation',
    label: 'Navigation (speed/course/heading)',
    state: 'warn',
    timeout: 4,
    alsoNull: false,
    paths: [
      'navigation.speedOverGround',
      'navigation.courseOverGroundTrue',
      'navigation.headingTrue'
    ]
  },
  {
    id: 'wind',
    label: 'Wind',
    // The wind sensor is bursty: measured at the Signal K websocket it delivers
    // only ~25 datagrams a minute in bursts, with gaps up to 10.5 s (the
    // sender's own activity light blinks, pauses, resumes). 25 s means a real
    // failure is still caught, but a normal pause is not reported.
    state: 'warn',
    timeout: 25,
    alsoNull: false,
    paths: [
      'environment.wind.angleApparent',
      'environment.wind.speedApparent'
    ]
  }
]

// Deliberately NOT watched: engine, electrical. An engine that is switched off
// stops transmitting, and that is normal rather than a fault - alarming on it
// would train the crew to ignore the alarm.

module.exports = function (app) {
  const seen = new Map()      // path -> ms of last update
  const values = new Map()    // path -> last value (for activeWhen gating)
  const alerted = new Map()   // groupId -> { since, reason }
  let startedAt = Date.now()
  let timer = null
  let cfg = {}
  let ticks = 0

  function loadState() {
    try {
      const raw = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))
      const now = Date.now()
      Object.keys(raw).forEach((p) => {
        const t = Number(raw[p])
        if (Number.isFinite(t) && now - t < STATE_MAX_AGE_MS) seen.set(p, t)
      })
      if (seen.size) {
        app.debug(`stale-watchdog restored ${seen.size} last-seen times`)
      }
    } catch (e) {
      // No state file on first run, or it is unreadable: start clean.
    }
  }

  function saveState() {
    try {
      const obj = {}
      seen.forEach((t, p) => {
        obj[p] = t
      })
      fs.writeFileSync(STATE_FILE, JSON.stringify(obj))
    } catch (e) {
      app.debug(`stale-watchdog could not save state: ${e.message}`)
    }
  }

  function publishNotification(group, value) {
    app.handleMessage(PLUGIN_ID, {
      updates: [
        {
          $source: PLUGIN_ID,
          values: [
            { path: `notifications.stalewatchdog.${group.id}`, value }
          ]
        }
      ]
    })
  }

  function clearValue(group) {
    app.handleMessage(PLUGIN_ID, {
      updates: [
        {
          $source: PLUGIN_ID,
          values: group.paths.map((p) => ({ path: p, value: null }))
        }
      ]
    })
  }

  function raise(group, reason, ageMs) {
    const previous = alerted.get(group.id)
    if (previous && previous.reason === reason) return
    alerted.set(group.id, { since: Date.now(), reason })
    const secs = Math.round(ageMs / 1000)
    publishNotification(group, {
      state: group.state || 'alert',
      method: group.state === 'alarm' ? ['visual', 'sound'] : ['visual'],
      message:
        reason === 'never'
          ? `${group.label}: no data received since Signal K started`
          : `${group.label} data stale for ${secs} s - do not rely on this reading`
    })
    if (group.alsoNull) clearValue(group)
  }

  function cancel(group) {
    if (!alerted.has(group.id)) return
    alerted.delete(group.id)
    publishNotification(group, {
      state: 'normal',
      method: [],
      message: `${group.label} data restored`
    })
  }

  function onDelta(delta) {
    if (!delta || !Array.isArray(delta.updates)) return
    const now = Date.now()
    delta.updates.forEach((update) => {
      if (!Array.isArray(update.values)) return
      update.values.forEach((v) => {
        if (!v || !v.path) return
        if (v.value === null || v.value === undefined) return
        seen.set(v.path, now)
        values.set(v.path, v.value)
      })
    })
  }

  function tick() {
    const now = Date.now()
    const scale = Number(cfg.scale) > 0 ? Number(cfg.scale) : 1
    const armGraceMs = (Number(cfg.neverGraceMinutes) || 2) * 60 * 1000

    ticks += 1
    if (ticks % 5 === 0) saveState()

    GROUPS.forEach((group) => {
      const ages = group.paths
        .filter((p) => seen.has(p))
        .map((p) => seen.get(p))

      if (ages.length === 0) {
        // Nothing from this group yet. Only complain if it has had a fair
        // chance - otherwise every reboot would announce missing feeds.
        if (now - startedAt > armGraceMs) raise(group, 'never', now - startedAt)
        return
      }

      if (group.activeWhen) {
        const v = values.get(group.activeWhen.path)
        if (typeof v !== 'number' || v <= group.activeWhen.above) {
          cancel(group)
          return
        }
      }

      const newest = Math.max.apply(null, ages)
      const ageMs = now - newest
      if (ageMs > group.timeout * 1000 * scale) {
        raise(group, 'stale', ageMs)
      } else {
        cancel(group)
      }
    })
  }

  const plugin = {
    id: PLUGIN_ID,
    name: 'Stale data watchdog',
    description:
      'Alerts when a data feed stops updating. Uses age of last update, not value change.',

    schema: {
      type: 'object',
      properties: {
        scale: {
          type: 'number',
          title: 'Timeout multiplier',
          description:
            'Multiply every timeout. 1 = engine 15s, GPS/depth/wind 20s, battery 60s.',
          default: 1
        },
        neverGraceMinutes: {
          type: 'number',
          title: 'Grace before reporting a feed that never arrived (minutes)',
          description:
            'Also the delay before a dead feed is reported after a Signal K restart that lost its saved state.',
          default: 2
        }
      }
    },

    start: function (settings) {
      cfg = (settings && settings.configuration) || {}
      startedAt = Date.now()
      ticks = 0
      seen.clear()
      values.clear()
      alerted.clear()
      loadState()

      app.signalk.on('delta', onDelta)
      timer = setInterval(tick, TICK_MS)
      app.setPluginStatus(
        `watching ${GROUPS.length} groups (${GROUPS.map((g) => g.id).join(', ')}), ` +
          `${seen.size} restored`
      )
      app.debug('stale-watchdog started')
    },

    stop: function () {
      if (timer) clearInterval(timer)
      timer = null
      saveState()
      app.signalk.removeListener('delta', onDelta)
    }
  }

  return plugin
}
