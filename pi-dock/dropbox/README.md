# Dropbox — offline boat manuals

The boat keeps a **local copy of the manuals library** so it works with no internet at sea.
Source of truth is one **dedicated Dropbox folder**, maintained from home. Sync is strictly
**one-way: Dropbox → boat**, so the boat can never overwrite or delete the master copy.

Built here as real files, restored by §4 and enabled by `bootstrap.sh`:

| Path | Role |
|---|---|
| `/usr/local/bin/manuals-sync.sh` | `rclone sync` Dropbox → `/home/pi/manuals`, skips quietly when offline |
| `/etc/systemd/system/manuals-sync.{service,timer}` | runs 5 min after boot, then every 30 min |
| `/etc/nginx/sites-available/manuals` | serves the library read-only on **:8081** (`:3000` = Signal K, `:8080` = AvNav) |
| `/home/pi/manuals/` | the local copy (created by the sync) |
| `pi-dock/pi-config/usr/local/bin/launch-manuals.sh` | kiosk window for the dock button |

**Why nginx and not `python3 -m http.server`:** only nginx honours HTTP **Range** requests, so a
300-page engine manual pages and scrolls in the kiosk browser instead of having to be fetched whole
first. That difference is very obvious on a slow link and in 200 MB PDFs.

## One-time setup (needs your Dropbox login — cannot be scripted)

1. Create the dedicated folder in Dropbox, e.g. **`BoatManuals`**, and put the manuals in it.
2. On the N100:
   ```
   sudo apt install rclone        # or: sudo dpkg -i <usb>/offline/debs/rclone_*.deb
   rclone config                  # n) new remote
                                  #    name> dropbox
                                  #    storage> dropbox
                                  #    (accept defaults, authorise in a browser via the URL it prints)
   rclone lsd dropbox:BoatManuals # must list your folders
   ```
3. Do the first sync by hand and check it:
   ```
   sudo systemctl start manuals-sync.service
   sudo tail -20 /var/log/manuals-sync.log
   find /home/pi/manuals -type f | head
   ```
4. Enable the timer (also done by `bootstrap.sh`):
   ```
   sudo systemctl enable --now manuals-sync.timer
   ```
5. Enable the web view:
   ```
   sudo ln -sf /etc/nginx/sites-available/manuals /etc/nginx/sites-enabled/manuals
   sudo rm -f /etc/nginx/sites-enabled/default     # stops nginx answering on 80
   sudo nginx -t && sudo systemctl reload nginx
   ```
   Then `http://localhost:8081/` lists the library.

## Auth — never commit it

The rclone Dropbox remote stores an **OAuth token** in `~/.config/rclone/rclone.conf`, i.e.
`/home/pi/.config/rclone/rclone.conf` once set up as `pi`. That file is user-filled and must never
be committed to this repo. To clone the setup onto a replacement box, copy that file across
`sftp`/USB with `chmod 600`, or just re-run `rclone config`.

## Dock button (optional, 1 line)

`dock.c` builds its buttons from a table, so adding **Manuals** is a single entry next to
`launch-grafana.sh`:

```c
{"Manuals",   "/usr/local/bin/launch-manuals.sh"},
```

Then rebuild the dock (§7). Omitted by default so the dock keeps the layout you know; the library is
reachable at `:8081` from any browser regardless.

## Naming convention (recommended)

`Category/Manufacturer_Model_Type.pdf`, e.g. `Engine/Yanmar_4JH_Workshop.pdf`,
`Electronics/Raymarine_Axiom_Manual.pdf`. rclone mirrors whatever structure you use, so a tidy
Dropbox folder gives a tidy on-boat library for free.
