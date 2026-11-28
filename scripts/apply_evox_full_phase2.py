#!/usr/bin/env python3
"""
Phase 2 KMI-free performance patches for pure Evolution X sm8450 (5.10.269).
Currently supports:
  - PELT half-life tuning (32ms stock, 12ms balanced-fast, 8ms aggressive)
"""

import argparse
from pathlib import Path

PELT12_BLOCK = """
static const u32 pelt12_runnable_avg_yN_inv[] __maybe_unused = {
\t0xffffffff, 0xf1a1bf37, 0xe411f039, 0xd744fcc9, 0xcb2ff529, 0xbfc886ba,
\t0xb504f333, 0xaadc0846, 0xa14517cb, 0x9837f050, 0x8facd61d, 0x879c7c96,
};

#define PELT12_LOAD_AVG_PERIOD 12
#define PELT12_LOAD_AVG_MAX 18227
"""

PELT12_CASE = """\tcase PELT12_LOAD_AVG_PERIOD:
\t\tpelt_load_avg_period = PELT12_LOAD_AVG_PERIOD;
\t\tpelt_load_avg_max = PELT12_LOAD_AVG_MAX;
\t\tpelt_runnable_avg_yN_inv = pelt12_runnable_avg_yN_inv;
\t\tpr_info("PELT half life is set to %dms\\n", num);
\t\tbreak;
"""


def patch_pelt(kernel_dir: Path, halflife: int) -> None:
    if halflife == 32:
        print("[phase2] PELT half-life = 32ms (stock), no PELT patch needed.")
        return
    if halflife not in (8, 12):
        raise SystemExit(f"[phase2][ERROR] Unsupported PELT half-life: {halflife} (expected 32, 12, or 8)")

    sched_pelt_h = kernel_dir / "kernel" / "sched" / "sched-pelt.h"
    pelt_c = kernel_dir / "kernel" / "sched" / "pelt.c"
    assert sched_pelt_h.is_file(), f"Missing {sched_pelt_h}"
    assert pelt_c.is_file(), f"Missing {pelt_c}"

    if halflife == 12:
        h_text = sched_pelt_h.read_text(encoding="utf-8")
        if "PELT12_LOAD_AVG_PERIOD" not in h_text:
            anchor = "#define PELT8_LOAD_AVG_MAX 12336\n"
            assert anchor in h_text, "Anchor PELT8_LOAD_AVG_MAX not found in sched-pelt.h"
            h_text = h_text.replace(anchor, anchor + PELT12_BLOCK, 1)
            sched_pelt_h.write_text(h_text, encoding="utf-8", newline="\n")
            print("[phase2] Added PELT12 constants to kernel/sched/sched-pelt.h")

    c_text = pelt_c.read_text(encoding="utf-8")
    if halflife == 12 and "case PELT12_LOAD_AVG_PERIOD:" not in c_text:
        case_anchor = "\tcase PELT32_LOAD_AVG_PERIOD:\n"
        assert case_anchor in c_text, "Anchor case PELT32_LOAD_AVG_PERIOD not found in pelt.c"
        c_text = c_text.replace(case_anchor, PELT12_CASE + case_anchor, 1)

    old_defaults = (
        "int pelt_load_avg_period = PELT32_LOAD_AVG_PERIOD;\n"
        "int pelt_load_avg_max = PELT32_LOAD_AVG_MAX;\n"
        "const u32 *pelt_runnable_avg_yN_inv = pelt32_runnable_avg_yN_inv;\n"
    )
    new_defaults = (
        f"int pelt_load_avg_period = PELT{halflife}_LOAD_AVG_PERIOD;\n"
        f"int pelt_load_avg_max = PELT{halflife}_LOAD_AVG_MAX;\n"
        f"const u32 *pelt_runnable_avg_yN_inv = pelt{halflife}_runnable_avg_yN_inv;\n"
    )
    assert old_defaults in c_text, "Default PELT32 initializer block not found in pelt.c"
    c_text = c_text.replace(old_defaults, new_defaults, 1)
    pelt_c.write_text(c_text, encoding="utf-8", newline="\n")
    print(f"[phase2] Set boot default PELT half-life to {halflife}ms in kernel/sched/pelt.c")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel-dir", required=True, type=Path)
    parser.add_argument("--pelt-halflife", type=int, default=32)
    args = parser.parse_args()
    patch_pelt(args.kernel_dir, args.pelt_halflife)


if __name__ == "__main__":
    main()
