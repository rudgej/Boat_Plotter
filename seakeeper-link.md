# SeaKeeper — Ethernet link, web UI and MQTT

Everything verified on the boat on **2026-11-21** from a MacBook Air (USB
Ethernet adapter) cabled directly to the SeaKeeper controller.

This document supersedes the SeaKeeper assumptions in `MIGRATION.md` §18 and
`seakeeper-esp/SETUP.md` §5–7. **The `172.16.102.1` address those documents are
built on does not exist.** See "What is wrong in the existing docs".

---

## 1. The short version

| | |
|---|---|
| Web UI | `http://192.168.0.2/` |
| SSH | `192.168.0.2:22` |
| MQTT (WebSocket) | `ws://192.168.0.2:9001/mqtt` |
| Subnet we must sit in | `192.168.0.0/24` |
| mDNS name | `canvu.local` |
| MAC | `1c:95:9f:07:22:70` |
| Integration mode | **Garmin** (`_garmin-mrn-html._tcp`) |

The unit is a **web server plus an MQTT broker**. Every button in the UI is an
MQTT publish to a single topic. There is no REST API.

---

## 2. Physical

- Direct cable, SeaKeeper RJ45 → USB Ethernet adapter on the Mac.
- Link negotiates **100baseTX full duplex**. The adapter is a Realtek
  **RTL8153** (`0bda:8153`); on the N100 the same cable lands on `enp2s0`.
- macOS cannot pin link speed on this adapter: `ifconfig en2 media …` returns
  `SIOCSIFMEDIA (media): Operation not supported on socket`.
- **Unexplained:** during one period the carrier cycled on a ~16 s period
  (10–12 s up, 4–5 s down) with no traffic involved. It later held stable for
  30+ s and the UI worked normally once reachable. Cause not established —
  see §9.

---

## 3. Addressing

Observed addresses for the same unit:

| When | Address | Note |
|---|---|---|
| Early, mid-boot | `169.254.5.161` | APIPA — a DHCP client that found no server |
| Settled, Garmin mode | **`192.168.0.2`** | there is no DHCP server anywhere on this cable |

**The address is not reliably stable across a power cycle.** Plan for that:
the host should serve a lease with a MAC pin so the unit always lands on the
same address (§6).

### mDNS service advertisements

Announced by the unit itself (it does **not** answer mDNS queries reliably, so
passive capture is more dependable than `dns-sd -G`):

```
canvu.local                              1c:95:9f:07:22:70
_http._tcp          :80     "Seakeeper controller on canvu"
_ssh._tcp           :22
_sftp-ssh._tcp      :22
_garmin-mrn-html._tcp :80   TXT "protovers=1" "path=/garmin/config.json"
                TXT "Seakeeper=true"   SRV canvu.local.:0
```

`_garmin-mrn-html` is the Garmin Marine Network HTML service type. The
integration setting (Garmin / Glass Helm / Raymarine / Simrad) changes what the
unit advertises, but in our testing it **did not change the address**, and it
still served `/garmin/config.json` after switching to Raymarine.

---

## 4. HTTP endpoints

| Path | Result |
|---|---|
| `GET /` | `200`, `text/html`, the UI (Bootstrap + Font Awesome) |
| `GET /garmin/config.json` | `200`, `{"title":"Seakeeper","path":"/index.html",…}` |
| `GET /assets/…` | static JS/CSS/images |

`config.json`:

```json
{"id":"6698b6b2-ae35-421b-8f8c-00c6fb83cae2","path":"/index.html",
 "title":"Seakeeper","icon":"/assets/images/logos/seakeeper-garmin-icon-3_2.png"}
```

Open ports: **80**, **22**, **9001**. Closed: 443, 8080.

---

## 5. MQTT — the control and telemetry interface

Transport is **MQTT over WebSocket**, using Paho (`/assets/js/mqttws31.js`).
The page sets `var port = "9001"` and connects to `ws://<host>:9001/mqtt`.

### 5.1 Topics

| Topic | Direction | Content |
|---|---|---|
| `seakeeper/request/1` | **we publish** | commands, JSON |
| `seakeeper/status/1` | subscribe | full state, JSON |
| `seakeeper/roll/1` | subscribe | roll angle stream |
| `seakeeper/gyros` | subscribe | list of `{ip_address, seakeeper_instance}` |
| `seakeeper/alarm` | subscribe | alarms |
| `seakeeper/alarmhistory/…` | subscribe | alarm history |

