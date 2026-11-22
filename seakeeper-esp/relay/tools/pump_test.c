/* Host-side test for the relay pump's buffer-boundary behaviour.
 *
 * Compiles relay.c against POSIX sockets (see /tmp/stubs) and pushes more data
 * through pump() than fits in one buffer, deliberately landing on the exact
 * boundary that used to wedge the connection: a full buffer that has been
 * fully sent (len == off == RELAY_BUF_SIZE).
 *
 *   clang -o /tmp/pump_test -I<stubs> -Isrc tools/pump_test.c src/relay.c -lpthread
 *   /tmp/pump_test
 *
 * Not built by PlatformIO; it never ships on the board.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/time.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

int pump(int a, int b, const char *name);

/* ---------------- FreeRTOS stand-ins ---------------- */
static TickType_t s_ticks = 0;

TickType_t xTaskGetTickCount(void) { return ++s_ticks; }
BaseType_t xTaskCreate(TaskFunction_t fn, const char *n, uint32_t s, void *a,
                       UBaseType_t p, TaskHandle_t *h)
{ (void)fn; (void)n; (void)s; (void)a; (void)p; (void)h; return pdFAIL; }
void vTaskDelete(TaskHandle_t t) { (void)t; }
void vTaskDelay(TickType_t t) { (void)t; }
SemaphoreHandle_t xSemaphoreCreateCounting(UBaseType_t m, UBaseType_t i)
{ (void)m; (void)i; return (SemaphoreHandle_t)1; }
BaseType_t xSemaphoreTake(SemaphoreHandle_t s, TickType_t t) { (void)s; (void)t; return pdTRUE; }
BaseType_t xSemaphoreGive(SemaphoreHandle_t s) { (void)s; return pdTRUE; }
void vSemaphoreDelete(SemaphoreHandle_t s) { (void)s; }

/* ---------------- test ---------------- */
#define TOTAL     46000
#define FIRST_GAP 1024      /* exactly one buffer, then a pause */

static int px_a = -1, px_b = -1, client_fd = -1, server_fd = -1;
static int pump_ret = 99;

static long now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000L + tv.tv_usec / 1000;
}

static void set_nonblocking(int fd)
{
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

static unsigned char pattern(size_t i) { return (unsigned char)((i * 31u) & 0xFF); }

static void *pump_thread(void *arg)
{
    (void)arg;
    pump_ret = pump(px_a, px_b, "test");
    return NULL;
}

static void *writer_thread(void *arg)
{
    (void)arg;
    unsigned char buf[4096];
    size_t sent = 0;
    long deadline = now_ms() + 8000;
    int first = 1;

    while (sent < TOTAL) {
        size_t chunk = TOTAL - sent;
        if (first && chunk > FIRST_GAP) chunk = FIRST_GAP;
        if (chunk > sizeof(buf)) chunk = sizeof(buf);

        size_t i;
        for (i = 0; i < chunk; i++) buf[i] = pattern(sent + i);

        ssize_t n = write(server_fd, buf, chunk);
        if (n > 0) {
            sent += (size_t)n;
            if (first) { first = 0; usleep(200000); }  /* let the pump drain it */
        } else if (!(n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            printf("writer error: %s\n", strerror(errno));
            break;
        } else {
            usleep(1000);
        }
        if (now_ms() > deadline) { printf("writer stalled at %zu\n", sent); break; }
    }
    shutdown(server_fd, SHUT_WR);
    return NULL;
}

int main(void)
{
    int sp1[2], sp2[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sp1) || socketpair(AF_UNIX, SOCK_STREAM, 0, sp2)) {
        perror("socketpair");
        return 2;
    }
    client_fd = sp1[0]; px_a = sp1[1];
    px_b = sp2[0];  server_fd = sp2[1];

    set_nonblocking(px_a);
    set_nonblocking(px_b);
    set_nonblocking(client_fd);   /* so the reader loop can honour its deadline */
    set_nonblocking(server_fd);   /* so the writer can honour its deadline */

    pthread_t pt, wt;
    pthread_create(&pt, NULL, pump_thread, NULL);
    pthread_create(&wt, NULL, writer_thread, NULL);

    unsigned char buf[4096];
    size_t got = 0;
    int corrupt = 0;
    long deadline = now_ms() + 8000;

    for (;;) {
        ssize_t n = read(client_fd, buf, sizeof(buf));
        if (n > 0) {
            size_t i;
            for (i = 0; i < (size_t)n; i++) {
                if (buf[i] != pattern(got + i)) corrupt++;
            }
            got += (size_t)n;
            if (got >= TOTAL) break;
        } else if (n == 0) {
            break;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            printf("reader error: %s\n", strerror(errno));
            break;
        } else {
            usleep(1000);
        }
        if (now_ms() > deadline) break;
    }

    /* The pump task only returns once both directions have closed, which is not
     * the point of this test: stop the client side, give it a moment, and
     * report. Threads are torn down with the process. */
    shutdown(client_fd, SHUT_WR);
    usleep(200000);

    printf("received %zu of %d bytes, %d corrupt, pump()=%d\n",
           got, TOTAL, corrupt, pump_ret);

    int ok = (got == TOTAL) && (corrupt == 0);
    printf("%s\n", ok ? "PASS" : "FAIL");
    exit(ok ? 0 : 1);
}
