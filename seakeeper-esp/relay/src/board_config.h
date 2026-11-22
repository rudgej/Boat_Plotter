/* Configuration for the SeaKeeper Wi-Fi <-> Ethernet relay.
 *
 * Everything you might want to change lives here and nowhere else.
 *
 * Credentials: if a file called secrets.h sits next to this one it is included
 * first and can override any value below. That file is gitignored, so real
 * passwords never reach the repository; without it the defaults are used.
 *
 *   cp board_config.h secrets-example ... no - see README:
 *     create main/secrets.h containing e.g.
 *       #define CFG_WIFI_SSID     "BoatNetwork"
 *       #define CFG_WIFI_PASSWORD "the-real-password"
 *
 * Values may also be overridden at build time: idf.py -DCFG_WIFI_SSID=\"x\"
 */
#pragma once

#if defined(__has_include)
#  if __has_include("secrets.h")
#    include "secrets.h"
#  endif
#endif

/* ---------------- Wi-Fi uplink (BoatNetwork) ---------------- */

#ifndef CFG_WIFI_SSID
#define CFG_WIFI_SSID       "BoatNetwork"
#endif

#ifndef CFG_WIFI_PASSWORD
#define CFG_WIFI_PASSWORD   ""          /* empty = open network */
#endif

/* Static address on the boat network. The N100's AP is 192.168.10.1/24 and
 * gives out .100-.200, so .50 is safely outside the pool. */
#ifndef CFG_STA_IP
#define CFG_STA_IP          "192.168.10.50"
#endif
#ifndef CFG_STA_NETMASK
#define CFG_STA_NETMASK     "255.255.255.0"
#endif
#ifndef CFG_STA_GATEWAY
#define CFG_STA_GATEWAY     "192.168.10.1"
#endif
#ifndef CFG_STA_DNS
#define CFG_STA_DNS         "192.168.10.1"
#endif

/* ---------------- Ethernet downlink (to the SeaKeeper) ---------------- */

/* The SeaKeeper is statically configured at 192.168.0.2 and has no gateway.
 * This interface must therefore sit in the same /24; that is what makes the
 * relayed connection's source address reachable by the unit. */
#ifndef CFG_ETH_IP
#define CFG_ETH_IP          "192.168.0.254"
#endif
#ifndef CFG_ETH_NETMASK
#define CFG_ETH_NETMASK     "255.255.255.0"
#endif

/* ---------------- Relay targets ---------------- */

/* Upstream device. Must be the SeaKeeper's own address. */
#ifndef CFG_UPSTREAM_HOST
#define CFG_UPSTREAM_HOST   "192.168.0.2"
#endif

/* Ports relayed from the Wi-Fi side to the upstream. 80 is the web UI,
 * 9001 is the MQTT-over-WebSocket broker the page uses for live data and
 * commands. */
#ifndef CFG_PORT_WEB
#define CFG_PORT_WEB        80
#endif
#ifndef CFG_PORT_MQTT
#define CFG_PORT_MQTT       9001
#endif

/* ---------------- WT32-ETH01 board wiring ---------------- */

/* LAN8720 PHY on the internal RMII bus, 50 MHz clock fed into GPIO0.
 * GPIO16 is the PHY power enable and must be driven high before init. */
#ifndef CFG_ETH_PHY_ADDR
#define CFG_ETH_PHY_ADDR    1
#endif
#ifndef CFG_ETH_MDC_GPIO
#define CFG_ETH_MDC_GPIO    23
#endif
#ifndef CFG_ETH_MDIO_GPIO
#define CFG_ETH_MDIO_GPIO   18
#endif
#ifndef CFG_ETH_POWER_GPIO
#define CFG_ETH_POWER_GPIO  16
#endif

/* ---------------- Sanity checks evaluated at compile time ---------------- */

#if CFG_PORT_WEB == CFG_PORT_MQTT
#error "CFG_PORT_WEB and CFG_PORT_MQTT must differ"
#endif