The trailing `1` is the **Seakeeper instance number**, taken from
`seakeeper/gyros`. A multi-unit boat would use `/2`, `/3`…

### 5.2 Commands — publish to `seakeeper/request/1`, QoS 0

| Action | Payload |
|---|---|
| Power on | `{"power":1}` |
| Power off | `{"power":0}` |
| Speed **minimum** (7600 rpm on this unit) | `{"flywheel_speed":1}` |
| Speed **maximum** (9700 rpm on this unit) | `{"flywheel_speed":0}` |
| Stabilise on | `{"stabilize":1}` |
| Stabilise off | `{"stabilize":0}` |

**Two traps:**

1. `flywheel_speed` in a *request* is a **selector**, not a number: `1` = min,
   `0` = max. It is inverted relative to intuition, and the JS function names
   (`setspeed_6500`, `setspeed_8450`) refer to a different model's speeds and
   will mislead anyone reading the source.
2. The actual rpm values are **not** in the UI's source — they come from the
   unit in the status message (`flywheel_min_speed`, `flywheel_max_speed`).

**Verified by round trip on 2026-11-21** (unit powered off, so this changes the
selector only — nothing spins):

| Published | `flywheel_crt_selected_speed` |
|---|---|
| `{"flywheel_speed":1}` | `1` |
| `{"flywheel_speed":0}` | `0` |

And the UI's own mapping, from `settings_page.js`:

```js
function setActiveSpeedButton(selectedSpeed) {
    if (selectedSpeed == '1') { $(".btn-6500").addClass("active"); ... }
    else                        { $(".btn-8450").addClass("active"); ... }
}
```

So `1` selects the **lower** of the two speed buttons and `0` the higher. On
this unit that is **`1` = 7600 rpm, `0` = 9700 rpm**. The class names
`btn-6500` / `btn-8450` are leftovers from another model and must be ignored.

Do not try to confirm this from the On-screen buttons: `.btn-8450` has
`active` hardcoded in the static HTML, so an un-updated page always looks like
"max selected".

### 5.3 Status — subscribe to `seakeeper/status/1`

Live payload captured from this unit while powered off:

```json
{"active_alarm_history":1,"battery_displayed":0,"battery_segments":31,
 "battery_voltage":12.399999618530273,"boat_roll_angle":-0.005401611328125,
 "display":"7.40.1.2332","drive1":"20020004","drive2":"2.02 / 0",
 "drive_current":0.37000274658203125,"drive_temperature":"29.0° C",
 "enclosure_pressure":"12","flywheel_crt_selected_speed":0,
 "flywheel_max_speed":9700,"flywheel_min_speed":7600,
 "flywheel_speed":0,"flywheel_speed_percent":0,"gcm":"10.82",
 "graph_is_dial_left":1,"gyro_angle":17.699996948242188,"imu":"2.54",
 "language":0,"model":"6","power_available":1,"power_enabled":0,
 "progress_bar_available":false,"progress_bar_percentage":0,
 "roll_angle_flipped":false,"run_hours":1434,"sea_hours":1311,
 "seakeeper_instance":1,"serial":"60055","stabilize_available":false,
 "stabilize_enabled":0,"tcml":"2993"}
```

Fields that matter for a plotter integration:

| Field | Meaning |
|---|---|
| `flywheel_speed` | **actual rotor rpm**, live — confirmed ramping 0→41 over ~9 s from a power-on. It reads 0 the moment power is cut **because at 41 rpm there is essentially no stored energy** — the rotor really does stop at once. At operating speed (7600/9700 rpm) coast-down takes **hours**, so expect a long decay here, not a step to zero. Not yet observed at speed (§9) |
| `flywheel_speed_percent` | 0–100, drives the speed ring |
| `flywheel_min_speed` / `flywheel_max_speed` | 7600 / 9700 on this unit |
| `flywheel_crt_selected_speed` | current selector, 0 = max, 1 = min |
| `stabilize_available` | **gates the Stabilise button**; false until at speed |
| `stabilize_enabled` | stabilisation actually engaged (0/1) |
| `power_available` / `power_enabled` | power control state |
| `boat_roll_angle`, `gyro_angle` | degrees |
| `battery_voltage` | 12.4 V here |
| `drive_temperature` | `"29.0° C"` — a **string**, not a number |
| `run_hours`, `sea_hours`, `serial`, `model` | identification |

