/* Copy this file to secrets.h (same directory) and fill in the real values.
 * secrets.h is git-ignored, so the password never reaches the repository.
 *
 *   cp main/secrets.example.h main/secrets.h
 *
 * Only the values you actually want to change need to be here; anything left
 * out falls back to the defaults in board_config.h.
 */
#pragma once

#define CFG_WIFI_SSID       "BoatNetwork"
#define CFG_WIFI_PASSWORD   "CHANGE-ME"
