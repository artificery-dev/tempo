# Connecting to the device

Tempo is a normal Linux system, and the USB cable that charges the Y2 is
also the way into it. Plug the player into a computer and it appears as a
small network adapter and a serial port at the same time: you can `ssh` to
it by address or by name, or open the serial port and find yourself already
logged in. WiFi joins your home network from the settings tree, Bluetooth
pairs a speaker or headphones, and a key chord at boot starts the player in a
debug mode a developer can attach to. This page covers each of these from the
point of view of someone holding the device. The developer pages linked
along the way explain how each piece is put together.

## The USB cable

When the Y2 boots with the cable connected, the computer sees one USB device
with two functions: a CDC-ECM network adapter and a CDC-ACM serial port.
Nothing has to be configured on the computer for the network side, because
the player does the work. It gives itself the address `10.42.0.1` on the
cable and runs a DHCP server there, so the computer's new network interface
receives an address in `10.42.0.0/24` the moment it comes up.

| On the cable | Value |
| --- | --- |
| The player's address | `10.42.0.1` |
| The player's name | `tempo.local` |
| The account | `tempo` |
| The serial port | A USB ACM device, `/dev/ttyACM0` on most Linux hosts |

The name `tempo.local` is advertised by the player over multicast DNS, so a
computer that resolves `.local` names can use it instead of the address. It
works over the cable and, once WiFi is up, over the network too.

The cable never gives the player a route to the Internet by itself. Only the
computer can share its connection, and on Linux the developer tooling does
that with `toolbox dev device link up --share`; see
[Working with a device](../development/device.md) for what that command
configures. Without it, the player can be reached from the computer but
cannot reach out through it.

## Logging in with ssh

```sh
ssh tempo@10.42.0.1
```

or, by name,

```sh
ssh tempo@tempo.local
```

The account is `tempo`. It has no fixed password: whoever built the firmware
image chose either a password, an SSH public key, or both, and an image with
neither cannot be built. If you flashed a package someone else made, ask them
what they set. If you built it yourself, it is whatever you put in your local
configuration. Password login over ssh is enabled, and any configured key is
already in the account's `authorized_keys`. Logging in as `root` over ssh is
disabled and root's password is locked; use `sudo` from the `tempo` account
instead, which asks for no password.

```sh
sudo systemctl status tempo.service
```

The player generates its ssh host keys the first time it boots, so two Y2s
flashed from the same image have different fingerprints, and a device that
has had its root filesystem reinstalled presents a new fingerprint. Expect
your ssh client to warn about a changed host key after a reinstall.

The player's own interface keeps running while you are logged in. The shell
is zsh with Oh My Zsh, and the usual tools are installed: `git`, `curl`,
`vim`, `htop`, `tmux`, `rsync`, `jq` and `sqlite3` among others. `apt` works
once the player has a way to the Internet, over WiFi or over a shared cable.

## The serial console

The same cable carries a serial port. On the computer it shows up as a USB
ACM device, `/dev/ttyACM0` on a Linux host with no other such device. Open it
with any terminal program at 115200 baud and you get a shell on the player,
already logged in as `tempo`.

```sh
screen /dev/ttyACM0 115200
```

There is no login prompt to get past and no password to enter on this port,
which is why it is the tool to reach for when networking is not answering:
it works as soon as the root filesystem is up, before any address exists on
the cable. Unplugging and replugging the cable brings the console back
without any action on the player. The panel itself never shows a console;
the player owns the screen.

The kernel's own boot messages do not appear on this port. They go to a
hardware serial line that is not wired to the outside of the case, so what
you see on the USB console starts with the login shell.

## WiFi

WiFi is off by default. Turn it on and join a network from the settings
tree: Settings, then Connections, then Wi-Fi.

| Row | What it does |
| --- | --- |
| Wi-Fi | Reads "Off — select to turn on" or "On — select to turn off". Press the center to flip it. |
| Scan again | Searches for networks. While Wi-Fi is off this row reads Refresh and only rereads the state. |
| Saved Networks | The networks the player has joined before. |
| One row per network found | The name, then "Connected" or "Saved", the signal as bars out of three, and "Secured" for a protected network. |

While a scan is running the page reads "Working…", and a scan that finds
nothing reads "Nothing found. Try scanning again."