Watch the types: `drive_temperature` and `enclosure_pressure` are strings,
`battery_voltage` and `boat_roll_angle` are floats. Parse defensively.

---

## 6. Host configuration

### 6.1 MacBook (verified working)

One setting is required — an address on the unit's subnet with **no router** so
the ethernet can never take the default route away from Wi-Fi:

```sh
sudo networksetup -setmanual "USB 10/100/1000 LAN" 192.168.0.254 255.255.255.0 ""
```

The trailing `""` (blank router) is deliberate and load-bearing. Verify with
`networksetup -getinfo "USB 10/100/1000 LAN"` → `Manual Configuration`,
`Router: (null)`.

Then `http://192.168.0.2/` works. This is **persistent** — it survives
unplugging the adapter and rebooting.

### 6.2 N100 (`enp2s0`) — proposed

Same shape as the existing `seakeeper` NetworkManager connection, different
subnet:

```sh
sudo nmcli con add type ethernet ifname enp2s0 con-name seakeeper \
    ipv4.method manual ipv4.addresses 192.168.0.254/24 \
    ipv4.gateway "" ipv4.dns "" ipv4.never-default yes \
    ipv6.method disabled connection.autoconnect yes \
    connection.autoconnect-priority 50
```

`never-default` is the important part: `enp2s0` must never become the internet
route.

**Because the unit's address is not stable, give it a lease.** A DHCP server
scoped to this interface only, with a MAC pin, makes `192.168.0.2`
deterministic:

```
# /etc/dnsmasq.d/seakeeper.conf
interface=enp2s0
bind-dynamic
port=0
dhcp-range=192.168.0.100,192.168.0.200,12h
dhcp-host=1c:95:9f:07:22:70,192.168.0.2
dhcp-option=3
```

Then every launcher, doc and bookmark can point at `http://192.168.0.2/` and
stay correct.

> Never a general dnsmasq bound to `0.0.0.0:53` — that breaks the BoatNetwork
> AP (see `MIGRATION.md` §8).

---

## 7. Evidence log

Things that were actually measured, so this can be re-checked:

```
# reachability
ping -c3 192.168.0.2         → 3/3 received, 1.588/2.238/3.240 ms
curl -o /dev/null -w '%{http_code}' http://192.168.0.2/          → 200
curl -o /dev/null -w '%{http_code}' http://192.168.0.2/garmin/config.json → 200
nc -z 192.168.0.2 22 / 80 / 9001                                  → open
nc -z 192.168.0.2 443 / 8080                                      → closed

# identity
tcpdump -ni en2 -e          → frames from 1c:95:9f:07:22:70
dns-sd -G v4 canvu.local    → 192.168.0.2

# commands (captured while clicking in the UI)
{"power":1} {"power":0} {"flywheel_speed":1} {"flywheel_speed":0}

# power cycle, 2026-11-21 — proves flywheel_speed is a live rpm counter
t(s)  rpm  power
 0.3    0      1     <- {"power":1} accepted, power_enabled flips immediately
 2.3    3      1
 4.3   10      1
 6.3   22      1
 8.3   35      1
 9.2   41      1     <- ~4.5 rpm/s early in the ramp
10.3    0      0     <- {"power":0}: 0 immediately, as expected at 41 rpm
                        (no stored energy). At 7600/9700 rpm the rotor coasts
                        down over HOURS - not yet observed, see §9
```

---

## 8. What is wrong in the existing docs

| Document | Says | Reality |
|---|---|---|
| `MIGRATION.md` §18 | SeaKeeper assumed at `172.16.102.1` | unit is at **`192.168.0.2`**; `.1` never existed |
| `MIGRATION.md` §18.3 | DHCP fallback pool `172.16.102.100–200` | pool must be `192.168.0.x` |
| `seakeeper-esp/SETUP.md` §5 | bridge downlink `172.16.102.254/24`, port-forward to `172.16.102.1` | target should be `192.168.0.2` |
| `pi-dock/…/seakeeper.nmconnection` | `172.16.102.254/24` | should be `192.168.0.254/24` |
| `n100/setup-seakeeper-enp2s0.sh` | `ADDR=172.16.102.254/24` | should be `192.168.0.254/24` |
| `pi-dock/…/launch-seakeeper.sh` | `http://192.168.10.50/` (via bridge) | direct: `http://192.168.0.2/` |

