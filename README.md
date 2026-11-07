# Boat Plotter

Configuration, automation and migration for the boat's navigation/plotter box.

## Layout

- **`pi-dock/`** — the live plotter config (Signal K, AvNav, KIP, dock, BoatNetwork AP, Shelly automation, watchdogs). Full docs in **`pi-dock/README.md`**.
- **`MIGRATION.md`** — the step-by-step plan to rebuild on the **CWWK N100 x86** box (Debian 13 + Signal K + AvNav, no OpenPlotter/OpenCPN). Start here when the new hardware arrives.
- **`seakeeper-esp/`** — ESP32 firmware for the Seakeeper interface.
- **`signalk-zones/`**, **`signalk-plugins/`** — extra Signal K bits (zones setter, fuel-economy plugin).
- **`shelly-migration-baseline.md`** — Shelly switch migration notes.

## Current hardware

CWWK Fanless Industrial Mini PC — Intel N100, 8 GB RAM, 128 GB M.2 NVMe, 2× RS232/RS485 COM, dual 2.5 GbE, 12 V DC. (Replaces the Raspberry Pi 5, which died of a 5 V rail fault from the Waveshare CAN HAT.)
