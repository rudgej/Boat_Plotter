# stale-watchdog

A Signal K plugin that raises a notification when a data feed stops updating.

Signal K has **no concept of data expiry**. It keeps the last value forever and
never marks it stale, so a dead GPS keeps displaying its final speed
indefinitely. This plugin watches the age of the last update per feed and
notifies when one goes quiet.

## What it watches

| Group | Timeout | State | Blanks value |
|---|---|---|---|
| Depth (`environment.depth.belowTransducer`) | 6 s | **alarm** | yes |
| Position (`navigation.position`) | 3 s | warn | no |
| Speed/course/heading | 4 s | warn | no |
| Apparent wind | 25 s | warn | no |

Deliberately not watched: **engine** and **electrical**. An engine that is
switched off stops transmitting, and an alarm that fires during ordinary
operation teaches the crew to ignore alarms.

## Why those numbers

Measured on the boat at the Signal K websocket (`tools/measure-arrivals.py`):

```
depth        1.00 s median, 1.01 s max
position     0.20 s median, 0.22 s max
speed/course 0.27 s median, 0.30 s max
apparent wind  0.66 s median, 10.48 s MAX   <- bursty sender
```

Depth is only 1 Hz, so anything much below 6 s is exhausted by a couple of
dropped transmissions. Wind is the opposite problem: it arrives in bursts with
pauses up to 10.5 s, so a tight timeout flaps. The `scale` setting multiplies
all four timeouts if the feel needs adjusting.

## Staleness is age, not change

The test is "when did this last update", never "did the number change". Depth
sits rock-steady at anchor and is perfectly healthy; a simulator can repeat a
canned value 5 times a second and is also healthy. Only silence is stale.

## Surviving a restart

Last-seen times are persisted to `~/.signalk/stale-watchdog-state.json`, so a
Signal K restart does not blind the watchdog. This matters because the failure
being watched for — a lost CAN interface — makes signalk-server throw
`ERR_SOCKET_DGRAM_NOT_RUNNING` and get restarted, which would otherwise wipe the
plugin's memory precisely during the outage.

## Install

```bash
cp -r stale-watchdog ~/.signalk/node_modules/
cat > ~/.signalk/plugin-config-data/stale-watchdog.json <<'EOF'
{ "enabled": true, "configuration": { "scale": 1, "neverGraceMinutes": 2 } }
EOF
sudo systemctl restart signalk
```

## Verified

Dropping `can0` raised `depth=alarm`, `position=warn`, `navigation=warn` within
8 s; the CAN watchdog then restored the bus and the notifications cleared on
their own. Notifications live under `notifications.stalewatchdog.<group>`.
