// Host-side test of the plymouth hand-off plugin's tempod client.
//
// Compiles the real plugins/plymouth_handoff.c natively (inside the toolchain
// container, via scripts/test) together with flutter-pi's own platformchannel.c
// for the JSON decoding, stubs the handful of embedder calls the plugin makes,
// and talks to a fake tempod living in a thread. It covers the wire protocol
// and the plugin's decisions - which path it takes, what it does on each reply
// - not the daemon side and not a real boot.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

int fake_system(const char *cmd);
uid_t fake_geteuid(void);
#define system(cmd) fake_system(cmd)
#define geteuid() fake_geteuid()
#include "plymouth_handoff.c"
#undef system
#undef geteuid

// ---- embedder stubs --------------------------------------------------------
struct flutterpi *flutterpi = NULL;
static int test_drm_fd = -1;
static int frames_requested = 0;
static int setmaster_calls = 0;
static char system_log[2048];

struct drmdev *flutterpi_get_drmdev(struct flutterpi *fp) { (void) fp; return (struct drmdev *) 0x1; }
void flutterpi_request_frame(struct flutterpi *fp) { (void) fp; frames_requested++; }
int drmdev_get_fd(struct drmdev *d) { (void) d; return test_drm_fd; }
int drmSetMaster(int fd) { (void) fd; setmaster_calls++; return 0; }
struct plugin_registry *flutterpi_get_plugin_registry(struct flutterpi *fp) { (void) fp; return NULL; }
int plugin_registry_set_receiver_locked(const char *c, enum platch_codec codec, platch_obj_recv_callback cb) { (void) c; (void) codec; (void) cb; return 0; }
int plugin_registry_remove_receiver_v2_locked(struct plugin_registry *r, const char *c) { (void) r; (void) c; return 0; }
void static_plugin_registry_add_plugin(const struct flutterpi_plugin_v2 *p) { (void) p; }
void static_plugin_registry_remove_plugin(const char *name) { (void) name; }
int flutterpi_send_platform_message(struct flutterpi *fp, const char *ch, const uint8_t *restrict m, size_t s, FlutterPlatformMessageResponseHandle *h) { (void) fp; (void) ch; (void) m; (void) s; (void) h; return 0; }
int flutterpi_respond_to_platform_message(const FlutterPlatformMessageResponseHandle *h, const uint8_t *restrict m, size_t s) { (void) h; (void) m; (void) s; return 0; }
FlutterPlatformMessageResponseHandle *flutterpi_create_platform_message_response_handle(struct flutterpi *fp, FlutterDataCallback cb, void *u) { (void) fp; (void) cb; (void) u; return NULL; }
void flutterpi_release_platform_message_response_handle(struct flutterpi *fp, FlutterPlatformMessageResponseHandle *h) { (void) fp; (void) h; }

// The in-process fallback only makes sense as root; the test picks the uid.
static uid_t fake_euid = 0;
uid_t fake_geteuid(void) { return fake_euid; }

int fake_system(const char *cmd) {
    strncat(system_log, cmd, sizeof(system_log) - strlen(system_log) - 2);
    strcat(system_log, "|");
    // "pidof plymouthd" -> 1 means "not running", which ends the quit loop.
    return strstr(cmd, "pidof") ? 1 : 0;
}

// ---- fake tempod ------------------------------------------------------------
struct server {
    const char *path;
    const char *reply;      // NULL: close without answering
    int listen_fd;
    // what it saw
    char request[256];
    int received_fd;
    int fd_matches;
};

static void *server_thread(void *arg) {
    struct server *s = arg;
    int conn = accept(s->listen_fd, NULL, NULL);
    CHECK(conn >= 0);

    char buf[256];
    struct iovec iov = { .iov_base = buf, .iov_len = sizeof buf - 1 };
    union { struct cmsghdr h; char b[CMSG_SPACE(sizeof(int))]; } ctl;
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.b, .msg_controllen = sizeof ctl.b };
    ssize_t n = recvmsg(conn, &msg, 0);
    CHECK(n > 0);
    buf[n] = '\0';
    strncpy(s->request, buf, sizeof s->request - 1);

    s->received_fd = -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            memcpy(&s->received_fd, CMSG_DATA(c), sizeof(int));
        }
    }
    if (s->received_fd >= 0) {
        struct stat a, b;
        CHECK(fstat(s->received_fd, &a) == 0 && fstat(test_drm_fd, &b) == 0);
        s->fd_matches = (a.st_dev == b.st_dev && a.st_ino == b.st_ino);
        close(s->received_fd);
    }
    if (s->reply) {
        CHECK(write(conn, s->reply, strlen(s->reply)) == (ssize_t) strlen(s->reply));
    }
    close(conn);
    return NULL;
}

static void server_start(struct server *s, pthread_t *t) {
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, s->path, sizeof addr.sun_path - 1);
    unlink(s->path);
    s->listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(s->listen_fd >= 0);
    CHECK(bind(s->listen_fd, (struct sockaddr *) &addr, sizeof addr) == 0);
    CHECK(listen(s->listen_fd, 1) == 0);
    CHECK(pthread_create(t, NULL, server_thread, s) == 0);
}

static void server_finish(struct server *s, pthread_t t) {
    pthread_join(t, NULL);
    close(s->listen_fd);
    unlink(s->path);
}


