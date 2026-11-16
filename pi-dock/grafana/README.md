# Grafana

The kiosk launcher survives (`pi-dock/launch-grafana.sh`); the server side was never captured in
the repo.

## What it was

A fullscreen Chromium kiosk — `--app`, window class `grafana-kiosk`, own profile
`~/.config/kiosk-grafana` — pointed at **`http://localhost:3001`**.

## Port 3001, not 3000

Signal K owns **3000**, and Grafana's own default is also 3000, so Grafana was moved to **3001**
to avoid the clash.

## Install & data source — `[TODO-CONFIRM]`, not captured

- Install method unknown (apt vs Docker).
- Data source unknown. `engine-trends/SPEC.md` deliberately chose SQLite, not InfluxDB, so **if**
  Grafana is revived it needs its own time-series source (InfluxDB, fed by a Signal K forwarder
  such as `signalk-to-influxdb`), or it charts something else entirely.
- **Dashboard definitions were not recovered** — no dashboard JSON exists in this repo; they must
  be re-created by hand.

## Rebuild (when desired)

1. Install Grafana; serve it on 3001 (or keep the kiosk URL at 3001).
2. Stand up a data source (InfluxDB + `signalk-to-influxdb` is the usual pairing).
3. Re-create the dashboards by hand; the existing `launch-grafana.sh` then points at them unchanged.
