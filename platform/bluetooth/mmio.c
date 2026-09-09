/* Aligned MMIO, mapping and descriptor ownership for the modem bootstrap. */
#define _FILE_OFFSET_BITS 64
#define _GNU_SOURCE
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/file.h>
#include <unistd.h>

static void before_write(void) {
#if defined(__arm__) || defined(__aarch64__)
    __asm__ volatile("dmb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
}
static void after_write(void) {
#if defined(__arm__) || defined(__aarch64__)
    __asm__ volatile("dsb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
}
uint32_t md_read32(volatile uint32_t *p) { uint32_t v = *p; before_write(); return v; }
void md_write32(volatile uint32_t *p, uint32_t v) { before_write(); *p = v; after_write(); }
int md_euid(void) { return (int)geteuid(); }
int md_open(void) { return open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC); }
void *md_map(int fd, uint64_t address, uint32_t size) {
    void *result = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)address);
    return result == MAP_FAILED ? NULL : result;
}
int md_unmap(void *address, uint32_t size) { return munmap(address, size); }
int md_close(int fd) { return close(fd); }
int md_lock(void) {
    int fd = open("/run/tempo-modem-bootstrap.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}
