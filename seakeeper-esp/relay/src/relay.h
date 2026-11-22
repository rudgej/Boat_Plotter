/* Simple TCP relay: listen on a local port, forward each connection to a
 * fixed upstream address, byte for byte.
 *
 * Deliberately not a router. Because the ESP32 originates the upstream
 * connection itself, it is sourced from the Ethernet interface address
 * (192.168.0.254), which the SeaKeeper can answer directly - no NAT, no port
 * forwarding and no gateway required on the unit.
 */
#pragma once

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Starts a listener task. Listens on all local addresses on `listen_port` and
 * forwards to `target_host:target_port`. Returns ESP_OK once the task exists;
 * bind/listen failures are logged and retried. */
esp_err_t relay_start(const char *name, uint16_t listen_port,
                      const char *target_host, uint16_t target_port);

#ifdef __cplusplus
}
#endif
