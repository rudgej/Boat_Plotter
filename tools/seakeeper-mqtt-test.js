#!/usr/bin/env node
'use strict'

/*
 * seakeeper-mqtt-test.js - check the SeaKeeper's MQTT-over-WebSocket broker
 * headlessly, from the N100.
 *
 * Why this exists: the previous attempt at a headless client failed at CONNACK
 * even though the WebSocket handshake returned 101. That was later put down to
 * the unit's limit on concurrent sessions, which has since been raised. This
 * script answers the question definitively: does a non-browser client get a
 * working session now?
 *
 * Subscribe-only by default. Publishing to seakeeper/request/1 WILL physically
 * act on the gyro (power, speed, stabilise), so it needs --publish explicitly.
 *
 *   node seakeeper-mqtt-test.js                 # subscribe, print, exit after 10s
 *   node seakeeper-mqtt-test.js --seconds 30
 *   node seakeeper-mqtt-test.js --publish '{"power":1}'   # ACTS ON THE UNIT
 *
 * Requires the Ethernet link up: enp2s0 must have carrier and 192.168.0.2 must
 * answer ping. The broker is at ws://192.168.0.2:9001/mqtt, unauthenticated.
 */

const HOST = process.env.SK_HOST || '192.168.0.2'
const PORT = process.env.SK_PORT || 9001
const URL = `ws://${HOST}:${PORT}/mqtt`

const TOPICS = ['seakeeper/status/1', 'seakeeper/roll/1']

function loadMqtt () {
  // Signal K ships mqtt (a canboatjs dependency); try local first, then the
  // system install, so this works from anywhere on the box.
  const candidates = [
    'mqtt',
    '/usr/lib/node_modules/signalk-server/node_modules/mqtt',
    '/usr/lib/node_modules/signalk-server/node_modules/@canboat/canboatjs/node_modules/mqtt'
  ]
  for (const c of candidates) {
    try {
      return require(c)
    } catch (e) { /* try next */ }
  }
  console.error('FATAL: no mqtt package found. Tried:\n  ' + candidates.join('\n  '))
  process.exit(2)
}

const args = process.argv.slice(2)
const getArg = (name, dflt) => {
  const i = args.indexOf(name)
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt
}
const seconds = Number(getArg('--seconds', '10'))
const publish = getArg('--publish', null)

const mqtt = loadMqtt()
const t0 = Date.now()
const el = () => ((Date.now() - t0) / 1000).toFixed(2) + 's'

function preflight (cb) {
  // Distinguish "we cannot reach the unit at all" from "the broker rejected the
  // session". Without this the script blamed the session limit for a down cable.
  const net = require('net')
  const sock = net.connect({ host: HOST, port: PORT })
  let done = false
  const finish = (ok, why) => {
    if (done) return
    done = true
    sock.destroy()
    cb(ok, why)
  }
  sock.setTimeout(4000)
  sock.on('connect', () => finish(true))
  sock.on('timeout', () => finish(false, 'TCP connect timed out'))
  sock.on('error', (e) => finish(false, e.code || e.message))
}

preflight((ok, why) => {
  if (!ok) {
    console.log(`cannot reach ${HOST}:${PORT} - ${why}`)
    console.log('')
    console.log('---- result ----')
    console.log('HOST UNREACHABLE. This is not a broker or session problem.')
    console.log('Check: is enp2s0 up with carrier, and does ping ' + HOST + ' answer?')
    process.exit(3)
  }
  run()
})

function run () {
console.log(`reachable, connecting to ${URL}`)
console.log(`timeout ${seconds}s, ${publish ? 'WILL PUBLISH: ' + publish : 'subscribe only'}`)

const client = mqtt.connect(URL, {
  clientId: 'n100-test-' + Math.random().toString(16).slice(2, 8),
  clean: true,
  reconnectPeriod: 0,
  connectTimeout: seconds * 1000
})

let gotConnect = false
let msgs = 0
const byTopic = {}

client.on('connect', () => {
  gotConnect = true
  console.log(`[${el()}] CONNECTED - CONNACK received. Sessions are working.`)
  client.subscribe(TOPICS, { qos: 0 }, (err, granted) => {
    if (err) {
      console.log(`[${el()}] subscribe error: ${err.message}`)
      return
    }
    console.log(`[${el()}] subscribed: ${JSON.stringify(granted.map(g => g.topic))}`)
    if (publish) {
      client.publish('seakeeper/request/1', publish, { qos: 0 }, (e) => {
        console.log(`[${el()}] published to seakeeper/request/1: ${publish}` +
          (e ? ' error: ' + e.message : ''))
      })
    }
  })
})

client.on('message', (topic, payload) => {
  msgs++
  byTopic[topic] = (byTopic[topic] || 0) + 1
  const text = payload.toString()
  // Print the first message per topic in full, then just count.
  if (byTopic[topic] === 1) {
    console.log(`[${el()}] ${topic} (${text.length} bytes):`)
    console.log('   ' + text.slice(0, 900))
  } else if (byTopic[topic] % 10 === 0) {
    console.log(`[${el()}] ${topic}: ${byTopic[topic]} messages, last ${text.length} bytes`)
  }
})

client.on('error', (e) => {
  console.log(`[${el()}] ERROR: ${e.message || e}`)
})

client.on('close', () => {
  console.log(`[${el()}] connection closed`)
})

setTimeout(() => {
  console.log('')
  console.log('---- result ----')
  if (!gotConnect) {
    console.log('NO CONNACK - but the host was reachable, so this IS a broker/session')
    console.log('problem, not a cable. The WebSocket opened and the broker never')
    console.log('accepted the session. This is the failure mode seen before the')
    console.log('unit\'s concurrent-session limit was raised.')
  } else {
    console.log(`CONNACK ok, ${msgs} message(s) received.`)
    for (const t of Object.keys(byTopic)) console.log(`   ${t}: ${byTopic[t]}`)
    const missing = TOPICS.filter(t => !byTopic[t])
    if (missing.length) console.log(`   never received: ${missing.join(', ')}`)
  }
  client.end(true, () => process.exit(gotConnect ? 0 : 1))
}, seconds * 1000)
}
