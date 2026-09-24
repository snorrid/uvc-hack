# uvc-hack

Patched `uvcvideo` driver installer for running several USB cameras on one USB
bus, e.g. for an [Autodarts](https://autodarts.io) board.

By default the Linux UVC driver lets MJPEG cameras reserve far more USB
bandwidth than they need, so a second or third camera often fails to start
(`No space left on device`). This script rebuilds the driver for your running
kernel with the payload size for compressed formats capped at `0x300` bytes.

Based on the original script at `get.autodarts.io/uvc`, rewritten to work on
current kernels (including 6.18+) and distros with compressed kernel modules
(Raspberry Pi OS, Debian 12+, Ubuntu 23.10+).

## Requirements

- Linux on a Debian-based distro (Raspberry Pi OS, Debian, Ubuntu). The script
  installs its build dependencies and kernel headers with `apt-get`.
- `sudo` access and an internet connection.
- Secure Boot disabled (the kernel refuses to load unsigned modules).

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/snorrid/uvc-hack/main/install_uvc_hack.sh)
```

Or from a clone:

```bash
git clone https://github.com/snorrid/uvc-hack.git
bash uvc-hack/install_uvc_hack.sh
```

The script:

1. Installs build tools and kernel headers if they're missing.
2. Downloads the uvc driver source matching your kernel (from the
   `raspberrypi/linux` fork on Raspberry Pi OS, mainline otherwise).
3. Applies the patch and compiles the module.
4. Installs it to `/lib/modules/$(uname -r)/updates/uvc/`, leaving the
   distro's driver untouched.
5. Reloads the driver, stopping and restarting the `autodarts` service around
   the reload if it's running.

If a camera is in use and the driver can't be unloaded, the script says so.
Reboot and the patched driver will be used.

### Check that it worked

Installed for the running kernel:

```bash
sudo modinfo -n uvcvideo
# should print /lib/modules/<kernel>/updates/uvc/uvcvideo.ko
```

Currently loaded (if this says "stock", reboot):

```bash
[ "$(cat /sys/module/uvcvideo/srcversion)" = "$(sudo modinfo -F srcversion uvcvideo)" ] \
    && echo "patched driver loaded" || echo "stock driver loaded"
```

## After a kernel upgrade

The patched driver is built for one kernel version. After a kernel upgrade
(e.g. `apt upgrade` followed by a reboot), the stock driver is used again, so
**re-run the install command**.

## Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/snorrid/uvc-hack/main/install_uvc_hack.sh) --uninstall
```

This removes the patched driver and reloads the stock one. It also cleans up
installs made by the original `get.autodarts.io/uvc` script.

## Options

| Variable           | Default | Description                                  |
| ------------------ | ------- | -------------------------------------------- |
| `UVC_PAYLOAD_SIZE` | `0x300` | Payload size to force for compressed formats |

```bash
UVC_PAYLOAD_SIZE=0x400 bash install_uvc_hack.sh
```

## Troubleshooting

- **`Patch did not apply`**: the driver source for your kernel changed in a way
  the patch doesn't recognise. Nothing was installed; please open an issue with
  your `uname -r` output.
- **`Kernel headers for ... are not installed`**: install the headers package
  for your kernel manually, then re-run.
- **`Secure Boot is enabled`**: disable Secure Boot in your firmware settings,
  or sign the module yourself.
