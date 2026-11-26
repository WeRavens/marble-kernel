#!/usr/bin/env python3
"""Apply Linux 5.10 GKI compatibility fixes for SuSFS and clean builds."""

import argparse
import pathlib
import re
import sys

I_USER_NS_CALL = re.compile(r"i_uid_into_mnt\(i_user_ns\(([^()]*)\),")


def fix_susfs_idmap(kernel_dir: pathlib.Path) -> None:
    """Rewrite i_user_ns() calls in fs/susfs.c to &init_user_ns on pre-6.3 kernels."""
    susfs_c = kernel_dir / "fs" / "susfs.c"
    fs_h = kernel_dir / "include" / "linux" / "fs.h"
    if not susfs_c.is_file():
        print("[skip] fs/susfs.c not present")
        return

    if fs_h.is_file() and re.search(
        r"\bi_user_ns\s*\(", fs_h.read_text(encoding="utf-8", errors="ignore")
    ):
        print("[skip] include/linux/fs.h provides i_user_ns()")
        return

    src = susfs_c.read_text(encoding="utf-8")
    if "i_user_ns" not in src:
        print("[ok] fs/susfs.c has no i_user_ns references")
        return

    out, count = I_USER_NS_CALL.subn(r"i_uid_into_mnt(&init_user_ns,", src)
    if count == 0:
        raise RuntimeError("i_user_ns present in fs/susfs.c but expected call shape did not match")
    if "i_user_ns" in out:
        remaining = out.count("i_user_ns")
        raise RuntimeError(f"{remaining} i_user_ns reference(s) remain in fs/susfs.c after rewrite")

    susfs_c.write_text(out, encoding="utf-8")
    print(f"[fixed] rewrote {count} i_uid_into_mnt(i_user_ns(...)) call(s) to &init_user_ns")


def fix_susfs_unused_helpers(kernel_dir: pathlib.Path) -> None:
    """Mark SuSFS credential helpers __maybe_unused to avoid -Werror=unused-function."""
    susfs_c = kernel_dir / "fs" / "susfs.c"
    if not susfs_c.is_file():
        return

    src = susfs_c.read_text(encoding="utf-8")
    replacements = [
        (
            "static struct cred *susfs_switch_to_ksu_domain(void)",
            "static struct cred * __maybe_unused susfs_switch_to_ksu_domain(void)",
        ),
        (
            "static void susfs_restore_creds(struct cred *orig_cred)",
            "static void __maybe_unused susfs_restore_creds(struct cred *orig_cred)",
        ),
    ]

    changed = 0
    for old, new in replacements:
        if old in src and new not in src:
            src = src.replace(old, new)
            changed += 1

    if changed:
        susfs_c.write_text(src, encoding="utf-8")
        print(f"[fixed] added __maybe_unused to {changed} SuSFS helper(s)")
    else:
        print("[ok] SuSFS credential helpers already guarded or absent")


def remove_protected_exports(kernel_dir: pathlib.Path) -> None:
    """Remove abi_gki_protected_exports lists if present so vendor modules keep loading."""
    for rel in (
        "android/abi_gki_protected_exports_aarch64",
        "android/abi_gki_protected_exports_x86_64",
    ):
        target = kernel_dir / rel
        if target.exists():
            target.unlink()
            print(f"[fixed] removed {rel}")


def strip_dirty_localversion(kernel_dir: pathlib.Path) -> None:
    """Prevent scripts/setlocalversion from appending -dirty to uname -r."""
    setlocal = kernel_dir / "scripts" / "setlocalversion"
    if not setlocal.is_file():
        print("[skip] scripts/setlocalversion not present")
        return

    src = setlocal.read_text(encoding="utf-8")
    if "printf '%s' -dirty" in src:
        setlocal.write_text(src.replace("printf '%s' -dirty", "printf '%s' ''"), encoding="utf-8")
        print("[fixed] stripped -dirty suffix in scripts/setlocalversion")
    else:
        print("[ok] scripts/setlocalversion already clean")


def verify_reboot_hook(kernel_dir: pathlib.Path) -> None:
    """Log reboot.c hook status after SuSFS patching without altering upstream behavior."""
    reboot_c = kernel_dir / "kernel" / "reboot.c"
    if not reboot_c.is_file():
        return

    src = reboot_c.read_text(encoding="utf-8")
    if "ksu_handle_sys_reboot" in src:
        print("[info] kernel/reboot.c contains ksu_handle_sys_reboot (kept intact)")
    else:
        print("[info] kernel/reboot.c has no ksu_handle_sys_reboot reference")


def apply_fixes(kernel_dir: pathlib.Path) -> None:
    """Run all Linux 5.10 compatibility and cleanup steps on kernel_dir."""
    if not kernel_dir.is_dir():
        raise FileNotFoundError(f"Kernel directory not found: {kernel_dir}")

    fix_susfs_idmap(kernel_dir)
    fix_susfs_unused_helpers(kernel_dir)
    remove_protected_exports(kernel_dir)
    strip_dirty_localversion(kernel_dir)
    verify_reboot_hook(kernel_dir)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fix Linux 5.10 SuSFS compatibility and build hygiene.")
    parser.add_argument("--kernel-dir", required=True, type=pathlib.Path, help="Path to kernel source root")
    args = parser.parse_args()
    apply_fixes(args.kernel_dir.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
