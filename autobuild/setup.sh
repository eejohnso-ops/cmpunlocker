#!/bin/bash
# Install, remove, or inspect the automatic rebuild of the GPU unlocks
# (cmpunlocker patched NVIDIA modules + gpu_unlock) on kernel upgrades.
#
#   sudo autobuild/setup.sh install [--cmp-ref REF] [--gpu-unlock-repo DIR] [--gpu-unlock-ref REF]
#   sudo autobuild/setup.sh uninstall
#   autobuild/setup.sh status
#
# install snapshots both sources at the given commits into /usr/local/src, so
# later branch switches or pulls in the working checkouts never change what an
# unattended kernel upgrade builds. Re-run install to move to newer commits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF=/etc/cmp-unlocks.conf
CONF_DIR=/etc/cmp-unlocks
STATE=/var/lib/cmp-unlocks
CMP_SRC=/usr/local/src/cmpunlocker
GPU_UNLOCK_SRC=/usr/local/src/gpu-unlock
HOOK_DIRS=(/etc/kernel/postinst.d /etc/kernel/header_postinst.d /etc/kernel/postrm.d)
SBIN=(cmp-unlocks-rebuild cmp-unlocks-select-kernel cmp-unlocks-verify)
UNIT=cmp-unlocks-verify.service

info() { echo "[INFO]  $*"; }
ok()   { echo "[ OK ]  $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[FAIL]  $*" >&2; exit 1; }

git_in() { git -c safe.directory="$1" -C "$1" "${@:2}"; }

set_grub_default() {
    local value="$1"
    if grep -q "^GRUB_DEFAULT=${value}\$" /etc/default/grub; then
        ok "GRUB_DEFAULT already ${value}"
        return
    fi
    cp -a /etc/default/grub /etc/default/grub.cmp-unlocks.bak
    sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=${value}/" /etc/default/grub
    update-grub
    ok "Set GRUB_DEFAULT=${value} (backup: /etc/default/grub.cmp-unlocks.bak)"
}

