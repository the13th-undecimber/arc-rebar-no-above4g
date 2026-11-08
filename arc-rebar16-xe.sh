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
    echo simple-framebuffer.0 > "$SFB/unbind" 2>/dev/null \
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
