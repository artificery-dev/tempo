// Linux-only ioctl/exec boundary; boot policy lives in Dart.
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int tempo_volume_keys_held(void) {
    DIR *directory = opendir("/dev/input");
    if (!directory) return 0;
    struct dirent *entry;
    unsigned int seen = 0;
    while ((entry = readdir(directory))) {
        if (strncmp(entry->d_name, "event", 5)) continue;
        char path[512];
        snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        unsigned char keys[16] = {0};
        if (ioctl(fd, EVIOCGKEY(sizeof(keys)), keys) >= 0) {
            if (keys[KEY_VOLUMEDOWN / 8] & (1 << (KEY_VOLUMEDOWN % 8))) seen |= 1;
            if (keys[KEY_VOLUMEUP / 8] & (1 << (KEY_VOLUMEUP % 8))) seen |= 2;
        }
        close(fd);
    }
    closedir(directory);
    return seen == 3;
}

int tempo_launch(int debug) {
    const char *binary = "/usr/local/bin/flutter-pi";
    if (debug) {
        execl(binary, binary, "--pixelformat", "RGB565", "/opt/tempo/flutter_assets",
              "--vm-service-port=41200", "--vm-service-host=0.0.0.0",
              "--disable-service-auth-codes", (char *)NULL);
    } else {
        execl(binary, binary, "--release", "--pixelformat", "RGB565",
              "/opt/tempo/flutter_assets", (char *)NULL);
    }
    perror("exec flutter-pi");
    return 127;
}
