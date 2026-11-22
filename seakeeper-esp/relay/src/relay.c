/* TCP relay: BoatNetwork in, SeaKeeper out.
 *
 * Not a router and not a general-purpose component. Listeners bind only to the
 * BoatNetwork address, so nothing is reachable from the Ethernet side, and
 * every upstream connection is bound to the Ethernet address so the unit
 * always sees 192.168.0.254 - the one address in its own /24 that it can
 * answer without a gateway.
 *
 * One listener task per port; each accepted connection gets a task that pumps
 * bytes both ways with select(). Sockets are non-blocking, buffers are per
 * direction, and half-close is propagated once the matching buffer is drained.
 */

#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <stdbool.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_err.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"

#include "board_config.h"
#include "relay.h"

static const char *TAG = "relay";

#define RELAY_BUF_SIZE       1024   /* per direction, per connection */
#define RELAY_CONNECT_MS     5000   /* upstream connect timeout */
#define RELAY_IDLE_MS        600000 /* drop a connection with no traffic at all */
#define RELAY_LISTEN_STACK   4096
#define RELAY_TASK_STACK     6144   /* holds 2 x RELAY_BUF_SIZE of buffers */
#define RELAY_TASK_PRIO      5
#define RELAY_MAX_LISTENERS  2

typedef struct {
    int      client_fd;
    const char *name;           /* points into s_cfg, which is static */
    uint16_t upstream_port;
    SemaphoreHandle_t slots;    /* this listener's own counter */
} relay_job_t;

typedef struct {
    const char       *name;
    uint16_t          listen_port;
    uint16_t          upstream_port;
    uint8_t           max_conns;
    SemaphoreHandle_t slots;
} listener_cfg_t;

static listener_cfg_t s_cfg[RELAY_MAX_LISTENERS];
static int            s_cfg_n = 0;

static void set_nonblocking(int fd)
{
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) {
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }
}

/* lwIP's default keepalive idle is two hours, which is longer than the relay's
 * own idle timeout and therefore useless on its own. Tune it so a link that
 * silently died is detected in about 90 s. */
static void set_keepalive(int fd)
{
    int one = 1;
    int idle = 60, intvl = 10, cnt = 3;

    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
}

/* Binds to a fixed local address. Used for both directions: the listener so it
 * is only reachable from BoatNetwork, and the upstream socket so the SeaKeeper
 * sees a reply address it can reach. */
static int bind_to(int fd, const char *ip, uint16_t port)
{
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port   = htons(port);
    if (inet_pton(AF_INET, ip, &a.sin_addr) != 1) {
        errno = EINVAL;
        return -1;
    }
    return bind(fd, (struct sockaddr *)&a, sizeof(a));
}

/* Non-blocking connect with a bounded wait, so a missing SeaKeeper cannot stall
 * the connection task. Returns 0 on success. */
static int connect_timeout(int fd, const struct sockaddr_in *dst, int timeout_ms)
{
    set_nonblocking(fd);

    int r = connect(fd, (const struct sockaddr *)dst, sizeof(*dst));
    if (r == 0) {
        return 0;
    }
    if (errno != EINPROGRESS) {
        return -1;
    }

    fd_set wf;
    FD_ZERO(&wf);
    FD_SET(fd, &wf);
    struct timeval tv;
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    r = select(fd + 1, NULL, &wf, NULL, &tv);
    if (r <= 0) {
        return -1;
    }

    int so_err = 0;
    socklen_t slen = sizeof(so_err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &slen) < 0) {
        return -1;
    }
    return so_err == 0 ? 0 : -1;
}

typedef struct {
    uint8_t buf[RELAY_BUF_SIZE];
    size_t  len;    /* bytes valid in buf */
    size_t  off;    /* bytes already written out */
} pump_buf_t;

static void pump_buf_compact(pump_buf_t *b)
{
    if (b->off > 0) {
        if (b->off == b->len) {
            b->len = 0;
            b->off = 0;
        } else {
            memmove(b->buf, b->buf + b->off, b->len - b->off);
            b->len -= b->off;
            b->off = 0;
        }
    }
}

/* Pumps until the connection is finished, fails, or goes idle.
 * Returns 0 on clean close, -1 on error or timeout. */
