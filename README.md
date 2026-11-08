# Intel Arc Large BAR on HP systems without Above 4G Decoding

Nov 8, 2026 · @13th

Enables Resizable BAR (16 GiB Large BAR) for Intel Arc GPUs on older HP machines whose firmware has no Above 4G Decoding option at all. No BIOS mod, no firmware flashing: two kernel parameters and one script.

## Read this first

1. **Only tested on HP machines.** Other vendors are unverified.
2. **Linux only.** This does not work on Windows.
3. **Only Large BAR itself is confirmed.** The BAR reaches 16 GiB and the whole of VRAM becomes CPU-visible. That is all that was measured.
4. **Gaming performance was not measured.** Whether anything gets faster is unknown.

## Verified systems

| System | Generation | GPU | Driver | OS |
| --- | --- | --- | --- | --- |
| HP Pavilion h8 | Sandy Bridge (2011) | Arc A770 16GB | i915 | Ubuntu 24.04 / kernel 6.8 |
| HP Z230 | Haswell (2013) | Arc B580 12GB | xe | Ubuntu 26.04 / kernel 7.0 |
| HP Z240 | Skylake (2015) | Arc B580 12GB | xe | Ubuntu 26.04 / kernel 7.0 |

None of these has an Above 4G Decoding option in its BIOS. A secondary GPU is not required.

One disclosure about the Pavilion h8: its firmware had already been modified to disable the legacy CSM so the machine boots in pure UEFI, because Arc cards have no legacy VBIOS. That change was flashed from Windows with the vendor's own update path, not with an external programmer or a clip. The Z230 and Z240 run completely stock firmware. Nothing here depends on that modification — it only gets the h8 to UEFI boot in the first place.

## How it works

Two things are missing from these platforms, and this fills in both.

- The firmware publishes no MMIO window above 4 GiB, so there is nowhere to put a 16 GiB BAR → `pci=nocrs` makes Linux ignore `_CRS` and treat the whole address space as available.
- When growing a BAR, the kernel only reprograms the bridge directly above the device. Arc cards carry an onboard PCIe switch, which puts three bridges in the path, so that is not enough → write the ReBAR size directly, then force a full PCI re-enumeration so every bridge window in the chain is rebuilt.

## Files

| File | Use it for |
| --- | --- |
| `arc-rebar16-xe.sh` | Arc B-series (B580, B570) — driver `xe` |
| `arc-rebar16-i915.sh` | Arc A-series (A770, A750, A580) — driver `i915` |
| `arc-rebar16.service` | both |

Pick **one** of the two scripts. They are identical apart from `MODULE` and the matching comments, and both install to the same path, so the one service file works either way.

The `xe` version is shown below for reference.

