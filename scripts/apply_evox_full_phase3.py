#!/usr/bin/env python3
"""
Phase 3 advanced feature port patcher for pure Evolution X sm8450 (5.10.269).
Stage 3.1: SSG (SamSung Generic) blk-mq I/O scheduler + cgroup support.
"""

import argparse
import shutil
import subprocess
from pathlib import Path

SSG_KCONFIG = """
config MQ_IOSCHED_SSG
\ttristate "SamSung Generic I/O scheduler"
\tdefault y
\thelp
\t  SamSung Generic IO scheduler optimized for mobile UFS storage.

config MQ_IOSCHED_SSG_CGROUP
\ttristate "Control Group for SamSung Generic I/O scheduler"
\tdefault y
\tdepends on BLK_CGROUP
\tdepends on MQ_IOSCHED_SSG
\thelp
\t  Control Group for SamSung Generic I/O scheduler.
"""

SSG_MAKEFILE = """ssg-$(CONFIG_MQ_IOSCHED_SSG)\t:= ssg-iosched.o
ssg-$(CONFIG_MQ_IOSCHED_SSG_CGROUP)\t+= ssg-cgroup.o
obj-$(CONFIG_MQ_IOSCHED_SSG)\t+= ssg.o
"""


def apply_ssg(repo_root: Path, kernel_dir: Path) -> None:
    src_dir = repo_root / "patches" / "evox-full" / "ssg"
    blk_dir = kernel_dir / "block"
    for fname in ("ssg-iosched.c", "ssg-cgroup.c", "ssg-cgroup.h"):
        src = src_dir / fname
        assert src.is_file(), f"Missing SSG source file: {src}"
        shutil.copy2(src, blk_dir / fname)

    kconfig = blk_dir / "Kconfig.iosched"
    ktext = kconfig.read_text(encoding="utf-8")
    if "config MQ_IOSCHED_SSG" not in ktext:
        assert "\nendmenu\n" in ktext, "Anchor endmenu not found in block/Kconfig.iosched"
        ktext = ktext.replace("\nendmenu\n", f"\n{SSG_KCONFIG}\nendmenu\n", 1)
        kconfig.write_text(ktext, encoding="utf-8", newline="\n")

    makefile = blk_dir / "Makefile"
    mtext = makefile.read_text(encoding="utf-8")
    if "CONFIG_MQ_IOSCHED_SSG" not in mtext:
        anchor = "obj-$(CONFIG_IOSCHED_BFQ)\t+= bfq.o\n"
        assert anchor in mtext, "Anchor obj-$(CONFIG_IOSCHED_BFQ) not found in block/Makefile"
        mtext = mtext.replace(anchor, anchor + SSG_MAKEFILE, 1)
        makefile.write_text(mtext, encoding="utf-8", newline="\n")

    elevator = blk_dir / "elevator.c"
    etext = elevator.read_text(encoding="utf-8")
    if "CONFIG_MQ_IOSCHED_SSG" not in etext:
        old_ret = '\treturn elevator_get(q, "mq-deadline", false);\n'
        new_ret = (
            "#if IS_ENABLED(CONFIG_MQ_IOSCHED_SSG)\n"
            '\treturn elevator_get(q, "ssg", false);\n'
            "#else\n"
            '\treturn elevator_get(q, "mq-deadline", false);\n'
            "#endif\n"
        )
        assert old_ret in etext, "Anchor elevator_get(mq-deadline) not found in block/elevator.c"
        etext = etext.replace(old_ret, new_ret, 1)
        elevator.write_text(etext, encoding="utf-8", newline="\n")

    print("[phase3] Applied SSG I/O scheduler (ssg-iosched + ssg-cgroup + default elevator).")


def apply_patch_series(repo_root: Path, kernel_dir: Path, subdir: str, label: str) -> None:
    patch_dir = repo_root / "patches" / "evox-full" / subdir
    patches = sorted(patch_dir.glob("*.patch"))
    assert patches, f"No {label} patches found in {patch_dir}"
    for p in patches:
        print(f"[phase3] Applying {label} patch: {p.name}")
        res = subprocess.run(
            ["patch", "-p1", "--forward", "--batch", "--fuzz=3", "-i", str(p)],
            cwd=str(kernel_dir),
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            print(res.stdout)
            print(res.stderr)
            raise SystemExit(f"[phase3][ERROR] Failed applying {p.name}")
    print(f"[phase3] Applied all {len(patches)} {label} patches cleanly.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--kernel-dir", required=True, type=Path)
    parser.add_argument("--enable-ssg", action="store_true")
    parser.add_argument("--enable-rcu-lazy", action="store_true")
    parser.add_argument("--enable-mglru", action="store_true")
    args = parser.parse_args()

    if args.enable_ssg:
        apply_ssg(args.repo_root, args.kernel_dir)
    if args.enable_rcu_lazy:
        apply_patch_series(args.repo_root, args.kernel_dir, "rcu_lazy", "RCU Lazy")
    if args.enable_mglru:
        apply_patch_series(args.repo_root, args.kernel_dir, "mglru", "MGLRU")


if __name__ == "__main__":
    main()
