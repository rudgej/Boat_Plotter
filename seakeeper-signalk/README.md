# seakeeper-signalk

Bridges the SeaKeeper gyro into Signal K at 1 Hz.

The gyro serves its own MQTT broker over WebSocket on port 9001, reachable only
through the Wi-Fi/Ethernet relay. This Signal K plugin connects to that broker,
picks the fields worth keeping, and republishes them as Signal K deltas.

Measured on the boat: 1.0 Hz exactly, values arriving with
`$source: seakeeper-signalk`.

## What it publishes

| Signal K path | Source field | Units |
|---|---|---|
| `navigation.attitude.roll` | `boat_roll_angle` | **radians** (unit sends degrees) |
| `propulsion.gyro.powerEnabled` | `power_enabled` | boolean |
| `propulsion.gyro.stabilizeAvailable` | `stabilize_available` | boolean |
| `propulsion.gyro.stabilizeEnabled` | `stabilize_enabled` | boolean |
| `propulsion.gyro.targetRpm` | `flywheel_crt_selected_speed` | rpm |
| `propulsion.gyro.rpm` | `flywheel_speed` | rpm |
| `notifications.seakeeper` | `alarming_seekepers` | `normal` / `alarm` |

`navigation.attitude.roll` and `propulsion.gyro.revolutions` are the two paths
with a Signal K convention behind them; the rest are ours. Roll follows the
convention (radians) so attitude widgets work. RPM is published as rpm rather
than the standard `revolutions` Hz because every consumer on this boat talks in
rpm; there is no `propulsion.gyro.revolutions`, so nothing can silently read the
wrong unit.

The alarm notification is deliberately a boolean-ish: `normal` or `alarm`, with
the count in the message. Which alarm it is does not matter for control.

## Connection budget

One MQTT connection, always. The gyro's own web page holds two of the four
slots, so:

```
page 2 + this plugin 1 = 3 of 4  ->  one spare for tools
```

Verified: `ss -tn | grep 192.168.0.2:9001 | grep -c ESTAB` reports 3 while the
page is open and the plugin is running.

Do not add a second client here. If you need to poke at the unit by hand, use
the spare slot and disconnect afterwards — an abandoned connection holds its
slot for 120 s.

## Rate

The unit publishes status about 4 times a second. This plugin samples to 1 Hz
because a stored history at 4 Hz costs four times the disk for no extra
information. `rateHz` is configurable if that ever changes.

## Stale handling

If nothing has arrived for `staleSeconds` (default 10), the plugin stops
publishing and reports that in its status. A frozen gauge on a stabiliser is
worse than an obvious gap. It resumes on its own when the unit comes back — the
MQTT client retries every 5 s.

## Install

```sh
scp -i ~/.ssh/id_boat index.js package.json install-on-box.sh \
    pi@bossy.local:/tmp/sk/
ssh -i ~/.ssh/id_boat pi@bossy.local 'cd /tmp/sk && sh install-on-box.sh'
```

The installer copies the files to `~/.signalk/node_modules/seakeeper-signalk`,
writes the default config, loads the module, and restarts Signal K.

No dependency install is needed: `signalk-server` ships its own copy of `mqtt`
and the plugin borrows it through `createRequire`. Installing `mqtt` into the
plugin directory also works and takes precedence — that is preferable if you
want it to survive a Signal K upgrade.

## Check it

```sh
curl -s localhost:3000/signalk/v1/api/vessels/self/propulsion/gyro/rpm
curl -s localhost:3000/signalk/v1/api/vessels/self/navigation/attitude/roll
curl -s localhost:3000/signalk/v1/api/vessels/self/notifications/seakeeper
```

To watch the rate, sample timestamps and count distinct ones per second.

## Why a plugin rather than an external publisher

Signal K requires authentication for writes from outside the server: a bare
`PUT` to a path returns 401 unless the caller holds a device token, and issuing
one needs an admin approval step. A plugin writes deltas in-process with
`app.handleMessage`, so it needs no token, no HTTP round trip and no extra
service to supervise. This matches how the rest of this repository talks to
Signal K.

## Path registration note

Signal K rejects a `PUT` to a path no provider has registered, which is why
`enginetrends-status` exists. That does not apply here — this plugin *emits*
values rather than accepting them, so no registration step is needed.

The protocol this talks to is documented in
[`esp-seakeeper-relay/docs/seakeeper-protocol.md`](https://github.com/rudgej/esp-seakeeper-relay/blob/main/docs/seakeeper-protocol.md).