do_install() {
    local cmp_ref=HEAD gu_repo="${HOME}/Projects/gpu-unlock" gu_ref=HEAD
    [[ -n "${SUDO_USER:-}" ]] && gu_repo="$(getent passwd "${SUDO_USER}" | cut -d: -f6)/Projects/gpu-unlock"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cmp-ref) cmp_ref="$2"; shift 2 ;;
            --gpu-unlock-repo) gu_repo="$2"; shift 2 ;;
            --gpu-unlock-ref) gu_ref="$2"; shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    local kver ref_dir targets cmp_commit gu_commit
    kver="$(uname -r)"
    ref_dir="/lib/modules/${kver}/updates/cmpunlocker"
    [[ -f "${ref_dir}/driver_version" && -f "${ref_dir}/gpu_inventory" ]] \
        || die "No cmpunlocker install found for running kernel ${kver} (${ref_dir}); run install.sh first"
    targets="$(grep -oE 'gpu_unlock\.targets=[^ ]+' /proc/cmdline | cut -d= -f2 || true)"
    [[ -n "${targets}" ]] || die "gpu_unlock.targets= is not on the running kernel command line"
    [[ "${targets}" != all ]] || die "gpu_unlock.targets=all is not supported here; name the PCI address(es)"

    info "Snapshotting cmpunlocker ${cmp_ref} from ${REPO}"
    cmp_commit="$(git_in "${REPO}" rev-parse --verify "${cmp_ref}^{commit}")"
    git_in "${REPO}" show "${cmp_commit}:driver/build.sh" | grep -q CMPUNLOCKER_KVER \
        || die "cmpunlocker ${cmp_commit} lacks CMPUNLOCKER_KVER support in driver/build.sh"
    rm -rf "${CMP_SRC}"
    mkdir -p "${CMP_SRC}"
    git_in "${REPO}" archive "${cmp_commit}" | tar -x -C "${CMP_SRC}"
    ok "cmpunlocker ${cmp_commit:0:12} -> ${CMP_SRC}"

    info "Snapshotting gpu-unlock ${gu_ref} from ${gu_repo}"
    gu_commit="$(git_in "${gu_repo}" rev-parse --verify "${gu_ref}^{commit}")"
    rm -rf "${GPU_UNLOCK_SRC}"
    mkdir -p "${GPU_UNLOCK_SRC}"
    git_in "${gu_repo}" archive "${gu_commit}" kernel/gpu_unlock | tar -x --strip-components=2 -C "${GPU_UNLOCK_SRC}"
    ok "gpu-unlock ${gu_commit:0:12} -> ${GPU_UNLOCK_SRC}"
    ls /usr/lib/firmware/gpu-unlock/*/v67-*.bin >/dev/null 2>&1 \
        || warn "gpu-unlock firmware not found under /usr/lib/firmware/gpu-unlock; the unlock cannot run"

    mkdir -p "${CONF_DIR}" "${STATE}/built" "${STATE}/build"
    install -m644 "${ref_dir}/gpu_inventory" "${CONF_DIR}/gpu_inventory"
    local tarball
    tarball="open-gpu-kernel-modules-$(cat "${ref_dir}/driver_version").tar.gz"
    if [[ -f "${REPO}/driver/.build/${tarball}" && ! -f "${STATE}/build/${tarball}" ]]; then
        cp "${REPO}/driver/.build/${tarball}" "${STATE}/build/"
        ok "Seeded build cache with ${tarball} (no download needed during upgrades)"
    fi
    cat > "${CONF}" <<EOF
# Written by cmpunlocker autobuild/setup.sh on $(date -Is). Re-run setup.sh install to change.
CMP_SRC=${CMP_SRC}
CMP_COMMIT=${cmp_commit}
GPU_UNLOCK_SRC=${GPU_UNLOCK_SRC}
GPU_UNLOCK_COMMIT=${gu_commit}
GPU_UNLOCK_TARGETS=${targets}
DRIVER_VERSION=$(cat "${ref_dir}/driver_version")
CARD_PROFILE=$(cat "${ref_dir}/card_profile")
GPU_INVENTORY_FILE=${CONF_DIR}/gpu_inventory
EOF
    ok "Wrote ${CONF}"

    for s in "${SBIN[@]}"; do install -m755 "${SCRIPT_DIR}/${s}" "/usr/local/sbin/${s}"; done
    for d in "${HOOK_DIRS[@]}"; do install -Dm755 "${SCRIPT_DIR}/kernel-hook" "${d}/cmp-unlocks"; done
    install -m644 "${SCRIPT_DIR}/${UNIT}" "/etc/systemd/system/${UNIT}"
    systemctl daemon-reload
    systemctl enable "${UNIT}"
    ok "Installed scripts, kernel hooks, and ${UNIT}"

    set_grub_default saved

    # The running kernel counts as built only if its unlocks verify right now.
    if /usr/local/sbin/cmp-unlocks-verify; then
        printf 'built=%s\ncmpunlocker=%s\ngpu_unlock=%s\nnote=verified live at setup\n' \
            "$(date -Is)" "${cmp_commit}" "${gu_commit}" > "${STATE}/built/${kver}"
        ok "Running kernel ${kver} verified and marked as built"
    else
        warn "Running kernel ${kver} failed verification; it is not marked as built"
    fi
    /usr/local/sbin/cmp-unlocks-select-kernel
    systemctl restart "${UNIT}" || true
    echo
    ok "Done. Test without touching the live driver:  sudo cmp-unlocks-rebuild <another installed kernel>"
}

do_uninstall() {
    systemctl disable --now "${UNIT}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${UNIT}"
    systemctl daemon-reload
    for d in "${HOOK_DIRS[@]}"; do rm -f "${d}/cmp-unlocks"; done
    for s in "${SBIN[@]}"; do rm -f "/usr/local/sbin/${s}"; done
    rm -f /etc/motd.d/90-cmp-unlocks-build /run/motd.d/90-cmp-unlocks-verify
    grub-editenv - unset saved_entry
    set_grub_default 0
    rm -rf "${CONF}" "${CONF_DIR}" "${STATE}" "${CMP_SRC}" "${GPU_UNLOCK_SRC}"
    ok "Removed. Installed modules under /lib/modules/*/updates are left in place."
}

do_status() {
    [[ -f "${CONF}" ]] || { echo "Not installed."; return; }
    cat "${CONF}"
    echo
    echo "Kernels (built = unlocks built for it):"
    local k
    for k in $(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V); do
        printf '  %-28s %s%s\n' "${k}" "$([[ -f "${STATE}/built/${k}" ]] && echo built || echo NOT-BUILT)" \
            "$([[ "${k}" == "$(uname -r)" ]] && echo '  (running)')"
    done
    echo
    echo "GRUB: $(grep '^GRUB_DEFAULT=' /etc/default/grub); $(grub-editenv list 2>/dev/null | grep saved_entry || echo 'saved_entry unset (boots newest)')"
    echo "Boot check: $(systemctl is-active "${UNIT}" 2>/dev/null || true)"
}

case "${1:-}" in
    install) [[ "${EUID}" -eq 0 ]] || die "Run as root"; shift; do_install "$@" ;;
    uninstall) [[ "${EUID}" -eq 0 ]] || die "Run as root"; do_uninstall ;;
    status) do_status ;;
    *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