```bash
#!/bin/bash
# Enable the 16 GiB resizable BAR on an Intel Arc GPU whose onboard PCIe switch
# puts two bridges between the GPU and its direct parent.
#
# Why this is needed: pci_resize_resource() only reprograms the bridge directly
# above the device, so growing BAR2 at runtime fails with -ENOSPC.  Setting the
# ReBAR size first and then forcing a full re-enumeration makes Linux size every
# bridge window in the chain, drawing from the >4 GiB root-bus window that
# pci=nocrs opens up.
#
# Required on the kernel command line:
#   pci=nocrs              so the root bus has address space above 4 GiB
#   modprobe.blacklist=xe  so the driver does not bind before this runs

set -u

DEV=0000:03:00.0          # Arc B-series (B580 / B570)
ROOTPORT=0000:00:01.0     # CPU root port above the card's switch
REBAR_CTL=428             # Resizable BAR cap @0x420, entry-0 Control at +0x08
SIZE_IDX=14               # 2^14 MiB = 16384 MiB = 16 GiB
MODULE=xe

log() { logger -t arc-rebar16 -- "$*"; printf 'arc-rebar16: %s\n' "$*"; }
finish() { log "loading $MODULE"; modprobe "$MODULE" || log "modprobe $MODULE failed"; exit 0; }

[ -d "/sys/bus/pci/devices/$DEV" ] || { log "$DEV not present, nothing to do"; finish; }

cur=$(setpci -s "$DEV" "$REBAR_CTL.l") || { log "cannot read ReBAR control"; finish; }
curidx=$(( (0x$cur >> 8) & 0x3F ))

if [ "$curidx" -eq "$SIZE_IDX" ]; then
    log "ReBAR already at size index $SIZE_IDX (16 GiB)"
    finish
fi

# Refuse to touch a device that already has a driver bound.  Clearing COMMAND and
# removing the root port under a live xe/i915 deadlocks in the driver's remove
# path while device_lock is held, which wedges the whole machine.  Reaching this
# point means modprobe.blacklist= is missing from the kernel command line, or
# someone ran this by hand on a running desktop.
if [ -e "/sys/bus/pci/devices/$DEV/driver" ]; then
    drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$DEV/driver")")
    log "ABORT: driver '$drv' is bound to $DEV and the BAR is not yet $SIZE_IDX."
    log "       resizing now would hang the machine. check modprobe.blacklist=$MODULE"
    exit 0
fi

sup=$(cat "/sys/bus/pci/devices/$DEV/resource2_resize" 2>/dev/null) || sup=0
if [ $(( 0x$sup & (1 << SIZE_IDX) )) -eq 0 ]; then
    log "size index $SIZE_IDX not advertised (supported bitmap 0x$sup), leaving BAR alone"
    finish
fi

log "ReBAR size index $curidx -> $SIZE_IDX; disabling memory decode on $DEV"
setpci -s "$DEV" COMMAND=0000 || { log "failed to clear COMMAND"; finish; }

new=$(printf '%08x' $(( (0x$cur & ~0x3F00) | (SIZE_IDX << 8) )))
setpci -s "$DEV" "$REBAR_CTL.l=$new" || { log "failed to write ReBAR control"; finish; }
log "ReBAR control 0x$cur -> 0x$new"

# At boot the Plymouth splash may be drawing on simpledrm, which scans out the
# UEFI GOP framebuffer inside the old BAR2.  Let it go before that memory moves.
# Cosmetic only: the splash ends a few seconds early.
if command -v plymouth >/dev/null 2>&1 && plymouth --ping >/dev/null 2>&1; then
    log "asking plymouth to quit before the framebuffer moves"
    plymouth quit >/dev/null 2>&1 || log "plymouth quit failed (continuing)"
fi

# The UEFI GOP framebuffer lives inside the old BAR2, and simpledrm is still
# scanning it out.  Detach it before the window moves so nothing writes to a
# region that is about to disappear.  Harmless if simpledrm is absent or xe has
# already evicted it.
SFB=/sys/bus/platform/drivers/simple-framebuffer
if [ -e "$SFB/simple-framebuffer.0" ]; then
    log "unbinding simpledrm from simple-framebuffer.0"
    echo simple-framebuffer.0 > "$SFB/unbind" 2>/dev/null \\
        || log "simpledrm unbind failed (continuing)"
fi

# Do NOT re-enable memory decode here: with the larger size the old base address
# is truncated to 0, so the BAR would overlap DRAM.  The rescan reprograms it and
# the driver enables decode via pci_enable_device().
log "removing $ROOTPORT subtree and rescanning"
echo 1 > "/sys/bus/pci/devices/$ROOTPORT/remove" || { log "remove failed"; finish; }
echo 1 > /sys/bus/pci/rescan                     || { log "rescan failed"; finish; }

# The rescan write returns once enumeration is done, but the sysfs attributes of
# the re-created device can lag slightly.  Wait up to 5 s rather than racing it.
for _ in $(seq 1 50); do
    [ -r "/sys/bus/pci/devices/$DEV/resource" ] && break
    sleep 0.1
done
[ -r "/sys/bus/pci/devices/$DEV/resource" ] || log "$DEV did not reappear after rescan"

# resource line 3 is BAR2; the values already carry a 0x prefix that bash
# arithmetic understands, so do not prepend another one.
if [ -r "/sys/bus/pci/devices/$DEV/resource" ]; then
    read -r s e _ < <(sed -n 3p "/sys/bus/pci/devices/$DEV/resource")
    log "BAR2 after rescan: $s-$e ($(( (e - s + 1) / 1048576 )) MiB)"
fi

finish
```

Adjust the variables at the top for your machine.

| Variable | How to find it |
| --- | --- |
| `DEV` | `lspci -nn \| grep -iE 'VGA\|Display'` |
| `ROOTPORT` | the topmost root port above the GPU, from `lspci -t` |
| `REBAR_CTL` | start of the Resizable BAR capability + `0x08`, from `sudo lspci -s <DEV> -vv \| grep -A3 'Physical Resizable BAR'` |
| `SIZE_IDX` | log2(size in MiB): 14 for 16 GiB, 13 for 8 GiB. Check support with `cat /sys/bus/pci/devices/<DEV>/resource2_resize` |
| `MODULE` | `xe` for Arc B-series, `i915` for Arc A-series. Already set correctly in each script |

`arc-rebar16.service`:

