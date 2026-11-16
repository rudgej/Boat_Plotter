# Dropbox sync — boat manuals

Status: **deferred — never implemented on the Pi; planned for the x86 rebuild.**

The only Dropbox use is the **boat manuals library**: a one-way pull from a Dropbox folder into the
local manuals tree, so the boat serves manuals offline.

## What / direction

- One-way: **Dropbox → local**. The boat never writes back.
- Master copy is a Dropbox folder (e.g. `Boat/Manuals/`), maintained from home.
- Local destination: `/home/pi/manuals/`.

## Mechanism

- **rclone** (CLI, headless). The official Dropbox Linux client is GUI-oriented; rclone is lighter
  and runs cleanly from a systemd timer.
- `rclone sync dropbox:BoatManuals /home/pi/manuals` — run on boot + hourly via a timer, i.e. it
  syncs whenever the box happens to be online. No daemon, no 24/7 requirement.

## Install

```
sudo apt install rclone
rclone config          # create remote `BoatManuals` of type `dropbox`
```

## Config / auth

- Config file: `~/.config/rclone/rclone.conf`.
- **Auth: an rclone Dropbox remote holds an OAuth token in that file — it is user-filled and must
  NOT be committed.** Create the remote with `rclone config` on the box; nothing secret goes in
  this repo.
- The destination folder is created by the sync itself; no server-side setup beyond the Dropbox
  folder existing.

## Left unfinished

The manuals library itself — nginx + `autoindex` serving `/home/pi/manuals` on `:8081`, a dock
"Manuals" button (Chromium `--app` → `http://localhost:8081/`), and the folder/naming convention
(`Category/Manufacturer_Model_Type.pdf`) — was agreed in principle but **not built**.
