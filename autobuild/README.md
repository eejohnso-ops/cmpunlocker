# autobuild: rebuild the GPU unlocks on kernel upgrades

This is local to z8g4 and not part of upstream cmpunlocker. Both unlocks
are per-kernel modules:

- cmpunlocker's patched NVIDIA modules (CMP 170HX)
- `gpu_unlock` (RTX 3090 tensor speed selectors)

A new kernel from unattended-upgrades would otherwise boot without them,
and nothing would report it.

## What it does

| Piece | Installed as | Job |
|---|---|---|
| `kernel-hook` | `/etc/kernel/{postinst.d,header_postinst.d,postrm.d}/cmp-unlocks` | Runs the rebuild when a kernel or its headers install, and cleans up on removal. It never fails apt. |
| `cmp-unlocks-rebuild` | `/usr/local/sbin` | Builds `gpu_unlock` and the patched NVIDIA modules for one kernel, then checks what `modprobe` will load and what's in the initramfs. It writes `/var/lib/cmp-unlocks/built/<kver>` on success. |
| `cmp-unlocks-select-kernel` | `/usr/local/sbin` | Sets GRUB to boot the newest kernel that has a build. If the newest kernel has none, it pins the last good one and writes `/etc/motd.d/90-cmp-unlocks-build`. |
| `cmp-unlocks-verify` + `.service` | `/usr/local/sbin`, systemd | Runs at every boot and checks three things: the patched `nvidia.ko` is loaded, the CMP reports its unlocked memory size, and `gpu_unlock: unlocked` was logged for each target. On failure it logs to the journal, writes a login warning, and leaves the unit failed. |

Builds use **pinned snapshots** in `/usr/local/src/{cmpunlocker,gpu-unlock}`,
made with `git archive` at install time. Branch switches or pulls in the
working checkouts don't change what an unattended upgrade builds.

## Use

    sudo autobuild/setup.sh install      # snapshot HEAD of this repo + ~/Projects/gpu-unlock HEAD
    autobuild/setup.sh status
    sudo cmp-unlocks-rebuild <kver>      # manual retry for a non-running kernel
    sudo autobuild/setup.sh uninstall

Re-run `install` after moving either checkout to a commit you have
verified. It needs `driver/build.sh` with `CMPUNLOCKER_KVER` support.
That is a permanent local patch, commit "build.sh: allow building for a
kernel other than the running one", carried on this branch. To take
upstream updates, rebase this branch onto `origin/master`.

Logs go to `/var/log/cmp-unlocks.log` and `journalctl -u cmp-unlocks-verify -b`.
