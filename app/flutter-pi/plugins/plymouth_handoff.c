// SPDX-License-Identifier: MIT
//
// plymouth_handoff - hand the display from the plymouth boot splash to
// flutter-pi with no gap between them.
//
// flutter-pi, started while plymouth still holds the DRM master, initializes
// and renders its first frame but cannot commit it (its drmdev is "paused" -
// it is not the master), so it waits. Meanwhile plymouth keeps animating. When
// the Dart side signals that the first frame is ready (the accompanying
// package's PlymouthHandoff.armOnFirstFrame), this plugin has the splash fade
// out, plymouth's master dropped, flutter-pi's fd made master, and the commit
// forced - so the swirl gives way to the app exactly at the first frame, never
// a frozen splash during startup.
//
// On the device the frontend runs unprivileged (uid 1000), and drmSetMaster on
// an fd that has never been master is refused without CAP_SYS_ADMIN. So the
// privileged half of the dance lives in tempod, the root daemon: this plugin
// connects to its socket, sends the request line {"op":"drm-handoff"} with the
// DRM fd attached as SCM_RIGHTS, and tempod fades the splash, deactivates
// plymouth, sets master on the fd it received (same open file description, so
// flutter-pi's fd becomes master too), and answers one line, {"ok":true} or
// {"ok":false,"error":"..."}. tempod retires plymouthd afterwards on its own,
// once it sees our first frame reach the CRTC (quitting earlier would blank
// the panel: plymouth's framebuffer teardown disables the plane).
// When tempod is not there (no socket, nobody listening, no permission), the
// plugin falls back to doing all of it in-process, which still works whenever
// flutter-pi happens to run as root.
//
// Requires two small embedder accessors (flutterpi_get_drmdev,
// flutterpi_request_frame); see app/flutter-pi/patches/0002.

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <xf86drm.h>

#include "flutter-pi.h"
#include "modesetting.h"
#include "platformchannel.h"
#include "pluginregistry.h"
#include "util/logging.h"

#define PLYMOUTH_HANDOFF_CHANNEL "flutter_pi/plymouth_handoff"

// The tempod socket. The build bakes in config.yaml's daemon.socket
// (-DTEMPOD_SOCKET=..., see app/flutter-pi/scripts/build); the TEMPOD_SOCKET
// environment variable overrides it at runtime.
#ifndef TEMPOD_SOCKET
    #define TEMPOD_SOCKET "/run/tempod/tempod.sock"
#endif

#define TEMPOD_REQUEST "{\"op\":\"drm-handoff\"}\n"

// The whole hand-off on the daemon side is a fade, a deactivate and a few
// retries - seconds at most. Past this, assume tempod is wedged and fall back.
#define TEMPOD_TIMEOUT_SEC 10
#define TEMPOD_REPLY_MAX 1024

// The theme fades over ~0.5s (RING_FADE_OUT_SECONDS); wait a touch past that.
#define FADE_US (600 * 1000)

static struct flutterpi *g_flutterpi = NULL;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

enum tempod_outcome {
    // tempod did the hand-off; flutter-pi's fd is DRM master now.
    TEMPOD_DONE,
    // No daemon to talk to (socket missing, nobody listening, no permission).
    TEMPOD_UNAVAILABLE,
    // Reached the daemon, but the hand-off did not happen.
    TEMPOD_FAILED,
};

static const char *tempod_socket_path(void) {
    const char *env = getenv("TEMPOD_SOCKET");
    return (env != NULL && env[0] != '\0') ? env : TEMPOD_SOCKET;
}

static int tempod_connect(const char *path) {
    struct sockaddr_un addr;
    struct timeval timeout = { .tv_sec = TEMPOD_TIMEOUT_SEC, .tv_usec = 0 };
    int fd, saved;

    if (strlen(path) >= sizeof(addr.sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }

    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return -1;
    }

    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *) &addr, sizeof addr) != 0) {
        saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }

    // A wedged daemon must not hang the hand-off forever.
    (void) setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    (void) setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    return fd;
}