The `172.16.102.x` assumption traced back to a guess recorded in
`seakeeper-esp/SETUP.md`, and everything downstream inherited it. It is now
disproved by measurement, not by another guess.

---

## 9. Open questions

1. **Why did the carrier cycle at ~16 s for a period?** It stopped on its own
   and the UI then worked normally. Candidates: adapter/PHY instability, the
   unit's boot sequence, a marginal cable. Not resolved. If it recurs, capture
   `tcpdump -ni en2 -e` across a drop and compare against the unit's own
   announcements.
2. **Is the address static or DHCP?** It produced APIPA once and `192.168.0.2`
   later, with no DHCP server present. That pattern suggests a DHCP client
   falling back, but it has not been proven. The MAC-pinned lease in §6.2 makes
   the question moot for the install.
3. **Headless MQTT client — RESOLVED 2026-11-21.** A real MQTT library works
   headlessly; only a hand-rolled WebSocket layer fails.

   Verified with `paho-mqtt` (Python), no browser involved:

   ```python
   import paho.mqtt.client as mqtt
   cli = mqtt.Client(client_id="n100probe", transport="websockets")
   cli.ws_set_options(path="/mqtt")
   cli.connect("192.168.0.2", 9001, 15)
   cli.subscribe("seakeeper/status/1", qos=0)
   ```

   Result: `connected rc=Success`, messages arriving on `seakeeper/status/1`
   with `flywheel_speed`, `flywheel_speed_percent`, `stabilize_available`,
   `stabilize_enabled`, `flywheel_min_speed` (7600) and `flywheel_max_speed`
   (9700).

   **The trap was ours, not theirs.** A hand-written WebSocket implementation
   completed the HTTP upgrade (`101`) but was dropped before CONNACK. The same
   MQTT CONNECT bytes sent from a browser WebSocket returned `20 02 00 00`
   immediately — so the MQTT payload was always correct and the fault was in
   our manual framing. **Do not hand-roll the WebSocket layer**; use
   `paho-mqtt` with `transport="websockets"`, or `mosquitto_sub --url
   ws://192.168.0.2:9001/mqtt`.

   Note the UI's own JS bypasses this by using Paho in the browser. Either way,
   a native client is available — no headless Chromium required.
4. **Do the other integration modes move the address?** Raymarine was tested
   and did not. Glass Helm and Simrad were not tested.
5. **A second MQTT client appears to displace the UI's connection.** After a
   Python client connected, the open browser page stopped reflecting changes it
   should have received (its DOM stayed on the hardcoded defaults while the
   unit reported the new value). Not yet isolated: single-connection broker, or
   a client-ID/keepalive interaction. **Relevant before running a Signal K
   bridge on the box** — verify whether the operator's browser UI and the
   bridge can be connected simultaneously.
6. **What does `flywheel_speed` do during a real coast-down?** At 41 rpm it
   goes to 0 at once, and rightly so — there is no stored energy at that speed.
   At 7600/9700 rpm the rotor takes **hours** to stop. Whether the field reports
   that decaying speed, or holds/latches something, is untested — and it decides
   whether rpm can be shown honestly on a helm display during shutdown. To test:
   bring the unit to speed, command `{"power":0}`, and sample
   `seakeeper/status/1` across the decay.

---

## 10. Next steps (morning)

- [ ] Point `192.168.0.2` at the box: update `seakeeper.nmconnection`,
      `setup-seakeeper-enp2s0.sh`, `launch-seakeeper.sh`
- [ ] Add the dnsmasq MAC-pinned lease and verify the unit keeps `.2` across a
      power cycle
- [ ] Correct `MIGRATION.md` §18 and `seakeeper-esp/SETUP.md` §5–7
- [ ] Decide on a headless MQTT subscriber for Signal K (read-only first:
      rpm, roll, alarm state), with the six commands behind an explicit switch
- [ ] Re-test the ~16 s carrier cycling if it reappears
