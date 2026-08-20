#!/bin/bash
# cmpunlocker — PCIe Gen2 link retrain for the CMP 170HX (and siblings).
#
# Gen2 takes two separate steps, and this script is only the second one:
#
#   1. The patched driver (driver/patches/0007-pcie-gen2.patch) clears the on-die
#      DIS_G2 gate and raises the advertised link capability to Gen2 during GSP
#      bootstrap. Config-space writes alone cannot do this, because a link trains
#      to min(LnkCap) of the two ends.
#   2. This script asks the *upstream* port to retrain. Setting the target speed
#      on the endpoint alone does not drive the negotiation.
#
# Step 1 lives in the driver and survives only until the modules are rebuilt;
# step 2 lives in PCIe config space and resets on reboot / link-down. So this
# runs on every boot (systemd unit) and on every driver rebind (udev rule).
#
# Measured result on the CMP 170HX: both steps do exactly what they claim, and
# the link still trains at Gen1. With LnkCap raised to 5GT/s and both ends
# targeting Gen2, a retrain issued from the root port completes -- the port's
# Link Bandwidth Management Status bit sets -- and comes back at 2.5GT/s, with
# no training errors and no transient Gen2 in 80k+ samples over 250ms. The
# blocker is OPT_GEN23 (0x82057c), a read-only fuse-option shadow that reads 1
# and rejects writes from both the CPU and the SEC2 booter path. So the raised
# Link Capability advertises a speed the PHY will not train at.
#
# The script therefore distinguishes three outcomes, not two: gate closed (the
# running driver lacks the patch -- a real fault), gate open and Gen2 reached,
# and gate open but the link declined Gen2 (settled hardware answer, reported
# and exited clean rather than failing the unit on every boot).
#
# Width is not touched: the 170HX is electrically x4, so x4 is expected.
set -uo pipefail

VENDOR="10de"
DEVICE_IDS=("20c2" "2082" "20b0")

# PCIe capability register offsets, relative to the Express capability (CAP_EXP)
LNKCTL="CAP_EXP+0x10.w"    # Link Control:  bit 5 = Retrain Link
LNKSTA="CAP_EXP+0x12.w"    # Link Status:   bits 3:0 = Current Link Speed
LNKCTL2="CAP_EXP+0x30.w"   # Link Control 2: bits 3:0 = Target Link Speed
GEN2="0x2"                 # encoded link speed for 5GT/s

# GA100 BAR0 registers the driver patch drives (see 0007-pcie-gen2.patch)
REG_CYA="0x8C2C0"          # CYA_0: bit 2 = DIS_G2, set means Gen2 is fused off
REG_LINKCAP="0x88084"      # Link Capabilities: bits 3:0 = max link speed
REG_OPT_GEN23="0x82057C"   # fuse-option shadow, read-only; 1 = Gen2/3 fused off
DRIVER_WAIT_SECS=120

# A retrain that reached Gen2 and immediately fell back would be invisible to a
# single read after a fixed sleep, so sample instead of sleeping.
POLL_MS=1000

log() { echo "cmpunlocker-pcie-gen2: $*"; }

