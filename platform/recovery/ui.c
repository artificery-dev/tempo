/* Recovery framebuffer UI; no dependency on a mounted root filesystem. */
#define _POSIX_C_SOURCE 200809L
#include "ui-assets.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#define M_PI 3.14159265358979323846
#define W 480
#define H 360
#define FG 0xf4f4f5
#define MUTED 0xbedbff
#define PRIMARY 0x00bcff
#ifndef STATE
#define STATE "/run/tempo-recovery-state"
#endif
static uint32_t frame[W * H];
static int spinning;
static void pixel(int x, int y, uint32_t color, int alpha) {
  if (x < 0 || y < 0 || x >= W || y >= H)
    return;
  uint32_t old = frame[y * W + x], result = 0;
  for (int shift = 0; shift < 24; shift += 8)
    result |= (((((color >> shift) & 255) * alpha +
                 ((old >> shift) & 255) * (255 - alpha)) /
                255)
               << shift);
  frame[y * W + x] = result;
}
static void rect(int x, int y, int w, int h, uint32_t color) {
  for (int j = y; j < y + h; j++)
    for (int i = x; i < x + w; i++)
      pixel(i, j, color, 255);
}
static void restore_background(int x, int y, int w, int h) {
  for (int j = y; j < y + h; j++)
    for (int i = x; i < x + w; i++) {
      const unsigned char *p = &background_pixels[(j * W + i) * 4];
      frame[j * W + i] = (p[0] << 16) | (p[1] << 8) | p[2];
    }
}
static void text(int x, int y, const char *s, uint32_t color) {
  for (; *s; s++, x += 12) {
    unsigned char c = *s;
    if (c < 32 || c > 126)
      c = '?';
    for (int j = 0; j < 24; j++)
      for (int i = 0; i < 12; i++)
        pixel(x + i, y + j, color,
              font_pixels[(j * font_width + (c - 32) * 12 + i) * 4 + 3]);
  }
}
static void centered(int y, const char *s, uint32_t color) {
  text((W - (int)strlen(s) * 12) / 2, y, s, color);
}
static int value(const char *supply, const char *property) {
  char path[256];
  snprintf(path, sizeof(path), "/sys/class/power_supply/%s/%s", supply,
           property);
  FILE *f = fopen(path, "r");
  int v = -1;
  if (f) {
    if (fscanf(f, "%d", &v) != 1)
      v = -1;
    fclose(f);
  }
  return v;
}
static void line(FILE *f, char *out, size_t size) {
  if (!fgets(out, size, f)) {
    out[0] = 0;
    return;
  }
  /* Always consume the whole record so a long label cannot become counters. */
  if (!strchr(out, '\n')) {
    int c;
    while ((c = fgetc(f)) != '\n' && c != EOF) {}
  }
  out[strcspn(out, "\r\n")] = 0;
}
static int transfer_mode(const char *mode) {
  return !strcmp(mode, "backup") || !strcmp(mode, "restore") ||
         !strcmp(mode, "flash") || !strcmp(mode, "verify");
}
static const char *mode_title(const char *mode) {
  if (!strcmp(mode, "backup")) return "Backing up player";
  if (!strcmp(mode, "restore")) return "Restoring backup";
  if (!strcmp(mode, "flash")) return "Flashing firmware";
  if (!strcmp(mode, "verify")) return "Verifying data";
  if (!strcmp(mode, "preparing")) return "Preparing recovery";
  if (!strcmp(mode, "stopping")) return "Stopping operation";
  if (!strcmp(mode, "complete")) return "Operation complete";
  if (!strcmp(mode, "cancelled")) return "Operation cancelled";
  if (!strcmp(mode, "error")) return "Operation failed";
  return "Working...";
}
static double monotonic_seconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static int byte_count(const char *s, uint64_t *out) {
  if (!s[0]) return 0;
  for (const char *c = s; *c; c++)
    if (*c < '0' || *c > '9') return 0;
  errno = 0;
  char *end;
  *out = strtoull(s, &end, 10);
  return !errno && !*end;
}
static void draw(double phase, const char *override) {
  restore_background(0, 0, W, H);
  for (unsigned y = 0; y < icon_height; y++)
    for (unsigned x = 0; x < icon_width; x++) {
      const unsigned char *p = &icon_pixels[(y * icon_width + x) * 4];
      pixel((W - icon_width) / 2 + x, (260 - icon_height) / 2 + y, (p[0] << 16) | (p[1] << 8) | p[2], p[3]);
    }
  for (unsigned y = 0; y < wordmark_height; y++)
    for (unsigned x = 0; x < wordmark_width; x++) {
      const unsigned char *p = &wordmark_pixels[(y * wordmark_width + x) * 4];
      pixel(16 + x, 10 + y, (p[0] << 16) | (p[1] << 8) | p[2], p[3]);
    }
  static int pct = -1, uv = -1, online = -1, limit = -1;
  static time_t last_sample = -1;
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  if (now.tv_sec != last_sample) {
    pct = value("mt6323-battery", "capacity");
    uv = value("mt6323-battery", "voltage_now");
    online = value("mt6323-charger", "online");
    limit = value("mt6323-charger", "constant_charge_current_max");
    last_sample = now.tv_sec;
  }
  char b[32];
  const int battery_right = W - 16;
  if (pct >= 0)
    snprintf(b, sizeof(b), "%d%%", pct);
  else
    strcpy(b, "--%");
  int percentage_x = battery_right - (int)strlen(b) * 12;
  int battery_x = percentage_x - 8 - 31;
  rect(battery_x, 19, 28, 14, MUTED);
  restore_background(battery_x + 2, 21, 24, 10);
  rect(battery_x + 28, 23, 3, 6, MUTED);
  if (pct >= 0)
    rect(battery_x + 3, 22, 22 * (pct > 100 ? 100 : pct) / 100, 8,
         online > 0 ? PRIMARY : FG);
  text(percentage_x, 14, b, FG);
  if (uv >= 0)
    snprintf(b, sizeof(b), "%.2fV", uv / 1000000.0);
  else
    strcpy(b, "-- V");
  text(battery_right - (int)strlen(b) * 12, 40, b, MUTED);
  if (limit >= 0 && online > 0)
    snprintf(b, sizeof(b), "%dmA", limit / 1000);
  else
    strcpy(b, "--mA");
  text(battery_right - (int)strlen(b) * 12, 64, b, PRIMARY);
  char mode[32] = "ready", first[128] = "", second[128] = "", percent[32] = "0";
  uint64_t done = 0, total = 0;
  double sampled = 0, rate = 0;
  FILE *f = fopen(STATE, "r");
  if (f) {
    line(f, mode, sizeof(mode));
    line(f, percent, sizeof(percent));
    line(f, first, sizeof(first));
    line(f, second, sizeof(second));
    if (fscanf(f, "%" SCNu64 " %" SCNu64 " %lf %lf",
               &done, &total, &sampled, &rate) != 4)
      done = total = 0;
    fclose(f);
  }
  if (override) {
    snprintf(mode, sizeof(mode), "%s", override);
    strcpy(first, "Backing up your player");
    strcpy(second, "Keep the USB cable connected");
    strcpy(percent, "42");
  }
  int transfer = transfer_mode(mode);
  spinning = !strcmp(mode, "busy") || !strcmp(mode, "preparing") ||
             !strcmp(mode, "stopping") || (transfer && !total);
  if (!strcmp(mode, "ready")) {
    centered(260, "Recovery Ready", FG);
    return;
  }
  if (!first[0])
    snprintf(first, sizeof(first), "%s", mode_title(mode));
  char *third = strstr(second, " - ");
  if (third) {
    *third = 0;
    third += 3;
  }
  centered(third ? 232 : 240, first, !strcmp(mode, "error") ? 0xffb4ab : FG);
  centered(third ? 258 : 266, second, MUTED);
  if (third) centered(284, third, MUTED);
  if (!strcmp(mode, "progress") || (transfer && total)) {
    int n = transfer ? (int)(100.0L * done / total) : atoi(percent);
    if (n < 0) n = 0;
    if (n > 100) n = 100;
    rect(48, 316, 384, 6, 0x1c398e);
    rect(48, 316, 384 * n / 100, 6, PRIMARY);
    char summary[80];
    if (transfer) {
      // Completed bytes come from the transfer worker, never an animation timer.
      // A worker which stops reporting must not leave a stale speed on screen.
      if (monotonic_seconds() - sampled > 2 || done == total) rate = 0;
      snprintf(summary, sizeof(summary), "%d%%  %.1f/%.1f MiB  %.1f MiB/s",
               n, done / 1048576.0, total / 1048576.0, rate / 1048576.0);
    } else {
      snprintf(summary, sizeof(summary), "%d%%", n);
    }
    centered(330, summary, MUTED);
  } else if (spinning) {
    for (int y = 306; y < 342; y++)
      for (int x = 222; x < 258; x++) {
        double dx = x - 239.5, dy = y - 323.5, d = sqrt(dx * dx + dy * dy),
               coverage = fmax(0, 1 - fabs(d - 12) / 2);
        double a = atan2(dy, dx) - phase;
        while (a < 0)
          a += 2 * M_PI;
        while (a >= 2 * M_PI)
          a -= 2 * M_PI;
        pixel(x, y, PRIMARY, (int)(coverage * (35 + 220 * a / (2 * M_PI))));
      }
  }
}
static int status(int argc, char **argv) {
  if (argc < 3)
    return 2;
  const char *mode = argv[2];
  int progress = 0, start = 3;
  uint64_t done = 0, total = 0;
  double sampled = monotonic_seconds(), rate = 0;
  if (transfer_mode(mode)) {
    if (argc < 5 || !byte_count(argv[3], &done) ||
        !byte_count(argv[4], &total) || (total && done > total)) return 2;
    start = 5;
    // Compare cumulative counters within the same operation. A counter reset
    // or mode change starts a fresh speed sample.
    FILE *previous = fopen(STATE, "r");
    if (previous) {
      char old_mode[32], ignored[128];
      uint64_t old_done, old_total;
      double old_time, old_rate;
      line(previous, old_mode, sizeof(old_mode));
      for (int i = 0; i < 3; i++) line(previous, ignored, sizeof(ignored));
      if (fscanf(previous, "%" SCNu64 " %" SCNu64 " %lf %lf",
                 &old_done, &old_total, &old_time, &old_rate) == 4 &&
          !strcmp(mode, old_mode) && old_total == total && done >= old_done &&
          sampled > old_time)
        rate = (done - old_done) / (sampled - old_time);
      fclose(previous);
    }
  } else if (!strcmp(mode, "progress")) {
    if (argc < 4)
      return 2;
    char *end;
    long n = strtol(argv[3], &end, 10);
    if (end == argv[3] || *end || n < 0 || n > 100)
      return 2;
    progress = n;
    start = 4;
  } else if (strcmp(mode, "busy") && strcmp(mode, "ready") &&
             strcmp(mode, "preparing") && strcmp(mode, "stopping") &&
             strcmp(mode, "complete") && strcmp(mode, "cancelled") &&
             strcmp(mode, "error"))
    return 2;
  if (argc > start + 2)
    return 2;
  for (int i = start; i < argc; i++)
    if (strlen(argv[i]) > 40 || strpbrk(argv[i], "\r\n"))
      return 2;
  for (int i = start; i < argc; i++)
    for (const unsigned char *c = (const unsigned char *)argv[i]; *c; c++)
      if (*c < 32 || *c > 126)
        return 2;
  char tmp[128];
  snprintf(tmp, sizeof(tmp), STATE ".%ld", (long)getpid());
  FILE *f = fopen(tmp, "w");
  if (!f)
    return 1;
  int failed = fprintf(f, "%s\n%d\n%s\n%s\n", mode, progress,
                       argc > start ? argv[start] : "",
                       argc > start + 1 ? argv[start + 1] : "") < 0;
  if (fprintf(f, "%" PRIu64 " %" PRIu64 " %.9f %.3f\n",
              done, total, sampled, rate) < 0) failed = 1;
  if (fclose(f))
    failed = 1;
  if (!failed && rename(tmp, STATE) == 0)
    return 0;
  unlink(tmp);
  return 1;
}
int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "status"))
    return status(argc, argv);
  if (argc == 4 && !strcmp(argv[1], "preview")) {
    draw(1, !strcmp(argv[2], "state") ? NULL : argv[2]);
    FILE *f = fopen(argv[3], "wb");
    if (!f)
      return 1;
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int i = 0; i < W * H; i++) {
      fputc(frame[i] >> 16, f);
      fputc(frame[i] >> 8, f);
      fputc(frame[i], f);
    }
    return fclose(f) != 0;
  }
  int fd = -1;
  for (int i = 0; i < 30 && fd < 0; i++) {
    fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0)
      sleep(1);
  }
  if (fd < 0) {
    perror("DRM device");
    return 1;
  }
  if (drmSetMaster(fd)) {
    perror("DRM master");
    return 1;
  }
  drmModeRes *resources = drmModeGetResources(fd);
  if (!resources) {
    perror("DRM resources");
    return 1;
  }
  drmModeConnector *connector = NULL;
  for (int i = 0; i < resources->count_connectors; i++) {
    drmModeConnector *candidate =
        drmModeGetConnector(fd, resources->connectors[i]);
    if (candidate && candidate->connection == DRM_MODE_CONNECTED &&
        candidate->count_modes) {
      connector = candidate;
      break;
    }
    if (candidate)
      drmModeFreeConnector(candidate);
  }
  if (!connector) {
    fprintf(stderr, "No connected DRM display\n");
    return 1;
  }
  uint32_t crtc = 0;
  for (int i = 0; i < connector->count_encoders && !crtc; i++) {
    drmModeEncoder *encoder = drmModeGetEncoder(fd, connector->encoders[i]);
    if (!encoder)
      continue;
    for (int n = 0; n < resources->count_crtcs; n++)
      if (encoder->possible_crtcs & (1u << n)) {
        crtc = resources->crtcs[n];
        break;
      }
    drmModeFreeEncoder(encoder);
  }
  drmModeModeInfo mode = connector->modes[0];
  if (!crtc || mode.hdisplay != W || mode.vdisplay != H) {
    fprintf(stderr, "Unsupported display mode %ux%u\n", mode.hdisplay,
            mode.vdisplay);
    return 1;
  }
  struct drm_mode_create_dumb buffer = {.width = W, .height = H, .bpp = 32};
  if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &buffer)) {
    perror("DRM buffer");
    return 1;
  }
  uint32_t framebuffer;
  if (drmModeAddFB(fd, W, H, 24, 32, buffer.pitch, buffer.handle,
                   &framebuffer)) {
    perror("DRM framebuffer");
    return 1;
  }
  struct drm_mode_map_dumb mapping = {.handle = buffer.handle};
  if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mapping))
    return 1;
  unsigned char *fb = mmap(NULL, buffer.size, PROT_READ | PROT_WRITE,
                           MAP_SHARED, fd, mapping.offset);
  if (fb == MAP_FAILED)
    return 1;
  draw(0, NULL);
  for (unsigned y = 0; y < H; y++)
    memcpy(fb + y * buffer.pitch, frame + y * W, W * 4);
  if (drmModeSetCrtc(fd, crtc, framebuffer, 0, 0, &connector->connector_id, 1,
                     &mode)) {
    perror("DRM modeset");
    return 1;
  }
  fprintf(stderr, "Recovery display ready: %ux%u XRGB8888\n",
          mode.hdisplay, mode.vdisplay);
  drmModeFreeConnector(connector);
  drmModeFreeResources(resources);
  for (unsigned tick = 0;; tick++) {
    draw(tick * .18, NULL);
    for (unsigned y = 0; y < H; y++)
      memcpy(fb + y * buffer.pitch, frame + y * W, W * 4);
    struct timespec delay = {0, spinning ? 50000000 : 200000000};
    nanosleep(&delay, NULL);
  }
}
