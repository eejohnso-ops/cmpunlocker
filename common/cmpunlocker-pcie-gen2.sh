#!/bin/bash
# cmpunlocker — PCIe Gen2 link retrain for the CMP 170HX (and siblings).
#
# Gen2 takes three steps, and this script is the last two of them:
#
#   1. The patched driver (driver/patches/0007-pcie-gen2.patch) clears the on-die
#      DIS_G2 gate and raises the advertised link capability to Gen2 during GSP
#      bootstrap.
#   2. By the time this script runs (full driver + RM/GSP init done), LINK_CONFIG_0
#      MAX_RATE has been observed reverted to 3 even though DIS_G2 stays cleared --
#      the normal post-boot RM/GSP bring-up resets it, independent of the SEC2-boot
#      write. So this script re-asserts DIS_G2 and MAX_RATE directly via a
#      userspace BAR0 mmap, immediately before retraining.
#   3. It then asks the *upstream* port to retrain. Setting the target speed on
#      the endpoint alone does not drive the negotiation.
#
# Step 1 lives in the driver and survives only until the modules are rebuilt;
# steps 2-3 reset on reboot, link-down, or any RM re-init, so this runs on every
# boot (systemd unit) and on every driver rebind (udev rule).
#
# History: an earlier version of this script treated BAR0 as read-only post-boot
# ("the GSP owns the register") and concluded OPT_GEN23 (0x82057c) was a
# read-only fuse blocking Gen2 permanently. That was wrong -- OPT_GEN23 was never
# the blocker. The working reference (amoghmunikote/cmpunlocker@746d9f7, the
# `gen2` branch) re-pokes DIS_G2/MAX_RATE right before retraining and reaches
# Gen2 on this same card. OPT_GEN23 is now read only for diagnostic logging.
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
REG_LINKCFG="0x8C040"      # LINK_CONFIG_0: bits 19:18 = MAX_RATE, 2 = Gen2
REG_OPT_GEN23="0x82057C"   # fuse-option shadow; diagnostic only, not gating
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
# unreadable. opt_gen23 is "?" when that register does not decode. Read-only:
# used before the write to confirm the driver patch is present at all (LnkCap
# raised to Gen2) -- a real fault, distinct from the post-boot reset this
# script's write step corrects.
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

# Re-asserts DIS_G2=0 and MAX_RATE=2 via a direct BAR0 mmap write, immediately
# before the retrain. This is a write, not a read, because by the time this
# service runs, post-boot RM/GSP init has been observed to revert MAX_RATE to
# 3 even though DIS_G2 stays cleared -- the SEC2-boot-time write alone does not
# survive to when the OS gets a chance to retrain the link. Echoes
# "<dis_g2> <max_rate> <alive>" read back after the write, or nothing on
# failure (unreadable/unwritable BAR0).
poke_bar0_gate() {
    local gpu="$1"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${gpu}" "${REG_CYA}" "${REG_LINKCFG}" <<'PY' 2>/dev/null
import mmap, os, struct, sys

gpu = sys.argv[1]
cya_off, link_off = (int(a, 16) for a in sys.argv[2:4])
path = f"/sys/bus/pci/devices/{gpu}/resource0"
try:
    fd = os.open(path, os.O_RDWR | os.O_SYNC)
except OSError:
    sys.exit(1)
try:
    size = os.path.getsize(path)
    if size <= max(cya_off, link_off):
        sys.exit(1)
    m = mmap.mmap(fd, size, access=mmap.ACCESS_WRITE)
except (OSError, ValueError):
    os.close(fd)
    sys.exit(1)

def r(off):
    return struct.unpack_from("<I", m, off)[0]

def w(off, val):
    struct.pack_into("<I", m, off, val & 0xFFFFFFFF)

try:
    if r(0) == 0xFFFFFFFF:   # BAR0 dead / device gone
        sys.exit(1)
    w(cya_off, r(cya_off) & ~(1 << 2))
    w(link_off, (r(link_off) & ~0xC0000) | (2 << 18))
    cya = r(cya_off)
    link = r(link_off)
    alive = 0 if r(0) == 0xFFFFFFFF else 1
    print((cya >> 2) & 1, (link >> 18) & 3, alive)
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
        if [[ "${cap_gen}" -lt 2 ]]; then
            log "${gpu}: Gen2 gate still closed (LnkCap=Gen${cap_gen})"
            log "${gpu}: the running driver lacks the Gen2 patch -- rebuild with install.sh and reboot"
            return 1
        fi
    fi

    # Order matters here and matches the working reference implementation
    # exactly: target speed on both ends first, a settle delay, *then* the BAR0
    # re-assert, *then* the retrain. Poking BAR0 before setting LnkCtl2 (tried
    # first) reached the gate-open state but the retrain still declined Gen2.
    setpci -s "${rp}"  "${LNKCTL2}=${GEN2}:0xf" 2>/dev/null || true
    setpci -s "${gpu}" "${LNKCTL2}=${GEN2}:0xf" 2>/dev/null || true
    sleep 0.2

    # Re-assert DIS_G2/MAX_RATE right before retraining -- post-boot RM/GSP init
    # has been observed to revert MAX_RATE (see header). If this write does not
    # stick, retraining is pointless, so bail before touching the root port.
    local poke_dis_g2="?" poke_max_rate="?" poke_alive="?"
    if state="$(poke_bar0_gate "${gpu}")" && [[ -n "${state}" ]]; then
        read -r poke_dis_g2 poke_max_rate poke_alive <<<"${state}"
    fi
    if [[ "${poke_alive}" != "1" || "${poke_dis_g2}" != "0" || "${poke_max_rate}" != "2" ]]; then
        log "${gpu}: gate re-assert failed (DIS_G2=${poke_dis_g2}, MAX_RATE=${poke_max_rate}, alive=${poke_alive}), skipping retrain"
        return 1
    fi

    setpci -s "${rp}" "${LNKCTL}=0x20:0x20" 2>/dev/null || true
    sleep 1.5

    after="$(poll_best_gen "${gpu}")"
    if [[ "${after}" -ge 2 ]]; then
        log "${gpu}: retrained Gen${before} -> Gen2 (root port ${rp})"
        return 0
    fi

    log "${gpu}: link declined Gen2 -- retrain completed, still Gen${after} (root port ${rp})"
    log "${gpu}: gate open (DIS_G2=${poke_dis_g2}, LnkCap=Gen${cap_gen}, MAX_RATE=${poke_max_rate}, OPT_GEN23=${opt_gen23})"
    return 1
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
