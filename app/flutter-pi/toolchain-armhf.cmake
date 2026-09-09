# CMake toolchain file for the device: Debian bookworm armhf.
#
# Used inside the toolchain container (platform/toolchain/Containerfile), which
# carries Debian's cross gcc plus bookworm's armhf libraries installed through
# multiarch. There is no sysroot: the target headers and libraries sit at their
# real paths (/usr/include/arm-linux-gnueabihf, /usr/lib/arm-linux-gnueabihf)
# and the cross gcc already searches them, so all this file has to do is name
# the compiler and keep pkg-config honest about which architecture it answers
# for. Linking against the very same packages the rootfs installs is what makes
# the resulting binary ABI-exact for the device.
#
#   cmake -DCMAKE_TOOLCHAIN_FILE=app/flutter-pi/toolchain-armhf.cmake ...

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR armv7l)

set(CMAKE_C_COMPILER arm-linux-gnueabihf-gcc)
set(CMAKE_ASM_COMPILER arm-linux-gnueabihf-gcc)

# Multiarch layout: find_library/find_path look under lib/arm-linux-gnueabihf.
set(CMAKE_LIBRARY_ARCHITECTURE arm-linux-gnueabihf)

# pkg-config must describe the target, not the build host. PKG_CONFIG_LIBDIR
# replaces the default search list outright (PKG_CONFIG_PATH only prepends),
# so the host's x86_64 .pc files cannot leak into the link.
set(ENV{PKG_CONFIG_LIBDIR} "/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig")
set(ENV{PKG_CONFIG_PATH} "")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "")

# Tools run on the host; only libraries and headers are target things.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
