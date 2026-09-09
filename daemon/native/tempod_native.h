#ifndef TEMPOD_NATIVE_H
#define TEMPOD_NATIVE_H
#include <stddef.h>
#include <stdint.h>

/* ABI 1. A runtime handle is owned by one caller and consumed by stop. */
uint32_t tempod_native_abi_version(void);
/* activated_fd == -1: bind socket_path. Otherwise take an inherited listening
 * AF_UNIX fd on success; leave the original fd intact on failure.
 * Errors are NUL-terminated in the caller-owned buffer when capacity > 0. */
void *tempod_native_start(const char *socket_path, int32_t activated_fd,
                         char *error, size_t error_capacity);
/* May block waiting for existing control handlers; call off the UI/main loop. */
void tempod_native_stop(void *runtime);
#endif
