# Shelly Migration Baseline — 2026-11-04

Goal: move all Shelly devices from `Automation` SSID to `Lighting` SSID (same VLAN 20).
Current stage: **backup WiFi = Lighting** written on all online devices; **primary = Automation** untouched (devices still live on Automation).

## Summary
- Online + migrated (backup=Lighting): **64**
- Offline (not yet migrated): **15**

## Offline / not yet migrated (watch list — check back in a few hours)

| Hostname | MAC | Last seen |
|----------|-----|-----------|
| shellydimmer2-E89F6D858B56 | e8:9f:6d:85:8b:56 | 14.9h |
| shellyplus1pm-441793d69434 | 44:17:93:d6:94:34 | 26.7h (brand new) |
| shellyplus1-2cbcbb3a3cc8 | 2c:bc:bb:3a:3c:c8 | 8.8d |
| shellydimmer2-4C7525347285 | 4c:75:25:34:72:85 | 11.8d |
| shellyplus1-08a6f77e0394 | 08:a6:f7:7e:03:94 | 27.2d |
| shellydimmer2-48E7296784A3 | 48:e7:29:67:84:a3 | 59.1d |
| shellyplus1-e465b842fb34 | e4:65:b8:42:fb:34 | 59.2d (BOAT — exclude) |
| shellyrgbw2-E868E7F39666 | e8:68:e7:f3:96:66 | 61.3d |
| shellydimmer2-40915156733B | 40:91:51:56:73:3b | 65.1d |
| shellydimmer2-48E72967E4E8 | 48:e7:29:67:e4:e8 | 65.1d |
| shellydimmer2-C45BBE7949B2 | c4:5b:be:79:49:b2 | 65.2d |
| shellydimmerg3-0892725f154c | 08:92:72:5f:15:4c | 65.2d |
| shellydimmerg3-0892725e8094 | 08:92:72:5e:80:94 | 65.2d |
| shellydimmer2-C45BBE79300E | c4:5b:be:79:30:0e | 65.2d |
| shellydimmerg3-0892725ee36c | 08:92:72:5e:e3:6c | 65.2d |

> **Resolved 2026-11-04 (later check):** the 59–65d entries are confirmed **dead/gone** (replaced). The two recent entries (`shellydimmer2-E89F6D858B56` @16.6h and `shellyplus1pm-441793d69434` @28.4h) are **boat Shellys**, not home devices — excluded. **Conclusion: no home devices are missing; migration of all live home Shellies is complete.**

## Online + migrated (backup = Lighting) — 64 devices

### Gen2 (11)
`.120 Pro4PM`, `.172 Pro3EM`, `.176 DimmerG3`, `.193 DimmerG3`, `.221 Plus1PM`, `.223 Plus1`, `.37 Plus1PM`, `.63 Pro4PM`, `.7 Plus1PM`, `.78 DimmerG3`, `.91 DimmerG3`

### Gen1 (53)
SHDM-2 (Dimmer2): `.115 .119 .126 .13 .133 .134 .142 .152 .156 .192 .2 .203 .231 .234 .237 .242 .25 .46 .50 .52 .53 .55 .6 .65 .69 .94`
SHRGBW2 (RGBW2): `.109 .11 .128 .137 .153 .157 .160 .161 .163 .178 .18 .191 .204 .224 .23 .247 .250 .28 .38 .40 .61 .70 .84 .85 .9 .95`
SHSW-1 (Shelly 1): `.44`

## Notes
- gen1 backup write: POST `/settings/sta1` (form-urlencoded: enabled/ssid/pass/ipv4_method). `sta`/`sta2` = primary.
- gen2 backup write: RPC `WiFi.SetConfig` `{"config":{"sta1":{enable,ssid,pass,is_open}}}`. `sta`=primary, `sta1`=backup.
- To re-check later: run `python3 /tmp/shelly_final_check.py` (lists online + any non-Lighting backup) and compare offline list against UniFi.
