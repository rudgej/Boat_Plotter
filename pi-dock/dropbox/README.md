# Dropbox — offline boat manuals

The boat keeps a **local copy of the manuals library** so it works with no internet at sea.
Source of truth is one **dedicated Dropbox folder**, maintained from home. Sync is strictly
**one-way: Dropbox → boat**, so the boat can never overwrite or delete the master copy.

Built here as real files, restored by §4 and enabled by `bootstrap.sh`:

| Path | Role |
|---|---|
| `/usr/local/bin/manuals-sync.sh` | `rclone sync` Dropbox → `/home/pi/manuals`, skips quietly when offline |
| `/etc/systemd/system/manuals-sync.{service,timer}` | runs 5 min after boot, then every **6 hours** |
| `/etc/nginx/sites-available/manuals` | serves the library read-only on **:8081** (`:3000` = Signal K, `:8080` = AvNav) |
| `/home/pi/manuals/` | the local copy (created by the sync) |
| `/home/pi/manuals-sync.log` | sync log (must be writable by `pi` — the unit runs as `User=pi`) |
| `pi-dock/pi-config/usr/local/bin/launch-manuals.sh` | kiosk window for the dock button |

**Why only every 6 hours:** the library essentially never changes, so a frequent sync is pure
overhead. One run shortly after boot (so a boat that was switched off picks up additions) plus
every 6 hours covers it. A run with nothing to do logs a single line.

**Why nginx and not `python3 -m http.server`:** only nginx honours HTTP **Range** requests, so a
300-page engine manual pages and scrolls in the kiosk browser instead of having to be fetched whole
first. That difference is very obvious on a slow link and in 200 MB PDFs.

## One-time setup (needs your Dropbox login — cannot be scripted)

**Set up rclone on a machine with a browser, then copy the config to the boat.** The OAuth token
is portable, so this avoids the headless `rclone authorize` dance. On an Intel Mac, Homebrew no
longer ships bottles (`Tier 3`), so take the official binary instead:

```
curl -fsSL -o r.zip https://downloads.rclone.org/rclone-current-osx-amd64.zip
unzip r.zip && cp rclone-*-osx-amd64/rclone ~/rclone-bin/rclone   # chmod 755
~/rclone-bin/rclone config      # n → dropbox → dropbox → blank id/secret → n → y (browser)
```

1. Authorise Dropbox on that machine, then copy the config over:
   ```
   ssh pi@bossy.local 'mkdir -p ~/.config/rclone && chmod 700 ~/.config/rclone'
   scp ~/.config/rclone/rclone.conf pi@bossy.local:.config/rclone/   # then chmod 600 there
   ```
2. Confirm it works on the boat:
   ```
   rclone lsd dropbox:Boat-Manuals
   ```
3. Configure and run the first sync (this sets the remote via a systemd drop-in and syncs):
   ```
   sudo apt install rclone        # if not already present
   bash pi-dock/dropbox/configure-remote.sh
   ```
   Default remote is **`dropbox:Boat-Manuals`**. Override with `MANUALS_REMOTE`.
4. Check it:
   ```
   tail -20 /home/pi/manuals-sync.log
   find /home/pi/manuals -type f | head
   ```
5. Enable the timer (also done by `bootstrap.sh`):
   ```
   sudo systemctl enable --now manuals-sync.timer
   ```
6. Enable the web view:
   ```
   sudo ln -sf /etc/nginx/sites-available/manuals /etc/nginx/sites-enabled/manuals
   sudo nginx -t && sudo systemctl reload nginx
   ```
   Then `http://localhost:8081/` lists the library. (Removing `sites-enabled/default` is
   optional — it only stops nginx answering on port 80, which nothing on the boat needs. Leaving
   it is what the box does today.)

## Auth — never commit it

The rclone Dropbox remote stores an **OAuth token** in `~/.config/rclone/rclone.conf`, i.e.
`/home/pi/.config/rclone/rclone.conf` once set up as `pi`. That file is user-filled and must never
be committed to this repo. To clone the setup onto a replacement box, copy that file across
`sftp`/USB with `chmod 600`, or just re-run `rclone config`.

## Dock button

The dock's **Manuals** button replaced the unused **Grafana** one on 2026-11-19 — `dock.c` builds
its buttons from a table, so it is a single entry:

```c
{"Manuals",   "/usr/local/bin/launch-manuals.sh"},
```

Rebuild the dock (§7 of `MIGRATION.md`) after changing it. The library is also reachable at
`:8081` from any browser regardless.

## Naming convention (recommended)

`Category/Manufacturer_Model_Type.pdf`, e.g. `Engine/Yanmar_4JH_Workshop.pdf`,
`Electronics/Raymarine_Axiom_Manual.pdf`. rclone mirrors whatever structure you use, so a tidy
Dropbox folder gives a tidy on-boat library for free.
