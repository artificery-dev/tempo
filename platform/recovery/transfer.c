/* Tempo recovery USB bulk service. Wire integers are little endian. */
#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <linux/usb/functionfs.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <sys/reboot.h>

#define CHUNK (1024 * 1024)
#ifndef STATE
#define STATE "/run/tempo-recovery-state"
#endif
enum { INFO = 1, BEGIN_READ, BEGIN_WRITE, READ, WRITE, ACK, FINISH, CANCEL, CONTEXT, FILL, REBOOT };
struct __attribute__((packed)) header {
  char magic[8];
  uint32_t op, status;
  uint64_t offset, length;
  uint32_t size, crc, region, flags;
};
_Static_assert(sizeof(struct header) == 48, "wire header size");
static int input, output, disk = -1, writing, boot_permission, test_mode;
static uint32_t active_region, active_flags;
static uint64_t base, total, completed, pending;
static double last_time, last_publish;
static uint64_t last_done;
static char context_title[64], context_detail[96];
static unsigned char buffer[CHUNK], check[CHUNK];
static const char *paths[3] = {"/dev/mmcblk0", "/dev/mmcblk0boot0",
                               "/dev/mmcblk0boot1"};
static uint32_t table[256];
static volatile sig_atomic_t timed_out;
static void timeout_signal(int sig) {
  (void)sig;
  timed_out = 1;
}
static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static uint32_t crc32(const void *data, size_t n) {
  uint32_t crc = ~0u;
  const unsigned char *p = data;
  while (n--)
    crc = table[(crc ^ *p++) & 255] ^ (crc >> 8);
  return ~crc;
}
static void state(const char *mode, const char *title, const char *detail,
                  int force) {
  double t = now();
  if (!force && t - last_publish < 0.2)
    return;
  double rate = t > last_time ? (completed - last_done) / (t - last_time) : 0;
  FILE *f = fopen(STATE ".transfer", "w");
  if (f) {
    fprintf(f, "%s\n0\n%s\n%s\n%" PRIu64 " %" PRIu64 " %.9f %.3f\n", mode,
            title, detail, completed, total, t, rate);
    if (!fclose(f))
      rename(STATE ".transfer", STATE);
  }
  last_time = last_publish = t;
  last_done = completed;
}
static int boot_force_saved = -1;
static int boot_force(int value) {
  if (test_mode || !active_region)
    return 0;
  char path[128];
  snprintf(path, sizeof(path), "/sys/class/block/mmcblk0boot%u/force_ro",
           active_region - 1);
  FILE *f = fopen(path, "r");
  int old;
  if (!f)
    return -1;
  int ok = fscanf(f, "%d", &old) == 1;
  fclose(f);
  if (!ok)
    return -1;
  if (value == 0)
    boot_force_saved = old;
  f = fopen(path, "w");
  if (!f)
    return -1;
  int failed = fprintf(f, "%d\n", value) < 0;
  return fclose(f) || failed ? -1 : 0;
}
static void close_disk(void) {
  if (disk >= 0) {
    if (writing) {
      int ro = 1;
      ioctl(disk, BLKROSET, &ro);
    }
    if (boot_force_saved >= 0) {
      boot_force(boot_force_saved);
      boot_force_saved = -1;
    }
    close(disk);
    disk = -1;
  }
  pending = 0;
  writing = 0;
}
/* Bounded waits let disconnects and stalled hosts terminate an operation. */
static int exact(int fd, void *data, size_t count, int send) {
  unsigned char *p = data;
  while (count) {
    struct pollfd pollfd = {fd, send ? POLLOUT : POLLIN, 0};
    int r = poll(&pollfd, 1, 30000);
    if (r < 0 && errno == EINTR)
      continue;
    if (r == 0 && !send && disk < 0)
      continue;
    if (r <= 0 || !(pollfd.revents & (send ? POLLOUT : POLLIN))) {
      if (r == 0) errno = ETIMEDOUT;
      return -1;
    }
    timed_out = 0;
    if (send || disk >= 0)
      alarm(30);
    /* FunctionFS allocates a contiguous buffer per syscall. Keep those
       allocations small even though protocol chunks remain 1 MiB. */
    size_t part = count < 65536 ? count : 65536;
    ssize_t n = send ? write(fd, p, part) : read(fd, p, part);
    alarm(0);
    if (timed_out) {
      errno = ETIMEDOUT;
      return -1;
    }
    if (n < 0 && (errno == EINTR || errno == EAGAIN))
      continue;
    if (n <= 0)
      return -1;
    count -= n;
    p += n;
  }
  return 0;
}
static int reply(uint32_t op, uint32_t status, void *data, uint32_t size) {
  struct header h = {.magic = {'T', 'E', 'M', 'P', 'R', 'E', 'C', '1'},
                     .op = htole32(op | 0x80000000u),
                     .status = htole32(status),
                     .offset = htole64(completed),
                     .length = htole64(total),
                     .size = htole32(size),
                     .crc = htole32(crc32(data, size)),
                     .region = htole32(active_region)};
  return exact(output, &h, sizeof(h), 1) ||
         (size && exact(output, data, size, 1));
}
static int failure(uint32_t op, const char *message) {
  if (disk >= 0 && writing) {
    state("stopping", "Stopping operation", "Synchronizing storage", 1);
    fdatasync(disk);
  }
  state("error", "Transfer failed", message, 1);
  close_disk();
  context_title[0] = context_detail[0] = 0;
  return reply(op, 1, (void *)message, strlen(message));
}
static uint64_t disk_size(int fd) {
  struct stat st;
  uint64_t size = 0;
  if (fstat(fd, &st))
    return 0;
  if (S_ISREG(st.st_mode) && test_mode)
    return st.st_size;
  if (!S_ISBLK(st.st_mode) || ioctl(fd, BLKGETSIZE64, &size))
    return 0;
  return size;
}
static int mounted(void) {
  if (test_mode)
    return 0;
  FILE *f = fopen("/proc/mounts", "r");
  if (!f)
    return 1;
  char line[4096];
  int found = 0;
  while (fgets(line, sizeof(line), f))
    if (strstr(line, "/dev/mmcblk"))
      found = 1;
  fclose(f);
  return found;
}
static int io_at(int fd, void *data, size_t size, uint64_t offset,
                 int write_it) {
  unsigned char *p = data;
  while (size) {
    ssize_t n =
        write_it ? pwrite(fd, p, size, offset) : pread(fd, p, size, offset);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return -1;
    p += n;
    size -= n;
    offset += n;
  }
  return 0;
}
static int serve(void) {
  for (;;) {
    struct header h;
    if (exact(input, &h, sizeof(h), 0))
      return -1;
    fprintf(stderr, "request received\n");
    if (memcmp(h.magic, "TEMPREC1", 8))
      return -1;
    uint32_t op = le32toh(h.op), size = le32toh(h.size),
             region = le32toh(h.region), flags = le32toh(h.flags);
    uint64_t offset = le64toh(h.offset), length = le64toh(h.length);
    if (size > CHUNK || le32toh(h.status))
      return -1;
    if (size && exact(input, buffer, size, 0))
      return -1;
    if (crc32(buffer, size) != le32toh(h.crc)) {
      if (failure(op, "Checksum mismatch"))
        return -1;
      continue;
    }
    if (op != WRITE && op != CONTEXT && op != FILL && size) {
      if (failure(op, "Unexpected payload"))
        return -1;
      continue;
    }
    int result = 0;
    if (op == REBOOT) {
      if (disk >= 0) result = failure(op, "Cannot reboot an active transfer");
      else {
        sync();
        state("stopping", "Restarting player", "Operation completed successfully", 1);
        result = reply(op,0,NULL,0);
        if (!result && !test_mode) {
          usleep(200000);
          if (reboot(RB_AUTOBOOT)) return -1;
        }
      }
    } else if (op == CONTEXT) {
      unsigned char *split = memchr(buffer, '\n', size);
      int valid = disk < 0 && split && split > buffer &&
          split - buffer < (int)sizeof(context_title) &&
          size - (size_t)(split - buffer) - 1 < sizeof(context_detail);
      for (uint32_t i = 0; i < size; i++)
        if (buffer + i != split && (buffer[i] < 32 || buffer[i] > 126)) valid = 0;
      if (!valid) result = failure(op, "Invalid display context");
      else {
        size_t title_size = split - buffer, detail_size = size - title_size - 1;
        memcpy(context_title, buffer, title_size); context_title[title_size] = 0;
        memcpy(context_detail, split + 1, detail_size); context_detail[detail_size] = 0;
        result = reply(op, 0, NULL, 0);
      }
    } else if (op == INFO) {
      if (disk >= 0) {
        result = failure(op, "Operation already active");
      } else {
        uint64_t sizes[3] = {0};
        for (int i = 0; i < 3; i++) {
          int fd = open(paths[i], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
          if (fd >= 0) {
            sizes[i] = disk_size(fd);
            close(fd);
          }
        }
        char json[512];
        int n = snprintf(json, sizeof(json),
                         "{\"version\":1,\"context\":true,\"fill\":true,\"reboot\":true,\"max_chunk\":%u,\"regions\":[{\"id\":"
                         "0,\"name\":\"user\",\"size\":%" PRIu64
                         "},{\"id\":1,\"name\":\"boot0\",\"size\":%" PRIu64
                         "},{\"id\":2,\"name\":\"boot1\",\"size\":%" PRIu64
                         "}],\"boot_writes\":%s}",
                         CHUNK, sizes[0], sizes[1], sizes[2],
                         boot_permission ? "true" : "false");
        result = reply(op, 0, json, n);
      }
    } else if (op == BEGIN_READ || op == BEGIN_WRITE) {
      if (disk >= 0 || region > 2 || !length || offset % 512 || length % 512 ||
          flags & ~3u ||
          (op == BEGIN_WRITE && region == 1 &&
           !(boot_permission && (flags & 1)))) {
        result = failure(op, "Invalid transfer request");
      } else if (mounted())
        result = failure(op, "Storage is mounted");
      else {
        disk = open(paths[region], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        uint64_t capacity = disk >= 0 ? disk_size(disk) : 0;
        if (!capacity || offset > capacity || length > capacity - offset ||
            offset > INT64_MAX || length > INT64_MAX - offset)
          result = failure(op, "Range outside storage");
        else {
          active_region = region;
          active_flags = flags;
          base = offset;
          total = length;
          completed = last_done = pending = 0;
          last_time = now();
          writing = op == BEGIN_WRITE;
          if (writing) {
            if (boot_force(0)) {
              result = failure(op, "Cannot unlock boot region");
              goto responded;
            }
            int ro = 0;
            if (!test_mode && ioctl(disk, BLKROSET, &ro)) {
              result = failure(op, "Storage write lock failed");
              goto responded;
            }
            int fd = open(paths[region], O_RDWR | O_CLOEXEC | O_NOFOLLOW);
            if (fd < 0) {
              result = failure(op, "Cannot open storage for write");
              goto responded;
            }
            close(disk);
            disk = fd;
          }
          if (!context_title[0]) {
            snprintf(context_title, sizeof(context_title), "%s %s", writing ? "Writing" : "Reading",
                     region == 0 ? "user data" : region == 1 ? "boot0" : "boot1");
            snprintf(context_detail, sizeof(context_detail), "Offset 0x%" PRIx64 "%s", offset,
                     writing && (flags & 2) ? " - write + verify" : "");
          }
          state(writing ? "flash" : "backup", context_title, context_detail, 1);
          result = reply(op, 0, NULL, 0);
        }
      }
    } else if (op == READ || op == WRITE || op == FILL) {
      if (disk < 0 || pending || (op != READ) != writing || !length ||
          length > CHUNK || length % 512 || offset != base + completed ||
          length > total - completed || region != active_region ||
          (writing && size != (op == FILL ? 4 : length)) || (!writing && size))
        result = failure(op, "Invalid transfer chunk");
      else if (op == FILL) {
        for (uint64_t i=4; i<length; i++) buffer[i]=buffer[i%4];
        if (io_at(disk,buffer,length,offset,1) || fdatasync(disk)) result=failure(op,"Fill write failed");
        else if ((active_flags & 2) && (io_at(disk,check,length,offset,0) || memcmp(buffer,check,length))) result=failure(op,"Fill verification failed");
        else {posix_fadvise(disk,offset,length,POSIX_FADV_DONTNEED);completed+=length;state("flash",context_title,context_detail,0);result=reply(op,0,NULL,0);}
      }
      else if (io_at(disk, buffer, length, offset, writing))
        result = failure(op, "Storage I/O failed");
      else if (writing) {
        if (fdatasync(disk))
          result = failure(op, "Storage sync failed");
        else if ((active_flags & 2) && (io_at(disk, check, length, offset, 0) ||
                                        memcmp(buffer, check, length)))
          result = failure(op, "Write verification failed");
        else {
          posix_fadvise(disk, offset, length, POSIX_FADV_DONTNEED);
          completed += length;
          state("flash", context_title, context_detail, 0);
          result = reply(op, 0, NULL, 0);
        }
      } else {
        pending = length;
        result = reply(op, 0, buffer, length);
      }
    } else if (op == ACK) {
      if (disk < 0 || writing || !pending ||
          offset != base + completed + pending)
        result = failure(op, "Invalid read acknowledgement");
      else {
        posix_fadvise(disk, base + completed, pending, POSIX_FADV_DONTNEED);
        completed += pending;
        pending = 0;
        state("backup", context_title, context_detail, 0);
        result = reply(op, 0, NULL, 0);
      }
    } else if (op == FINISH || op == CANCEL) {
      if (op == CANCEL && disk < 0) {
        context_title[0] = context_detail[0] = 0;
        result = reply(op, 0, NULL, 0);
      } else if (disk < 0 || (op == FINISH && (pending || completed != total)))
        result = failure(op, "Transfer is incomplete");
      else {
        state("stopping",
              op == CANCEL ? "Stopping operation" : "Finishing operation",
              "Synchronizing storage", 1);
        if (writing && fdatasync(disk))
          result = failure(op, "Storage sync failed");
        else {
          close_disk();
          state(op == CANCEL ? "cancelled" : "complete",
                op == CANCEL ? "Operation cancelled" : "Transfer complete", "",
                1);
          context_title[0] = context_detail[0] = 0;
          result = reply(op, 0, NULL, 0);
        }
      }
    } else
      result = failure(op, "Unknown command");
  responded:
    if (result)
      return -1;
  }
}

static int descriptors(int fd) {
  struct __attribute__((packed)) desc {
    struct usb_functionfs_descs_head_v2 head;
    uint32_t fs_count, hs_count;
    struct __attribute__((packed)) speed {
      struct usb_interface_descriptor intf;
      struct usb_endpoint_descriptor_no_audio in, out;
    } fs, hs;
  } d = {0};
  d.head.magic = htole32(FUNCTIONFS_DESCRIPTORS_MAGIC_V2);
  d.head.length = htole32(sizeof(d));
  d.head.flags = htole32(FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC);
  d.fs_count = d.hs_count = htole32(3);
  d.fs.intf =
      (struct usb_interface_descriptor){.bLength = USB_DT_INTERFACE_SIZE,
                                        .bDescriptorType = USB_DT_INTERFACE,
                                        .bNumEndpoints = 2,
                                        .bInterfaceClass = 0xff,
                                        .bInterfaceSubClass = 0x54,
                                        .bInterfaceProtocol = 1,
                                        .iInterface = 1};
  d.fs.in = (struct usb_endpoint_descriptor_no_audio){
      .bLength = USB_DT_ENDPOINT_SIZE,
      .bDescriptorType = USB_DT_ENDPOINT,
      .bEndpointAddress = USB_DIR_IN | 1,
      .bmAttributes = USB_ENDPOINT_XFER_BULK,
      .wMaxPacketSize = htole16(64)};
  d.fs.out = d.fs.in;
  d.fs.out.bEndpointAddress = 2;
  d.hs = d.fs;
  d.hs.in.wMaxPacketSize = d.hs.out.wMaxPacketSize = htole16(512);
  if (write(fd, &d, sizeof(d)) != sizeof(d))
    return -1;
  struct __attribute__((packed)) strings {
    struct usb_functionfs_strings_head head;
    uint16_t lang;
    char name[24];
  } strings = {.head = {.magic = htole32(FUNCTIONFS_STRINGS_MAGIC),
                        .length = htole32(sizeof(strings)),
                        .str_count = htole32(1),
                        .lang_count = htole32(1)},
               .lang = htole16(0x409),
               .name = "Tempo Recovery Transfer"};
  return write(fd, &strings, sizeof(strings)) == sizeof(strings) ? 0 : -1;
}
/* Reset only the USB session, never the player or its storage. This also
   discards partial protocol frames after a timeout or malformed request. */
static int reconnect_usb(void) {
  const char *path = "/sys/kernel/config/usb_gadget/tempo/UDC";
  char controller[128] = {0};
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  char *line = fgets(controller, sizeof(controller), f);
  fclose(f);
  if (!line || !controller[0] || controller[0] == '\n') return 0;
  f = fopen(path, "w");
  if (!f) return -1;
  int failed = fputs("\n", f) < 0;
  if (fclose(f) || failed) return -1;
  usleep(300000);
  f = fopen(path, "w");
  if (!f) return -1;
  failed = fputs(controller, f) < 0;
  return fclose(f) || failed ? -1 : 0;
}

int main(int argc, char **argv) {
  struct sigaction action = {.sa_handler = timeout_signal};
  sigaction(SIGALRM, &action, NULL);
  for (unsigned i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int j = 0; j < 8; j++)
      c = (c >> 1) ^ ((c & 1) ? 0xedb88320 : 0);
    table[i] = c;
  }
  if (argc == 5 && !strcmp(argv[1], "--test-stdio")) {
    test_mode = 1;
    boot_permission = 1;
    for (int i = 0; i < 3; i++)
      paths[i] = argv[i + 2];
    input = 0;
    output = 1;
    serve();
    if (disk >= 0 && writing)
      fdatasync(disk);
    close_disk();
    return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "--allow-boot-writes"))
    boot_permission = 1;
  else if (argc != 1)
    return 2;
  int ep0 = open("/dev/ffs-tempo/ep0", O_RDWR | O_CLOEXEC);
  if (ep0 < 0 || descriptors(ep0)) {
    perror("FunctionFS descriptors");
    return 1;
  }
  FILE *ready = fopen("/run/transfer-ready", "w");
  if (ready)
    fclose(ready);
  struct usb_functionfs_event event;
  for (;;) {
    if (read(ep0, &event, sizeof(event)) != sizeof(event)) {
      if (errno == EINTR)
        continue;
      break;
    }
    fprintf(stderr, "FunctionFS event %u\n", event.type);
    if (event.type != FUNCTIONFS_ENABLE)
      continue;
    output = open("/dev/ffs-tempo/ep1", O_WRONLY | O_CLOEXEC);
    input = open("/dev/ffs-tempo/ep2", O_RDONLY | O_CLOEXEC);
    fprintf(stderr, "endpoints in=%d out=%d\n", input, output);
    if (input >= 0 && output >= 0)
      serve();
    fprintf(stderr, "session ended: %s\n", strerror(errno));
    if (disk >= 0) {
      state("stopping", "Connection interrupted", "Synchronizing storage", 1);
      if (writing)
        fdatasync(disk);
      state("error", "Transfer interrupted", "Reconnect to retry", 1);
      close_disk();
    }
    if (input >= 0)
      close(input);
    if (output >= 0)
      close(output);
    context_title[0] = context_detail[0] = 0;
    if (reconnect_usb()) {
      perror("Recovery USB reconnect");
      break;
    }
    state("ready", "Recovery Ready", "Transfer interrupted; ready to retry", 1);
  }
  close(ep0);
  return 1;
}
