/* TCP relay implementation.
 *
 * One listener task per port. Each accepted connection gets its own task which
 * connects upstream (sourced from the Ethernet interface, because that is the
 * route to the upstream) and then pumps bytes both ways with select().
 *
 * Sockets are non-blocking; buffers are per direction and compacted as data is
 * forwarded. Half-close is propagated so HTTP and WebSocket teardown behave.
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

#include "relay.h"

static const char *TAG = "relay";

#define RELAY_MAX_CONNS      6      /* concurrent connections, all ports */
#define RELAY_BUF_SIZE       1024   /* per direction, per connection */
#define RELAY_CONNECT_MS     5000   /* upstream connect timeout */
#define RELAY_LISTEN_STACK   4096
#define RELAY_TASK_STACK     6144   /* holds 2 x RELAY_BUF_SIZE of buffers */
#define RELAY_TASK_PRIO      5
#define RELAY_MAX_LISTENERS  4

typedef struct {
    int      client_fd;
    int      upstream_fd;
    char     name[16];
    char     host[32];
    uint16_t port;
} relay_job_t;

typedef struct {
    char     name[16];
    char     host[32];
    uint16_t listen_port;
    uint16_t target_port;
} listener_cfg_t;

static listener_cfg_t    s_cfg[RELAY_MAX_LISTENERS];
static int               s_cfg_n = 0;
static SemaphoreHandle_t s_slots = NULL;

static void set_nonblocking(int fd)
{
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) {
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }
}

/* Non-blocking connect with a bound wait, so a missing SeaKeeper cannot stall
 * the listener. Returns 0 on success. */
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

/* Pumps until both directions are finished or an error occurs.
 * Returns 0 on clean close, -1 on error. */
static int pump(int a, int b)
{
    pump_buf_t ab;  /* data read from a, to be written to b */
    pump_buf_t ba;  /* data read from b, to be written to a */
    bool a_eof = false, b_eof = false;
    bool a_wr_shut = false, b_wr_shut = false;

    memset(&ab, 0, sizeof(ab));
    memset(&ba, 0, sizeof(ba));

    for (;;) {
        /* Propagate half-close once the matching buffer is drained. */
        if (a_eof && ab.len == ab.off && !b_wr_shut) {
            shutdown(b, SHUT_WR);
            b_wr_shut = true;
        }
        if (b_eof && ba.len == ba.off && !a_wr_shut) {
            shutdown(a, SHUT_WR);
            a_wr_shut = true;
        }
        if (a_eof && b_eof) {
            return 0;
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
            continue;   /* idle tick; keeps the loop responsive */
        }

        /* a -> b */
        if (!a_eof && FD_ISSET(a, &rf)) {
            pump_buf_compact(&ab);
            int n = recv(a, ab.buf + ab.len, RELAY_BUF_SIZE - ab.len, 0);
            if (n > 0) {
                ab.len += (size_t)n;
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
            } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                return -1;
            }
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
    dst.sin_port   = htons(job->port);
    if (inet_pton(AF_INET, job->host, &dst.sin_addr) != 1) {
        ESP_LOGE(TAG, "%s: bad upstream address '%s'", job->name, job->host);
        goto done;
    }

    up = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (up < 0) {
        ESP_LOGE(TAG, "%s: socket() failed: errno %d", job->name, errno);
        goto done;
    }
    int one = 1;
    setsockopt(up, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    if (connect_timeout(up, &dst, RELAY_CONNECT_MS) != 0) {
        ESP_LOGW(TAG, "%s: upstream %s:%u unreachable", job->name, job->host, job->port);
        goto done;
    }

    ESP_LOGI(TAG, "%s: relaying client fd %d -> %s:%u", job->name, job->client_fd,
             job->host, job->port);

    set_nonblocking(job->client_fd);
    pump(job->client_fd, up);

done:
    if (up >= 0) {
        close(up);
    }
    if (job->client_fd >= 0) {
        close(job->client_fd);
    }
    if (s_slots) {
        xSemaphoreGive(s_slots);
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

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family      = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port        = htons(cfg->listen_port);

        if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            ESP_LOGE(TAG, "%s: bind port %u failed: errno %d", cfg->name,
                     cfg->listen_port, errno);
            close(ls);
            vTaskDelay(pdMS_TO_TICKS(5000));
            continue;
        }
        if (listen(ls, 4) != 0) {
            ESP_LOGE(TAG, "%s: listen failed: errno %d", cfg->name, errno);
            close(ls);
            vTaskDelay(pdMS_TO_TICKS(5000));
            continue;
        }

        ESP_LOGI(TAG, "%s: listening on port %u -> %s:%u", cfg->name,
                 cfg->listen_port, cfg->host, cfg->target_port);

        for (;;) {
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int c = accept(ls, (struct sockaddr *)&peer, &plen);
            if (c < 0) {
                if (errno == EINTR) {
                    continue;
                }
                ESP_LOGW(TAG, "%s: accept failed: errno %d", cfg->name, errno);
                vTaskDelay(pdMS_TO_TICKS(200));
                continue;
            }

            if (xSemaphoreTake(s_slots, 0) != pdTRUE) {
                ESP_LOGW(TAG, "%s: connection limit reached, refusing", cfg->name);
                close(c);
                continue;
            }

            relay_job_t *job = calloc(1, sizeof(*job));
            if (job == NULL) {
                close(c);
                xSemaphoreGive(s_slots);
                continue;
            }
            job->client_fd   = c;
            job->upstream_fd = -1;
            job->port        = cfg->target_port;
            strlcpy(job->name, cfg->name, sizeof(job->name));
            strlcpy(job->host, cfg->host, sizeof(job->host));

            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

            if (xTaskCreate(relay_task, cfg->name, RELAY_TASK_STACK, job,
                            RELAY_TASK_PRIO, NULL) != pdPASS) {
                ESP_LOGE(TAG, "%s: out of tasks", cfg->name);
                close(c);
                xSemaphoreGive(s_slots);
                free(job);
            }
        }
    }
}

esp_err_t relay_start(const char *name, uint16_t listen_port,
                      const char *target_host, uint16_t target_port)
{
    if (s_cfg_n >= RELAY_MAX_LISTENERS) {
        return ESP_ERR_NO_MEM;
    }
    if (s_slots == NULL) {
        s_slots = xSemaphoreCreateCounting(RELAY_MAX_CONNS, RELAY_MAX_CONNS);
        if (s_slots == NULL) {
            return ESP_ERR_NO_MEM;
        }
    }

    listener_cfg_t *cfg = &s_cfg[s_cfg_n];
    strlcpy(cfg->name, name, sizeof(cfg->name));
    strlcpy(cfg->host, target_host, sizeof(cfg->host));
    cfg->listen_port = listen_port;
    cfg->target_port = target_port;

    if (xTaskCreate(listener_task, name, RELAY_LISTEN_STACK, cfg,
                    RELAY_TASK_PRIO, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    s_cfg_n++;
    return ESP_OK;
}
