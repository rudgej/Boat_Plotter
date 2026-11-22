/* Fixed-purpose TCP relay for the SeaKeeper bridge.
 *
 * Two listeners (web UI, MQTT over WebSocket), one upstream device. There is
 * deliberately no configuration: addresses and ports come from board_config.h.
 */
#pragma once

#include <stdint.h>
#include "esp_err.h"

/* Listens on CFG_STA_IP:listen_port and forwards each accepted connection to
 * CFG_UPSTREAM_HOST:upstream_port, sourced from CFG_ETH_IP. `name` is used in
 * log lines only; `max_conns` caps concurrent connections for this port alone,
 * so one listener cannot exhaust another's slots. Returns ESP_OK once the
 * listener task exists; bind failures are retried in the background (the
 * address is not available until Wi-Fi is up, so an early failure is expected
 * and not fatal). */
esp_err_t relay_start(const char *name, uint16_t listen_port, uint16_t upstream_port,
                      uint8_t max_conns);
