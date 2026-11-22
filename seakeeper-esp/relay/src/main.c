/* SeaKeeper relay - Wi-Fi to Ethernet byte pipe.
 *
 * Wi-Fi (BoatNetwork, static) is the uplink the N100 talks to.
 * Ethernet (static, same /24 as the SeaKeeper) is the downlink.
 * Two TCP ports are relayed: 80 (web UI) and 9001 (MQTT over WebSocket).
 *
 * No routing, no NAT, no port forwarding on the SeaKeeper side: the ESP32
 * writes that do not exist here.
 */

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_timer.h"
#include "esp_system.h"
#include "esp_eth.h"
#include "esp_eth_mac_esp.h"        /* ETH_ESP32_EMAC_DEFAULT_CONFIG, EMAC_CLK_EXT_IN */
#include "esp_eth_phy.h"
#include "esp_eth_netif_glue.h"     /* esp_eth_new_netif_glue */
#include "nvs_flash.h"
#include "driver/gpio.h"

#include "board_config.h"
#include "relay.h"

static const char *TAG = "app";

static esp_netif_t *s_sta_netif = NULL;
static esp_netif_t *s_eth_netif = NULL;
static esp_timer_handle_t s_reconnect_timer = NULL;

/* Retry runs in the esp_timer task, not in the event handler. Blocking the
 * default event loop here would also delay Ethernet link events. */
static void wifi_reconnect_cb(void *arg)
{
    esp_wifi_connect();
}

/* ------------------------------------------------------------------ */
/* Wi-Fi station                                                       */
/* ------------------------------------------------------------------ */

static bool wifi_has_password(void)
{
    return CFG_WIFI_PASSWORD[0] != '\0';
}

static void wifi_apply_static_ip(void)
{
    esp_netif_dhcpc_stop(s_sta_netif);

    esp_netif_ip_info_t ip;
    memset(&ip, 0, sizeof(ip));
    ip.ip.addr      = esp_ip4addr_aton(CFG_STA_IP);
    ip.netmask.addr = esp_ip4addr_aton(CFG_STA_NETMASK);
    ip.gw.addr      = esp_ip4addr_aton(CFG_STA_GATEWAY);

    esp_err_t err = esp_netif_set_ip_info(s_sta_netif, &ip);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "static IP %s failed: %s", CFG_STA_IP, esp_err_to_name(err));
        return;
    }

    /* No DNS: every peer this board talks to is an IP literal. */
    ESP_LOGI(TAG, "wifi static IP %s/%s gw %s", CFG_STA_IP, CFG_STA_NETMASK,
             CFG_STA_GATEWAY);
}

static void wifi_event_handler(void *arg, esp_event_base_t base,
                               int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *d = (wifi_event_sta_disconnected_t *)data;
        ESP_LOGW(TAG, "wifi disconnected (reason %d), retrying in 1 s",
                 d ? d->reason : -1);

        /* Re-arm from now so a disconnect storm still retries once per second,
         * and never connect immediately in parallel with a pending timer. */
        if (s_reconnect_timer == NULL) {
            esp_wifi_connect();
        } else {
            esp_timer_stop(s_reconnect_timer);
            esp_timer_start_once(s_reconnect_timer, 1000 * 1000);
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *)data;
        if (s_reconnect_timer != NULL) {
            esp_timer_stop(s_reconnect_timer);
        }
        ESP_LOGI(TAG, "wifi up: " IPSTR, IP2STR(&e->ip_info.ip));
    }
}

static void wifi_init(void)
{
    s_sta_netif = esp_netif_create_default_wifi_sta();
    wifi_apply_static_ip();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    const esp_timer_create_args_t timer_args = {
        .callback = &wifi_reconnect_cb,
        .name     = "wifi-retry",
    };
    ESP_ERROR_CHECK(esp_timer_create(&timer_args, &s_reconnect_timer));

    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                               &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               &wifi_event_handler, NULL));

    wifi_config_t wc;
    memset(&wc, 0, sizeof(wc));
    strlcpy((char *)wc.sta.ssid, CFG_WIFI_SSID, sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, CFG_WIFI_PASSWORD, sizeof(wc.sta.password));
    wc.sta.threshold.authmode = wifi_has_password() ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    if (!wifi_has_password()) {
        ESP_LOGW(TAG, "CFG_WIFI_PASSWORD is empty: " CFG_WIFI_SSID
                      " is WPA2, so association will be refused");
    }

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));

    /* Modem sleep adds tens to hundreds of milliseconds of latency and can drop
     * inbound frames. This board is a bridge, not a battery sensor, so it stays
     * awake. */
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "wifi started, joining \"%s\"", CFG_WIFI_SSID);
}

/* ------------------------------------------------------------------ */
/* Ethernet (WT32-ETH01, LAN8720)                                      */
/* ------------------------------------------------------------------ */

/* Link state is logged rather than acted on: TCP connections fail fast when the
 * cable is out and recover by themselves when it returns, but without these
 * events a dropped link looks like the SeaKeeper ignoring us - which is exactly
 * the confusion this project started with. */
