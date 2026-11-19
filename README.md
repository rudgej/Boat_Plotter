# Boat Plotter

Configuration, automation and migration for the boat's navigation/plotter box.

## Layout

- **`pi-dock/`** — the live plotter config (Signal K, AvNav, KIP, dock, BoatNetwork AP, Shelly automation, watchdogs). Full docs in **`pi-dock/README.md`**. `pi-dock/canable2/` holds the offline CANable2 **candlelight** firmware and re-flash steps.
- **`MIGRATION.md`** — the step-by-step plan to rebuild on the **CWWK N100 x86** box (Debian 13 + Signal K + AvNav, no OpenPlotter/OpenCPN). Start here when the new hardware arrives.
- **`engine-trends/`** — the engine trend monitor: `SPEC.md` (locked spec), `engine-trends.py`
  (systemd daemon + Signal K plugin), `reset.sh` and the live-check tools. Deployed and running.
- **`pi-dock/pi-config/home/pi/.signalk/settings.json`** — Signal K's own config (pipedProviders
  for N2K, wind UDP and the two serial ports, plus security). Without this a restored Signal K has
  no data connections at all.
- **`n100/`** — the x86 build kit: `bootstrap.sh` (OS layer), `install-apps.sh` (Node 22 / Signal K / AvNav),
  `make-usb.sh` + `verify-usb.sh` + `test-usb-capacity.sh` (installer media), and `snapshot-n100.sh` (config backup).
- **`seakeeper-esp/`** — ESP32 firmware for the Seakeeper interface.
- **`signalk-zones/`**, **`signalk-plugins/`** — extra Signal K bits (zones setter, fuel-economy plugin).
- **`shelly-migration-baseline.md`** — Shelly switch migration notes.

## Current hardware

CWWK Fanless Industrial Mini PC — Intel N100, 8 GB RAM, 128 GB M.2 NVMe, 2× RS232/RS485 COM, dual 2.5 GbE, 12 V DC. (Replaces the Raspberry Pi 5, which died of a 5 V rail fault from the Waveshare CAN HAT.)