```ini
[Unit]
Description=Enable the large resizable BAR on an Intel Arc GPU, then load its driver
Documentation=man:setpci(8)
Before=display-manager.service graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/arc-rebar16.sh

[Install]
WantedBy=multi-user.target
```

## Install

**1. Edit `/etc/default/grub`**

```bash
sudo nano /etc/default/grub
```

Add `pci=nocrs` and the blacklist entry for your card's driver inside the quotes of the line that is already there. **Use the one that matches your card.**

Arc B-series (B580 / B570), driver `xe`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pci=nocrs modprobe.blacklist=xe"
```

Arc A-series (A770 / A750 / A580), driver `i915`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pci=nocrs modprobe.blacklist=i915"
```

The blacklisted module has to match the `MODULE` line in the script you install in step 2. Getting those two out of step is the easiest mistake to make here: the script will refuse to run and log `ABORT: driver ... is bound`.

`quiet splash` is just what Ubuntu ships; keep whatever your line already had and only add to it. Then set the two timeout lines, which are the same for both cards:

```
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
```

They keep the GRUB menu reachable at boot, which is the recovery path if anything goes wrong. Put your own values back once things are stable.

Save with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`, and apply:

```bash
sudo update-grub
```

**2. Install the files**

Download both files first. The commands below only work from the directory the files are actually in, so change into your download folder before running them:

```bash
cd ~/Downloads     # wherever your browser saved them
ls arc-rebar16*    # both files should be listed here
```

If `ls` shows nothing, you are in the wrong directory. Then install — use the script that matches your card:

```bash
# Arc B-series (B580 / B570)
sudo install -m 755 arc-rebar16-xe.sh /usr/local/sbin/arc-rebar16.sh

# Arc A-series (A770 / A750 / A580)
sudo install -m 755 arc-rebar16-i915.sh /usr/local/sbin/arc-rebar16.sh
```

Note that both commands install to the same destination name, `/usr/local/sbin/arc-rebar16.sh`. That is intentional. Then the unit, which is the same for both:

```bash
sudo install -m 644 arc-rebar16.service /etc/systemd/system/arc-rebar16.service
sudo systemctl daemon-reload
sudo systemctl enable arc-rebar16.service
```

`Created symlink ...` means it is registered.

**3. Reboot**

Do not run the script by hand at this point. Running it while the driver is still bound deadlocks the machine; the script detects this and aborts.

## Verify

```bash
journalctl -b -t arc-rebar16
sudo lspci -s <DEV> -vv | grep -E 'Region 2|current size'
```

`BAR2 after rescan: ... (16384 MiB)` and `current size: 16GB` mean it worked. Then check the driver's own view:

```bash
sudo dmesg | grep -iE 'VISIBLE VRAM|CPU accessible|Small BAR'   # xe
sudo dmesg | grep -i 'local memory'                             # i915
```

On `xe`, `CPU accessible size` should equal `usable size` and `Small BAR device` should be gone. On `i915`, `Local memory IO size` should equal `Local memory available`.

## Reverting

At the GRUB menu press `e`, delete `modprobe.blacklist=...` from the `linux` line and boot with `Ctrl+X`. You are back to the old 256 MiB behaviour. Then disable the unit:

```bash
sudo systemctl disable arc-rebar16.service
```

Remove `pci=nocrs` from `/etc/default/grub` and run `sudo update-grub` to undo the rest.

## Caveats and limitations

- **`pci=nocrs` makes Linux ignore the firmware's resource description.** It can collide with reserved regions. Check once after installing, and again after any hardware change: `sudo dmesg | grep -iE 'BAR .*(failed|no space|conflict)|resource.*conflict'`
- **`remove`/`rescan` runs on every boot.** The script always falls through to `modprobe`, so the worst case is booting with the old 256 MiB BAR.
- **UEFI boot is required.** Arc cards have no legacy VBIOS.

## License and credits

Do whatever you like with this. Modify and redistribute freely, no attribution needed. **No warranty** — use at your own risk.

The analysis and this document were produced with Claude (Anthropic).

## References

- [drm/i915: Add lmem\_bar\_size modparam](https://www.spinics.net/lists/intel-gfx/msg301189.html)
- [PATCH v2 00/11 PCI: BAR resizing fix/rework](https://ratatoskr.run/intel-gfx/2025/11/9267704/t)
- [PATCH 0/2 PCI: BAR resize rollback fixes](https://ratatoskr.run/lkml/2026/01/3380010/t)
- [arc-rebar — prior work, for systems that do have Above 4G Decoding](https://github.com/RodBurlamaqui/Intel-ARC-Rebar)