static int pump(int a, int b, const char *name)
{
    pump_buf_t ab;  /* read from a, to be written to b */
    pump_buf_t ba;  /* read from b, to be written to a */
    bool a_eof = false, b_eof = false;
    bool a_wr_shut = false, b_wr_shut = false;
    TickType_t last = xTaskGetTickCount();

    memset(&ab, 0, sizeof(ab));
    memset(&ba, 0, sizeof(ba));

    for (;;) {
        /* Finished only when both peers have closed AND everything already
         * read has been written out. Closing on the EOFs alone would truncate
         * a response that arrives just before the upstream closes. */
        if (a_eof && b_eof && ab.len == ab.off && ba.len == ba.off) {
            return 0;
        }

        /* Without this, a peer that opens a connection and then goes quiet
         * holds one of this listener's slots until reboot. */
        if ((TickType_t)(xTaskGetTickCount() - last) > pdMS_TO_TICKS(RELAY_IDLE_MS)) {
            ESP_LOGW(TAG, "%s: idle for %d ms, closing", name, RELAY_IDLE_MS);
            return -1;
        }

        /* Propagate half-close once the matching buffer is drained. */
        if (a_eof && ab.len == ab.off && !b_wr_shut) {
            shutdown(b, SHUT_WR);
            b_wr_shut = true;
        }
        if (b_eof && ba.len == ba.off && !a_wr_shut) {
            shutdown(a, SHUT_WR);
            a_wr_shut = true;
        }

        fd_set rf, wf;
        FD_ZERO(&rf);
        FD_ZERO(&wf);
        int maxfd = -1;

        if (!a_eof && ab.len < RELAY_BUF_SIZE) {
            FD_SET(a, &rf);
            if (a > maxfd) maxfd = a;
        }
        if (ab.len > ab.off) {
            FD_SET(b, &wf);
            if (b > maxfd) maxfd = b;
        }
        if (!b_eof && ba.len < RELAY_BUF_SIZE) {
            FD_SET(b, &rf);
            if (b > maxfd) maxfd = b;
        }
        if (ba.len > ba.off) {
            FD_SET(a, &wf);
            if (a > maxfd) maxfd = a;
        }

        if (maxfd < 0) {
            return 0;   /* nothing left to wait for */
        }

        struct timeval tv;
        tv.tv_sec  = 1;
        tv.tv_usec = 0;

        int r = select(maxfd + 1, &rf, &wf, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (r == 0) {
            continue;   /* idle tick; the timeout is checked at loop top */
        }

        bool progress = false;

        /* a -> b */
        if (!a_eof && FD_ISSET(a, &rf)) {
            pump_buf_compact(&ab);
            int n = recv(a, ab.buf + ab.len, RELAY_BUF_SIZE - ab.len, 0);
            if (n > 0) {
                ab.len += (size_t)n;
                progress = true;
            } else if (n == 0) {
                a_eof = true;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                return -1;
            }
        }
        if (FD_ISSET(b, &wf) && ab.len > ab.off) {
            int n = send(b, ab.buf + ab.off, ab.len - ab.off, 0);
            if (n > 0) {
                ab.off += (size_t)n;
                progress = true;
            } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                return -1;
            }
        }

        /* b -> a */
        if (!b_eof && FD_ISSET(b, &rf)) {
            pump_buf_compact(&ba);
            int n = recv(b, ba.buf + ba.len, RELAY_BUF_SIZE - ba.len, 0);
            if (n > 0) {
                ba.len += (size_t)n;
                progress = true;
            } else if (n == 0) {
                b_eof = true;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                return -1;
            }
        }
        if (FD_ISSET(a, &wf) && ba.len > ba.off) {
            int n = send(a, ba.buf + ba.off, ba.len - ba.off, 0);
            if (n > 0) {
                ba.off += (size_t)n;
                progress = true;
            } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                return -1;
            }
        }

        if (progress) {
            last = xTaskGetTickCount();
        }
    }
}

