# NetworkManager profiles

Captured from the N100 so a rebuild restores the network rather than guessing it.

| Profile | Interface | Purpose | Address |
|---|---|---|---|
| `BoatNetwork` | `wlx6815790f593c` (USB BrosTrend AX900) | **The AP**. Sensors and the Seakeeper bridge join this | **192.168.10.1/24**, DHCP `.100–.200` |
| `Bossywifi` | `wlp3s0` (onboard RTL8821CE) | Boat uplink, **priority 10** | DHCP |
| `3cpr` | `wlp3s0` | Home uplink, **priority 5** | DHCP |
| `seakeeper` | `enp2s0` | Direct SeaKeeper link, `never-default` | 192.168.0.254/24 |

## ⚠️ Passwords are stripped

Every `psk=` in these files is `CHANGE_ME`. Set the real ones after restoring:

```
sudo nmcli con mod BoatNetwork wifi-sec.psk '<password>'
sudo nmcli con mod Bossywifi   wifi-sec.psk '<password>'
sudo nmcli con mod 3cpr        wifi-sec.psk '<password>'
sudo nmcli con up BoatNetwork
```

## ⚠️ Permissions matter

NetworkManager **ignores** a keyfile that is not `600` and owned by root. Copying
these in with a normal `cp` leaves them 644 and the connection will simply not appear:

```
sudo chown root:root /etc/NetworkManager/system-connections/*.nmconnection
sudo chmod 600       /etc/NetworkManager/system-connections/*.nmconnection
sudo systemctl reload NetworkManager
```

## Why `192.168.10.1` must not change

Devices have it **compiled in** (wind sensor, tank sensor, the Seakeeper bridge).
It is set explicitly in `BoatNetwork.nmconnection` with `ipv4.addresses`. With
`ipv4.method=shared` and **no** explicit address, NetworkManager picks a default
of `10.42.x.x` and every one of those devices goes silent. The address line is
load-bearing.

It is also tied to the dongle: the interface name `wlx6815790f593c` derives from
that USB stick's MAC (`68:15:79:0f:59:3c`). Replace the dongle and the name
changes, this profile stops matching, and there is no `192.168.10.1` at all.