static int run_with_reply(const char *sockpath, const char *reply, struct server *out) {
    struct server s = { .path = sockpath, .reply = reply };
    pthread_t t;
    server_start(&s, &t);
    int r = tempod_handoff(test_drm_fd);
    server_finish(&s, t);
    if (out) *out = s;
    return r;
}

int main(void) {
    const char *sockpath = "/tmp/handoff-test.sock";
    test_drm_fd = open("/dev/null", O_RDWR);
    CHECK(test_drm_fd >= 0);

    // Compile-time default is honoured when the env var is unset/empty.
    unsetenv("TEMPOD_SOCKET");
    CHECK(strcmp(tempod_socket_path(), TEMPOD_SOCKET) == 0);
    setenv("TEMPOD_SOCKET", "", 1);
    CHECK(strcmp(tempod_socket_path(), TEMPOD_SOCKET) == 0);
    setenv("TEMPOD_SOCKET", sockpath, 1);
    CHECK(strcmp(tempod_socket_path(), sockpath) == 0);

    // 1. No socket at all -> unavailable (ENOENT).
    unlink(sockpath);
    CHECK(tempod_handoff(test_drm_fd) == TEMPOD_UNAVAILABLE);

    // 2. Socket file present, nobody listening -> unavailable (ECONNREFUSED).
    {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un addr = { .sun_family = AF_UNIX };
        strncpy(addr.sun_path, sockpath, sizeof addr.sun_path - 1);
        CHECK(bind(fd, (struct sockaddr *) &addr, sizeof addr) == 0);
        close(fd);   // bound but never listened: connect gets ECONNREFUSED
        CHECK(tempod_handoff(test_drm_fd) == TEMPOD_UNAVAILABLE);
        unlink(sockpath);
    }

    // 3. Happy path: request line + fd arrive together, {"ok":true} -> done.
    struct server seen;
    CHECK(run_with_reply(sockpath, "{\"ok\":true}\n", &seen) == TEMPOD_DONE);
    CHECK(strcmp(seen.request, "{\"op\":\"drm-handoff\"}\n") == 0);
    CHECK(seen.received_fd >= 0 && seen.fd_matches);

    // 4. Reply with whitespace and no trailing newline, then close -> done.
    CHECK(run_with_reply(sockpath, "{ \"ok\" : true }", NULL) == TEMPOD_DONE);

    // 5. Refusal carries the error string -> failed.
    CHECK(run_with_reply(sockpath, "{\"ok\":false,\"error\":\"plymouth still master\"}\n", NULL) == TEMPOD_FAILED);

    // 6. Garbage, non-object, and a silent close -> failed.
    CHECK(run_with_reply(sockpath, "nonsense\n", NULL) == TEMPOD_FAILED);
    CHECK(run_with_reply(sockpath, "[1,2]\n", NULL) == TEMPOD_FAILED);
    CHECK(run_with_reply(sockpath, "{\"ok\":\"yes\"}\n", NULL) == TEMPOD_FAILED);
    CHECK(run_with_reply(sockpath, NULL, NULL) == TEMPOD_FAILED);

    // 7. The whole thread body, tempod present: one frame requested, no
    //    plymouth commands, no drmSetMaster from us.
    {
        struct server s = { .path = sockpath, .reply = "{\"ok\":true}\n" };
        pthread_t t;
        frames_requested = 0; setmaster_calls = 0; system_log[0] = '\0';
        server_start(&s, &t);
        handoff_thread(NULL);
        server_finish(&s, t);
        CHECK(frames_requested == 1);
        CHECK(setmaster_calls == 0);
        CHECK(system_log[0] == '\0');
    }

    // 8. The whole thread body, no tempod: the in-process path runs with the
    //    tempo-handoff status, deactivate, drmSetMaster, a frame, and quit.
    {
        frames_requested = 0; setmaster_calls = 0; system_log[0] = '\0';
        unlink(sockpath);
        handoff_thread(NULL);
        CHECK(strcmp(system_log,
                     "plymouth update --status=tempo-handoff|"
                     "plymouth deactivate|"
                     "pidof plymouthd >/dev/null 2>&1|") == 0);
        CHECK(setmaster_calls == 1);
        CHECK(frames_requested == 1);
    }

    // 9. tempod refuses -> still falls through to the in-process attempt.
    {
        struct server s = { .path = sockpath, .reply = "{\"ok\":false,\"error\":\"nope\"}\n" };
        pthread_t t;
        frames_requested = 0; setmaster_calls = 0; system_log[0] = '\0';
        server_start(&s, &t);
        handoff_thread(NULL);
        server_finish(&s, t);
        CHECK(strstr(system_log, "plymouth update --status=tempo-handoff|") == system_log);
        CHECK(setmaster_calls == 1);
        CHECK(frames_requested == 1);
    }

    // 10. Unprivileged and no tempod: nothing to be gained from the
    //     in-process path - no plymouth commands, no drmSetMaster, one frame
    //     so the bounced commit is visible in the log.
    {
        fake_euid = 1000;
        frames_requested = 0; setmaster_calls = 0; system_log[0] = '\0';
        unlink(sockpath);
        handoff_thread(NULL);
        CHECK(system_log[0] == '\0');
        CHECK(setmaster_calls == 0);
        CHECK(frames_requested == 1);
        fake_euid = 0;
    }

    puts("all handoff client tests passed");
    return 0;
}
