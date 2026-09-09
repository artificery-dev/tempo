#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Read-only Y2 display capture. Host policy owns transport and output PNG. */
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: device-screenshot OUTPUT.raw\n"); return 2; }
    FILE *compatible = fopen("/proc/device-tree/compatible", "rb");
    char board[1024] = {0};
    if (!compatible) { perror("compatible"); return 1; }
    size_t count = fread(board, 1, sizeof(board)-1, compatible);
    fclose(compatible);
    int y2 = 0, mtk = 0;
    for (size_t offset = 0; offset < count;) {
        size_t length = strnlen(board+offset, count-offset);
        if (!strcmp(board+offset, "innioasis,y2")) y2 = 1;
        if (!strcmp(board+offset, "mediatek,mt6582")) mtk = 1;
        offset += length+1;
    }
    if (!y2 || !mtk) { fprintf(stderr, "only Innioasis Y2/MT6582 is supported\n"); return 1; }
    int memory = open("/dev/mem", O_RDONLY | O_SYNC);
    if (memory < 0) { perror("/dev/mem"); return 1; }
    void *registers = mmap(NULL, 4096, PROT_READ, MAP_SHARED, memory, 0x14007000);
    if (registers == MAP_FAILED) { perror("OVL mmap"); close(memory); return 1; }
    uint32_t address = *(volatile uint32_t *)((char *)registers + 0x40);
    munmap(registers, 4096);
    if (!address || address > UINT32_MAX - 480*360*2) { fprintf(stderr, "no valid scanout buffer\n"); close(memory); return 1; }
    size_t size = 480*360*2, offset = address & 4095;
    size_t mapped = (offset + size + 4095) & ~(size_t)4095;
    void *frame = mmap(NULL, mapped, PROT_READ, MAP_SHARED, memory, address & ~(uint32_t)4095);
    if (frame == MAP_FAILED) { perror("framebuffer mmap"); close(memory); return 1; }
    int output = open(argv[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int result = 0;
    if (output < 0) { perror("output"); result = 1; }
    else {
        size_t written = 0;
        while (written < size) {
            ssize_t length = write(output, (char *)frame + offset + written, size-written);
            if (length < 0 && errno == EINTR) continue;
            if (length <= 0) { perror("write"); result = 1; break; }
            written += (size_t)length;
        }
        if (close(output) != 0) { perror("close"); result = 1; }
    }
    munmap(frame, mapped); close(memory);
    if (!result) printf("scanout 0x%x\n", address);
    return result;
}