// Send the request line with the DRM fd riding along as SCM_RIGHTS on the
// same sendmsg, as the protocol requires.
static int tempod_send_request(int sock, int drm_fd) {
    const char *request = TEMPOD_REQUEST;
    size_t total = strlen(request), sent;
    struct iovec iov = { .iov_base = (void *) request, .iov_len = total };
    union {
        struct cmsghdr align;
        char buf[CMSG_SPACE(sizeof(int))];
    } control;
    struct msghdr msg;
    struct cmsghdr *cmsg;
    ssize_t n;

    memset(&control, 0, sizeof control);
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.buf;
    msg.msg_controllen = sizeof control.buf;

    cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &drm_fd, sizeof(int));

    do {
        n = sendmsg(sock, &msg, MSG_NOSIGNAL);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
        return -1;
    }

    // The fd went with the first bytes; finish the line if it was cut short.
    for (sent = (size_t) n; sent < total;) {
        n = send(sock, request + sent, total - sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        sent += (size_t) n;
    }
    return 0;
}

// Read tempod's one reply line into buf (NUL-terminated, newline stripped).
static int tempod_read_reply(int sock, char *buf, size_t size) {
    size_t len = 0;
    char *newline;
    ssize_t n;

    while (len + 1 < size) {
        n = recv(sock, buf + len, size - 1 - len, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            break;
        }
        len += (size_t) n;
        newline = memchr(buf, '\n', len);
        if (newline != NULL) {
            *newline = '\0';
            return 0;
        }
    }

    buf[len] = '\0';
    if (len == 0) {
        errno = ECONNRESET;
        return -1;
    }
    return 0;
}

// {"ok":true} or {"ok":false,"error":"..."}. Anything else is a failure.
static enum tempod_outcome tempod_parse_reply(const char *line) {
    struct platch_obj obj;
    struct json_value *value;
    enum tempod_outcome outcome = TEMPOD_FAILED;
    int ok;

    ok = platch_decode((const uint8_t *) line, strlen(line), kJSONMessageCodec, &obj);
    if (ok != 0) {
        LOG_ERROR("plymouth handoff: tempod reply is not JSON: %s\n", line);
        return TEMPOD_FAILED;
    }

    if (obj.json_value.type == kJsonObject) {
        value = jsobject_get(&obj.json_value, "ok");
        if (value != NULL && value->type == kJsonTrue) {
            outcome = TEMPOD_DONE;
        } else {
            value = jsobject_get(&obj.json_value, "error");
            LOG_ERROR(
                "plymouth handoff: tempod could not hand off the display: %s\n",
                (value != NULL && value->type == kJsonString) ? value->string_value : "(no error given)"
            );
        }
    } else {
        LOG_ERROR("plymouth handoff: unexpected tempod reply: %s\n", line);
    }

    platch_free_obj(&obj);
    return outcome;
}

static enum tempod_outcome tempod_handoff(int drm_fd) {
    const char *path = tempod_socket_path();
    char reply[TEMPOD_REPLY_MAX];
    enum tempod_outcome outcome;
    int sock;

    sock = tempod_connect(path);
    if (sock < 0) {
        // ENOENT: no daemon installed. ECONNREFUSED: socket file but nobody
        // listening. EACCES: not in the daemon's group. All mean "no tempod".
        LOG_ERROR("plymouth handoff: tempod not reachable at %s (%s); using the in-process path\n", path, strerror(errno));
        return TEMPOD_UNAVAILABLE;
    }

    LOG_ERROR("plymouth handoff: delegating the DRM hand-off to tempod at %s\n", path);

    if (tempod_send_request(sock, drm_fd) != 0) {
        LOG_ERROR("plymouth handoff: could not send the request to tempod: %s\n", strerror(errno));
        outcome = TEMPOD_FAILED;
    } else if (tempod_read_reply(sock, reply, sizeof reply) != 0) {
        LOG_ERROR("plymouth handoff: no reply from tempod: %s\n", strerror(errno));
        outcome = TEMPOD_FAILED;
    } else {
        outcome = tempod_parse_reply(reply);
    }

    close(sock);
    return outcome;
}