static void eth_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    (void)data;

    switch (id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "ethernet driver started");
        break;
    case ETHERNET_EVENT_STOP:
        ESP_LOGW(TAG, "ethernet driver stopped");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ethernet link up");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "ethernet link down - downlink dead until it returns");
        break;
    default:
        break;
    }
}

static esp_err_t eth_init(void)
{
    /* PHY power enable on this board. */
    gpio_config_t io;
    memset(&io, 0, sizeof(io));
    io.pin_bit_mask = 1ULL << CFG_ETH_POWER_GPIO;
    io.mode         = GPIO_MODE_OUTPUT;
    gpio_config(&io);
    gpio_set_level(CFG_ETH_POWER_GPIO, 1);
    vTaskDelay(pdMS_TO_TICKS(100));      /* let the PHY settle */

    eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
    phy_config.phy_addr    = CFG_ETH_PHY_ADDR;
    phy_config.reset_gpio_num = -1;      /* no reset line on this board */

    eth_esp32_emac_config_t emac_config = ETH_ESP32_EMAC_DEFAULT_CONFIG();
    emac_config.smi_gpio.mdc_num    = CFG_ETH_MDC_GPIO;
    emac_config.smi_gpio.mdio_num   = CFG_ETH_MDIO_GPIO;
    emac_config.clock_config.rmii.clock_mode = EMAC_CLK_EXT_IN;
    emac_config.clock_config.rmii.clock_gpio = 0;   /* 50 MHz fed in on GPIO0 */

    esp_eth_mac_t *mac = esp_eth_mac_new_esp32(&emac_config, &mac_config);
    esp_eth_phy_t *phy = esp_eth_phy_new_lan87xx(&phy_config);
    if (mac == NULL || phy == NULL) {
        ESP_LOGE(TAG, "ethernet MAC/PHY creation failed");
        return ESP_FAIL;
    }

    esp_eth_config_t eth_config = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    esp_err_t err = esp_eth_driver_install(&eth_config, &eth_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_eth_driver_install: %s", esp_err_to_name(err));
        return err;
    }

    /* Fixed MAC so the DHCP server and ARP tables stay stable across reboots. */
    uint8_t eth_mac[6] = { 0x02, 0x00, 0x5e, 0x10, 0x00, 0x01 };
    esp_eth_ioctl(eth_handle, ETH_CMD_S_MAC_ADDR, eth_mac);

    err = esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                     &eth_event_handler, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ethernet event handler: %s", esp_err_to_name(err));
        return err;
    }

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    s_eth_netif = esp_netif_new(&netif_cfg);
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    if (s_eth_netif == NULL || glue == NULL) {
        ESP_LOGE(TAG, "ethernet netif creation failed");
        return ESP_FAIL;
    }
    esp_netif_attach(s_eth_netif, glue);

    /* Static address in the SeaKeeper's own subnet - this is what makes the
     * relayed connections answerable by the unit without any gateway. */
    esp_netif_dhcpc_stop(s_eth_netif);
    esp_netif_ip_info_t ip;
    memset(&ip, 0, sizeof(ip));
    ip.ip.addr      = esp_ip4addr_aton(CFG_ETH_IP);
    ip.netmask.addr = esp_ip4addr_aton(CFG_ETH_NETMASK);
    ip.gw.addr      = 0;
    err = esp_netif_set_ip_info(s_eth_netif, &ip);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ethernet static IP %s failed: %s", CFG_ETH_IP,
                 esp_err_to_name(err));
        return err;
    }
    ESP_LOGI(TAG, "ethernet static IP %s/%s", CFG_ETH_IP, CFG_ETH_NETMASK);

    err = esp_eth_start(eth_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_eth_start: %s", esp_err_to_name(err));
        return err;
    }
    return ESP_OK;
}

/* ------------------------------------------------------------------ */

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    /* Ethernet first so the downlink address exists before the first client
     * arrives over Wi-Fi. Neither init blocks on link. */
    err = eth_init();
    if (err != ESP_OK) {
        /* Without the downlink there is nothing to relay, and every connection
         * would fail silently at the client. Restart rather than sit dead. */
        ESP_LOGE(TAG, "ethernet init failed (%s) - restarting in 5 s",
                 esp_err_to_name(err));
        vTaskDelay(pdMS_TO_TICKS(5000));
        esp_restart();
    }
    wifi_init();

    ESP_LOGI(TAG, "starting relays to " CFG_UPSTREAM_HOST);
    ESP_ERROR_CHECK(relay_start("web",  CFG_PORT_WEB,  CFG_PORT_WEB,
                                CFG_WEB_MAX_CONNS));
    ESP_ERROR_CHECK(relay_start("mqtt", CFG_PORT_MQTT, CFG_PORT_MQTT,
                                CFG_MQTT_MAX_CONNS));

    ESP_LOGI(TAG, "ready: http://%s/  (mqtt ws :%d)", CFG_STA_IP, CFG_PORT_MQTT);
}
