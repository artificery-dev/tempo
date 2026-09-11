# Account templates

Every file in the image that names the device's user account, with `@USER@`,
`@UID@` and `@GID@` where the account's name and ids go. The rootfs build
renders them once; the image also carries them under
`/usr/local/lib/tempo-system/account/`, so that first run on the device can
rename the account and render them again from the same source. Paths mirror
the image root. `etc/sudoers.d/10-tempo` is only rendered and installed when
the account has passwordless sudo.