// The original, in-process hand-off. Needs the privileges to talk to
// plymouthd and to become DRM master, i.e. root.
static void in_process_handoff(int drm_fd) {
    // Fade the throbber down to the bare logo while plymouth still owns the
    // panel, so the frame we are about to freeze on is the clean swirl.
    (void) system("plymouth update --status=tempo-handoff");
    usleep(FADE_US);

    // Drop plymouth's master (deactivate leaves its last frame frozen on the
    // panel, so no black), then become master on the fd flutter-pi already
    // holds. NOT drmdev_resume: that re-opens the device and errors EINVAL
    // here because the fd was never suspended - flutter-pi has always had it
    // open, it just was not the master while plymouth was. A plain
    // drmSetMaster flips that, and the commit path's is_drm_master check
    // (drmAuthMagic) then passes, so the frame that was paused can land.
    (void) system("plymouth deactivate");

    if (drm_fd >= 0) {
        // Retry briefly: plymouth's master drop and our set can race.
        for (int i = 0; i < 20 && drmSetMaster(drm_fd) != 0; i++) {
            usleep(50 * 1000);
        }
    }
    // Force a fresh frame so the (now un-paused) commit actually happens.
    flutterpi_request_frame(g_flutterpi);

    // Retire plymouth for good now that it is off the display (invisible); a
    // single quit can race flutter-pi's master grab, so retry until it is gone.
    for (int i = 0; i < 20 && system("pidof plymouthd >/dev/null 2>&1") == 0; i++) {
        (void) system("plymouth quit --retain-splash");
        usleep(300 * 1000);
    }
}

// Runs off the platform thread: the fade and the sleeps must not block it.
static void *handoff_thread(void *arg) {
    struct drmdev *drmdev;
    int drm_fd = -1;

    (void) arg;

    drmdev = flutterpi_get_drmdev(g_flutterpi);
    if (drmdev != NULL) {
        drm_fd = drmdev_get_fd(drmdev);
    }

    if (drm_fd >= 0) {
        // The card was opened without O_CLOEXEC. Once it is master, a child
        // (the plymouth calls below, Dart's Process.start) inheriting it would
        // keep the master alive past a crash of ours, and the restarted
        // frontend would get EBUSY. Close it on exec, always.
        (void) fcntl(drm_fd, F_SETFD, FD_CLOEXEC);
    }

    if (drm_fd >= 0 && tempod_handoff(drm_fd) == TEMPOD_DONE) {
        // tempod made our fd master and is retiring plymouth itself; all that
        // is left is to force the paused first commit through.
        flutterpi_request_frame(g_flutterpi);
        return NULL;
    }

    if (geteuid() != 0) {
        // Unprivileged and without tempod there is no way to become master:
        // drmSetMaster is EACCES for an fd that was never master, and
        // plymouthd only takes commands from root. Do not spend seconds
        // forking plymouth calls that will be refused; just ask for a frame
        // so the log shows what happened when the commit is bounced.
        LOG_ERROR("plymouth handoff: not root and no tempod - cannot take the display, leaving the splash up\n");
        flutterpi_request_frame(g_flutterpi);
        return NULL;
    }

    // No tempod, or it could not finish the job, and we are root: do it here.
    in_process_handoff(drm_fd);
    return NULL;
}

static void start_handoff(void) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, handoff_thread, NULL) == 0) {
        pthread_detach(thread);
    }
}

static int on_receive(char *channel, struct platch_obj *object, FlutterPlatformMessageResponseHandle *response_handle) {
    (void) channel;

    if (streq(object->method, "handoff")) {
        // Once only: a second signal must not re-run the whole dance.
        pthread_once(&g_once, start_handoff);
        return platch_respond(
            response_handle,
            &(struct platch_obj){ .codec = kStandardMethodCallResponse, .success = true, .std_result = { .type = kStdTrue } }
        );
    }

    return platch_respond_not_implemented(response_handle);
}

enum plugin_init_result plymouth_handoff_init(struct flutterpi *flutterpi, void **userdata_out) {
    int ok;

    g_flutterpi = flutterpi;

    ok = plugin_registry_set_receiver_locked(PLYMOUTH_HANDOFF_CHANNEL, kStandardMethodCall, on_receive);
    if (ok != 0) {
        return PLUGIN_INIT_RESULT_ERROR;
    }

    *userdata_out = NULL;
    return PLUGIN_INIT_RESULT_INITIALIZED;
}

void plymouth_handoff_deinit(struct flutterpi *flutterpi, void *userdata) {
    (void) userdata;
    plugin_registry_remove_receiver_v2_locked(flutterpi_get_plugin_registry(flutterpi), PLYMOUTH_HANDOFF_CHANNEL);
}

FLUTTERPI_PLUGIN("plymouth handoff", plymouth_handoff_plugin, plymouth_handoff_init, plymouth_handoff_deinit)