static void relay_task(void *arg)
{
    relay_job_t *job = (relay_job_t *)arg;
    int up = -1;

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port   = htons(job->upstream_port);
    if (inet_pton(AF_INET, CFG_UPSTREAM_HOST, &dst.sin_addr) != 1) {
        ESP_LOGE(TAG, "%s: bad upstream address '%s'", job->name, CFG_UPSTREAM_HOST);
        goto done;
    }

    up = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (up < 0) {
        ESP_LOGE(TAG, "%s: socket() failed: errno %d", job->name, errno);
        goto done;
    }

    int one = 1;
    setsockopt(up, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    set_keepalive(up);

    /* Source the connection from the Ethernet address. Without this the source
     * address depends on lwIP's route choice, and the SeaKeeper would be asked
     * to reply to an address it cannot reach. */
    if (bind_to(up, CFG_ETH_IP, 0) != 0) {
        ESP_LOGE(TAG, "%s: cannot bind source %s: errno %d", job->name,
                 CFG_ETH_IP, errno);
        goto done;
    }

    if (connect_timeout(up, &dst, RELAY_CONNECT_MS) != 0) {
        ESP_LOGW(TAG, "%s: upstream " CFG_UPSTREAM_HOST ":%u unreachable",
                 job->name, job->upstream_port);
        goto done;
    }

    ESP_LOGI(TAG, "%s: relaying client fd %d -> " CFG_UPSTREAM_HOST ":%u",
             job->name, job->client_fd, job->upstream_port);

    set_nonblocking(job->client_fd);
    pump(job->client_fd, up, job->name);

done:
    if (up >= 0) {
        close(up);
    }
    if (job->client_fd >= 0) {
        close(job->client_fd);
    }
    if (job->slots != NULL) {
        xSemaphoreGive(job->slots);
    }
    free(job);
    vTaskDelete(NULL);
}

static void listener_task(void *arg)
{
    const listener_cfg_t *cfg = (const listener_cfg_t *)arg;

    for (;;) {
        int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (ls < 0) {
            ESP_LOGE(TAG, "%s: socket() failed: errno %d", cfg->name, errno);
            vTaskDelay(pdMS_TO_TICKS(5000));
            continue;
        }

        int one = 1;
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        /* BoatNetwork only: the Ethernet side must not expose these ports, so
         * this is deliberately not INADDR_ANY. Expect failures until Wi-Fi is
         * up, hence a warning and a retry rather than an error. */
        if (bind_to(ls, CFG_STA_IP, cfg->listen_port) != 0) {
            ESP_LOGW(TAG, "%s: bind " CFG_STA_IP ":%u failed: errno %d (waiting for Wi-Fi)",
                     cfg->name, cfg->listen_port, errno);
            close(ls);
            vTaskDelay(pdMS_TO_TICKS(2000));
            continue;
        }
        if (listen(ls, 4) != 0) {
            ESP_LOGE(TAG, "%s: listen failed: errno %d", cfg->name, errno);
            close(ls);
            vTaskDelay(pdMS_TO_TICKS(5000));
            continue;
        }

        ESP_LOGI(TAG, "%s: " CFG_STA_IP ":%u -> " CFG_UPSTREAM_HOST ":%u",
                 cfg->name, cfg->listen_port, cfg->upstream_port);

        int accept_fails = 0;
        for (;;) {
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int c = accept(ls, (struct sockaddr *)&peer, &plen);
            if (c < 0) {
                if (errno == EINTR) {
                    continue;
                }
                /* The interface can come back with the listening socket left
                 * unusable. Recreate it rather than retrying a dead handle. */
                if (++accept_fails >= 3) {
                    ESP_LOGW(TAG, "%s: accept keeps failing (errno %d), reopening listener",
                             cfg->name, errno);
                    close(ls);
                    break;
                }
                ESP_LOGW(TAG, "%s: accept failed: errno %d", cfg->name, errno);
                vTaskDelay(pdMS_TO_TICKS(200));
                continue;
            }
            accept_fails = 0;

            if (xSemaphoreTake(cfg->slots, 0) != pdTRUE) {
                ESP_LOGW(TAG, "%s: all %u slots in use, refusing", cfg->name,
                         cfg->max_conns);
                close(c);
                continue;
            }

            relay_job_t *job = calloc(1, sizeof(*job));
            if (job == NULL) {
                close(c);
                xSemaphoreGive(cfg->slots);
                continue;
            }
            job->client_fd     = c;
            job->name          = cfg->name;
            job->upstream_port = cfg->upstream_port;
            job->slots         = cfg->slots;

            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            set_keepalive(c);

            if (xTaskCreate(relay_task, cfg->name, RELAY_TASK_STACK, job,
                            RELAY_TASK_PRIO, NULL) != pdPASS) {
                ESP_LOGE(TAG, "%s: out of tasks", cfg->name);
                close(c);
                xSemaphoreGive(cfg->slots);
                free(job);
            }
        }
    }
}

esp_err_t relay_start(const char *name, uint16_t listen_port, uint16_t upstream_port,
                      uint8_t max_conns)
{
    if (s_cfg_n >= RELAY_MAX_LISTENERS || max_conns == 0) {
        return ESP_ERR_NO_MEM;
    }

    listener_cfg_t *cfg = &s_cfg[s_cfg_n];
    cfg->slots = xSemaphoreCreateCounting(max_conns, max_conns);
    if (cfg->slots == NULL) {
        return ESP_ERR_NO_MEM;
    }

    cfg->name          = name;
    cfg->listen_port   = listen_port;
    cfg->upstream_port = upstream_port;
    cfg->max_conns     = max_conns;

    if (xTaskCreate(listener_task, name, RELAY_LISTEN_STACK, cfg,
                    RELAY_TASK_PRIO, NULL) != pdPASS) {
        vSemaphoreDelete(cfg->slots);
        cfg->slots = NULL;
        return ESP_ERR_NO_MEM;
    }
    s_cfg_n++;
    return ESP_OK;
}