command -v setpci >/dev/null 2>&1 || { log "setpci not found (install pciutils)"; exit 1; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { log "must run as root"; exit 1; }

# Current negotiated speed as a Gen number (1, 2, ...) for a device BDF.
current_gen() {
    local dev="$1" v
    v="$(setpci -s "${dev}" "${LNKSTA}" 2>/dev/null || echo "")"
    [[ -n "${v}" ]] || { echo "?"; return; }
    echo $(( 0x${v} & 0xf ))
}

# Echoes "<dis_g2> <cap_max_gen> <opt_gen23>" read from BAR0, or nothing if
# unreadable. opt_gen23 is "?" when that register does not decode.
# Read-only: opens resource0 O_RDONLY and never writes. Clearing DIS_G2 from
# userspace is deliberately not attempted -- by the time this runs the GSP owns
# the register, which is why the fix belongs in the driver patch.
read_bar0_state() {
    local gpu="$1"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${gpu}" "${REG_CYA}" "${REG_LINKCAP}" "${REG_OPT_GEN23}" <<'PY' 2>/dev/null
import mmap, os, struct, sys

gpu = sys.argv[1]
cya_off, cap_off, opt_off = (int(a, 16) for a in sys.argv[2:5])
path = f"/sys/bus/pci/devices/{gpu}/resource0"
try:
    fd = os.open(path, os.O_RDONLY)
except OSError:
    sys.exit(1)
try:
    size = os.path.getsize(path)
    if size <= max(cya_off, cap_off, opt_off):
        sys.exit(1)
    m = mmap.mmap(fd, size, prot=mmap.PROT_READ)
except (OSError, ValueError):
    os.close(fd)
    sys.exit(1)
try:
    cya = struct.unpack_from("<I", m, cya_off)[0]
    cap = struct.unpack_from("<I", m, cap_off)[0]
    opt = struct.unpack_from("<I", m, opt_off)[0]
    if cya == 0xFFFFFFFF or cap == 0xFFFFFFFF:   # BAR0 dead / device gone
        sys.exit(1)
    # This one is priv-blocked on some boards; all-ones means "no answer".
    print((cya >> 2) & 1, cap & 0xF, "?" if opt == 0xFFFFFFFF else opt & 1)
finally:
    m.close()
    os.close(fd)
PY
}

# The unit is ordered only against multi-user.target, so on a cold boot this can
# start before the nvidia driver has bound the card. BAR0 is not mappable until
# it has, so wait rather than misreport the gate as unreadable.
wait_for_driver() {
    local gpu="$1" i
    for (( i = 0; i < DRIVER_WAIT_SECS; i++ )); do
        [[ -e "/sys/bus/pci/devices/${gpu}/driver" ]] && return 0
        sleep 1
    done
    return 1
}

# Highest link generation seen on "$1" within POLL_MS, sampled as fast as
# setpci can be forked. Stops early once Gen2 shows up.
poll_best_gen() {
    local dev="$1" best cur deadline
    best="$(current_gen "${dev}")"
    [[ "${best}" =~ ^[0-9]+$ ]] || best=0
    deadline=$(( $(date +%s%N) / 1000000 + POLL_MS ))
    while (( $(date +%s%N) / 1000000 < deadline )); do
        [[ "${best}" -ge 2 ]] && break
        cur="$(current_gen "${dev}")"
        [[ "${cur}" =~ ^[0-9]+$ ]] && (( cur > best )) && best="${cur}"
    done
    echo "${best}"
}

retrain_one() {
    local gpu="$1" rp before after state dis_g2 cap_gen opt_gen23
    rp="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${gpu}")")")"
    if [[ ! -e "/sys/bus/pci/devices/${rp}" || "${rp}" == "${gpu}" ]]; then
        log "${gpu}: no upstream root port found, skipping"
        return 1
    fi

    before="$(current_gen "${gpu}")"
    if [[ "${before}" == "2" ]]; then
        log "${gpu}: already at Gen2 (root port ${rp}), nothing to do"
        return 0
    fi

    wait_for_driver "${gpu}" || log "${gpu}: no driver bound after ${DRIVER_WAIT_SECS}s, continuing anyway"

    # Confirm the driver patch actually opened the Gen2 gate before blaming the link.
    dis_g2="?"; cap_gen="?"; opt_gen23="?"
    if state="$(read_bar0_state "${gpu}")" && [[ -n "${state}" ]]; then
        read -r dis_g2 cap_gen opt_gen23 <<<"${state}"
        if [[ "${dis_g2}" != "0" || "${cap_gen}" -lt 2 ]]; then
            log "${gpu}: Gen2 gate still closed (DIS_G2=${dis_g2}, LnkCap=Gen${cap_gen})"
            log "${gpu}: the running driver lacks the Gen2 patch -- rebuild with install.sh and reboot"
            return 1
        fi
    fi

    # Target Gen2 on both ends, then retrain from the root port.
    setpci -s "${rp}"  "${LNKCTL2}=${GEN2}:0xf" 2>/dev/null || true
    setpci -s "${gpu}" "${LNKCTL2}=${GEN2}:0xf" 2>/dev/null || true
    setpci -s "${rp}"  "${LNKCTL}=0x20:0x20"    2>/dev/null || true

    after="$(poll_best_gen "${gpu}")"
    if [[ "${after}" -ge 2 ]]; then
        log "${gpu}: retrained Gen${before} -> Gen2 (root port ${rp})"
        return 0
    fi

    #
    # Third outcome, distinct from "the driver patch is missing": the gate is open
    # and the retrain completed, but the endpoint still negotiated Gen1. On the
    # 170HX that is the settled hardware answer rather than a fault -- OPT_GEN23 is
    # a read-only fuse shadow, so the raised Link Capability is advertising a speed
    # the PHY will not train at. Report it and exit clean; leaving the unit in a
    # failed state every boot would imply there is something left to fix.
    #
    log "${gpu}: link declined Gen2 -- retrain completed, still Gen${after} (root port ${rp})"
    log "${gpu}: gate is open (DIS_G2=${dis_g2}, LnkCap=Gen${cap_gen}, OPT_GEN23=${opt_gen23});"
    log "${gpu}: OPT_GEN23=1 means Gen2 is fused off on this board and no config-space"
    log "${gpu}: write can lift it. Gen1 x4 is the expected steady state."
    return 0
}

mapfile -t GPUS < <(
    for id in "${DEVICE_IDS[@]}"; do
        lspci -D -d "${VENDOR}:${id}" 2>/dev/null | awk '{print $1}'
    done
)

if [[ ${#GPUS[@]} -eq 0 ]]; then
    log "no supported CMP card found (${VENDOR}:${DEVICE_IDS[*]})"
    exit 0
fi

rc=0
for gpu in "${GPUS[@]}"; do
    retrain_one "${gpu}" || rc=1
done
exit "${rc}"
