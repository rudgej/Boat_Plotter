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

    esp_netif_dns_info_t dns;
    memset(&dns, 0, sizeof(dns));
    dns.ip.type = ESP_IPADDR_TYPE_V4;
    dns.ip.u_addr.ip4.addr = esp_ip4addr_aton(CFG_STA_DNS);
    esp_netif_set_dns_info(s_sta_netif, ESP_NETIF_DNS_MAIN, &dns);

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
        ESP_LOGW(TAG, "wifi disconnected (reason %d), retrying", d ? d->reason : -1);
        vTaskDelay(pdMS_TO_TICKS(1000));
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *)data;
        ESP_LOGI(TAG, "wifi up: " IPSTR, IP2STR(&e->ip_info.ip));
    }
}

static void wifi_init(void)
{
    s_sta_netif = esp_netif_create_default_wifi_sta();
    wifi_apply_static_ip();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                               &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               &wifi_event_handler, NULL));

    wifi_config_t wc;
    memset(&wc, 0, sizeof(wc));
    strlcpy((char *)wc.sta.ssid, CFG_WIFI_SSID, sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, CFG_WIFI_PASSWORD, sizeof(wc.sta.password));
    wc.sta.threshold.authmode = wifi_has_password() ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "wifi started, joining \"%s\"", CFG_WIFI_SSID);
}

/* ------------------------------------------------------------------ */
/* Ethernet (WT32-ETH01, LAN8720)                                      */
/* ------------------------------------------------------------------ */

static void eth_init(void)
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
        return;
    }

    esp_eth_config_t eth_config = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    esp_err_t err = esp_eth_driver_install(&eth_config, &eth_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_eth_driver_install: %s", esp_err_to_name(err));
        return;
    }

    /* Fixed MAC so the DHCP server and ARP tables stay stable across reboots. */
    uint8_t eth_mac[6] = { 0x02, 0x00, 0x5e, 0x10, 0x00, 0x01 };
    esp_eth_ioctl(eth_handle, ETH_CMD_S_MAC_ADDR, eth_mac);

    s_eth_netif = esp_netif_new(ESP_NETIF_DEFAULT_ETH());
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    if (s_eth_netif == NULL || glue == NULL) {
        ESP_LOGE(TAG, "ethernet netif creation failed");
        return;
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
    } else {
        ESP_LOGI(TAG, "ethernet static IP %s/%s", CFG_ETH_IP, CFG_ETH_NETMASK);
    }

    err = esp_eth_start(eth_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_eth_start: %s", esp_err_to_name(err));
    }
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
    eth_init();
    wifi_init();

    ESP_LOGI(TAG, "starting relays to %s", CFG_UPSTREAM_HOST);
    ESP_ERROR_CHECK(relay_start("web",  CFG_PORT_WEB,  CFG_UPSTREAM_HOST, 80));
    ESP_ERROR_CHECK(relay_start("mqtt", CFG_PORT_MQTT, CFG_UPSTREAM_HOST, 9001));

    ESP_LOGI(TAG, "ready: http://%s/  (mqtt ws :%d)", CFG_STA_IP, CFG_PORT_MQTT);
}