Selecting a network opens its own page. A secured network you have not
joined before shows a Password field. Because the Y2 has no keyboard, the
Enter Password row opens a list of characters to walk with the wheel: Done
and Delete Last Character at the top, then letters, digits, Space and
punctuation. Press the center on each character to add it, and Done to come
back. Then press Connect. The player joins, takes an address from the
network by DHCP and remembers the network, so it appears under Saved
Networks from then on. A network page also offers Disconnect while
connected and Forget Network for a saved one.

Open networks and networks with an ordinary WPA password are supported. A
network that needs a username, an old WEP key or WPA3 only shows "Enterprise,
WEP and WPA3-only networks are not supported yet." and cannot be joined.
Trying to connect while the radio is off shows "Turn on Wi-Fi to connect."

Once connected, the status bar shows the WiFi icon and `apt`, `curl` and the
rest can reach the Internet. When both the cable and WiFi are up, the cable
stays the player's default route, so a computer sharing its connection keeps
working.

One thing does not change when WiFi comes up: you still cannot `ssh` to the
player over it. The firewall trusts the USB cable completely and accepts
nothing inbound from any other network, and that is the shipped default.
Opening ssh over WiFi means allowing port 22 in the firewall, either when the
image is built or at a shell on the device:

```sh
sudo ufw allow 22/tcp
```

Do this only on a network you trust, and remember that the `tempo` account
has passwordless `sudo`. [Wifi](../porting/wifi.md) describes the radio,
the driver and the supplicant underneath this screen, and
[Root filesystem](../platform/rootfs.md) the firewall policy.

## Bluetooth audio

Bluetooth is for listening: the player sends stereo audio to a speaker or a
pair of headphones, and the buttons on that device control playback. It is
off by default. Settings, then Connections, then Bluetooth opens the screen.

| Row | What it does |
| --- | --- |
| Bluetooth | Reads "Off — select to turn on" or "On — select to turn off". Press the center to flip it. |
| Scan again | Looks for audio devices for five seconds. Refresh while the radio is off only rereads the state. |
| One row per device | Its name, then "Connected", "Paired" or "Available". |

Only devices that offer stereo audio playback are listed, so a phone or a
keyboard does not appear even when it is discoverable. Put the speaker or
headphones into pairing mode first, then scan.

Selecting a device opens its page. An unpaired device reads "Put the device
in pairing mode. PIN and passkey pairing are not supported yet." and offers
Pair & Connect. A paired device shows its address and offers Connect, or
Disconnect while connected, and Forget Device, which removes the pairing.
Devices that ask for a PIN or want you to confirm a code on both ends cannot
be paired.

When a Bluetooth device connects, what happens next depends on On New Audio
Device Detected under Settings, Sound, Output:

| Setting | Effect |
| --- | --- |
| Switch, the default | The sound moves to the device at once. |
| Ask | The screen turns on and a card asks "Switch to <device name>?", with Switch and Keep Current. Turn the wheel to pick one and press the center; Menu keeps the current output. |
| Ignore | Nothing moves; the device stays connected and silent. |

The question only comes up when the sound would move between the player's
own speaker or headphones and a Bluetooth device. Plugging headphones in or
out never asks; that switch is automatic. While a Bluetooth device is
connected the volume card names it and shows its level, and its own play,
pause, next and previous controls drive the player.
[Bluetooth](../porting/bluetooth.md) covers pairing, the audio path and the
remote control in depth.

## The debug build

The player normally runs a compiled release build of its interface. The same
installed software can also start in a debug mode, which runs the interface
from source in the Dart VM and opens the Dart VM service for a developer to
attach to. Nothing needs to be flashed to use it.

Hold both volume keys while the player starts. That is at power on, or
whenever the player interface is restarted, since the check happens each time
it launches. When both keys are down at that moment the interface comes up in
debug mode, with the VM service listening on port 41200 without an
authentication code. The firewall only admits that port over the USB cable,
so the service is reachable from the connected computer and nowhere else.
From a Tempo checkout, `toolbox dev app attach` connects to it:

```sh
toolbox dev app attach
```

Debug mode is slower than the release build and lasts until the interface is
next started without the keys held. Restart it normally, or reboot, to go
back. [Working with a device](../development/device.md) describes attaching,
deploying a fresh build over the cable and reading the logs;
[Root filesystem](../platform/rootfs.md) describes the launcher that reads
the keys.
