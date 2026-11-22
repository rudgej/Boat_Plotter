/* Fixed constants for the SeaKeeper relay.
 *
 * Single-purpose firmware: one board, one boat, one SeaKeeper. Nothing here is
 * meant to be configurable, and nothing is read at runtime - if the boat
 * changes, this file changes and the board is reflashed.
 *
 * The addresses are not arbitrary:
 *   192.168.10.50   this board on the N100's AP, outside its .100-.200 pool
 *   192.168.0.254   this board on the SeaKeeper's subnet, used as the source
 *                   address of every relayed connection
 *   192.168.0.2     the SeaKeeper itself
 */
#pragma once

/* ---------------- Wi-Fi uplink (BoatNetwork) ---------------- */

#define CFG_WIFI_SSID       "BoatNetwork"
#define CFG_WIFI_PASSWORD   "B0ssywifi"

#define CFG_STA_IP          "192.168.10.50"
#define CFG_STA_NETMASK     "255.255.255.0"
#define CFG_STA_GATEWAY     "192.168.10.1"

/* ---------------- Ethernet downlink (to the SeaKeeper) ---------------- */

/* The SeaKeeper has no gateway, so this interface must share its /24. Every
 * relayed connection is sourced from this address, which is exactly what makes
 * the unit's replies reachable. */
#define CFG_ETH_IP          "192.168.0.254"
#define CFG_ETH_NETMASK     "255.255.255.0"

#define CFG_UPSTREAM_HOST   "192.168.0.2"

/* Ports relayed from BoatNetwork to the unit: web UI and MQTT/WebSocket. */
#define CFG_PORT_WEB        80
#define CFG_PORT_MQTT       9001

/* ---------------- WT32-ETH01 wiring ---------------- */

/* LAN8720 PHY on the internal RMII bus; 50 MHz clock fed into GPIO0. GPIO16 is
 * the PHY power enable and must be driven high before the driver starts. */
#define CFG_ETH_PHY_ADDR    1
#define CFG_ETH_MDC_GPIO    23
#define CFG_ETH_MDIO_GPIO   18
#define CFG_ETH_POWER_GPIO  16
