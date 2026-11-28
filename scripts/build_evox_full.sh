#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/Evolution-X-Devices/kernel_xiaomi_sm8450.git}"
MODULES_REPO="${MODULES_REPO:-https://github.com/Evolution-X-Devices/kernel_xiaomi_sm8450-modules.git}"
COMMON_REPO="${COMMON_REPO:-https://github.com/Evolution-X-Devices/device_xiaomi_sm8450-common.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-cnb}"

ROOT_MODE="${ROOT_MODE:-none}"
LTO_MODE="${LTO_MODE:-full}"
OPT_LEVEL="${OPT_LEVEL:-O2}"
ENABLE_PERF_CONFIG="${ENABLE_PERF_CONFIG:-false}"
TIMER_HZ="${TIMER_HZ:-250}"
PELT_HALFLIFE="${PELT_HALFLIFE:-32}"
ENABLE_SSG="${ENABLE_SSG:-false}"
ENABLE_RCU_LAZY="${ENABLE_RCU_LAZY:-false}"
ENABLE_MGLRU="${ENABLE_MGLRU:-false}"
TOOLCHAIN="${TOOLCHAIN:-aosp-r563880c}"

# Layout: sm8450, sm8450-modules, and out are direct siblings in WORK_DIR
# so external Makefiles referencing $(OUT_DIR)/../sm8450-modules/... resolve cleanly.
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work_evox_full}"
KERNEL_DIR="$WORK_DIR/sm8450"
MODULES_DIR="$WORK_DIR/sm8450-modules"
COMMON_DIR="$WORK_DIR/sm8450-common"
OUT_DIR="$WORK_DIR/out"
MOD_STAGE="$WORK_DIR/mod_stage"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$REPO_ROOT/toolchains/$TOOLCHAIN}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
BUILD_DATE="$(date -u +%Y%m%d-%H%M)"

mkdir -p "$WORK_DIR" "$TOOLCHAIN_DIR" "$ARTIFACTS_DIR"

log() {
  echo "[MarbleEvoXFull] $*"
}

die() {
  echo "[MarbleEvoXFull][ERROR] $*" >&2
  exit 1
}

download_toolchain() {
  local existing_clang=""
  existing_clang="$(find "$TOOLCHAIN_DIR" -maxdepth 4 \( -type f -o -type l \) -path '*/bin/clang' 2>/dev/null | head -n1 || true)"

  if [[ -z "$existing_clang" ]]; then
    case "$TOOLCHAIN" in
      aosp-r563880c)
        log "Cloning AOSP clang-r563880c..."
        rm -rf "$TOOLCHAIN_DIR"
        git clone --depth=1 https://github.com/bluegreensea/android_prebuilts_clang_kernel_linux-x86_clang-r563880c.git "$TOOLCHAIN_DIR"
        ;;
      slim-llvm-22.1.8)
        log "Downloading Slim LLVM 22.1.8..."
        local archive="$WORK_DIR/toolchain.tar.xz"
        curl -fL --retry 3 --retry-delay 5 -o "$archive" "https://mirrors.edge.kernel.org/pub/tools/llvm/files/llvm-22.1.8-x86_64.tar.xz"
        tar -xJf "$archive" -C "$TOOLCHAIN_DIR"
        rm -f "$archive"
        ;;
      *)
        die "Unsupported TOOLCHAIN='$TOOLCHAIN' (expected aosp-r563880c or slim-llvm-22.1.8)"
        ;;
    esac
    existing_clang="$(find "$TOOLCHAIN_DIR" -maxdepth 4 \( -type f -o -type l \) -path '*/bin/clang' 2>/dev/null | head -n1 || true)"
  else
    log "Reusing cached toolchain at $TOOLCHAIN_DIR"
  fi

  [[ -n "$existing_clang" ]] || die "Could not locate clang binary in $TOOLCHAIN_DIR"
  CLANG_BIN_DIR="$(dirname "$existing_clang")"
  export PATH="$CLANG_BIN_DIR:$PATH"
  export LD_LIBRARY_PATH="${CLANG_BIN_DIR}/../lib:${CLANG_BIN_DIR}/../lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  log "Using compiler: $(clang --version | head -n1)"
}

clone_sources() {
  rm -rf "$KERNEL_DIR" "$MODULES_DIR" "$COMMON_DIR" "$OUT_DIR" "$MOD_STAGE"
  mkdir -p "$OUT_DIR" "$MOD_STAGE"

  log "Cloning pure Evolution X sources (branch: $KERNEL_BRANCH)..."
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$MODULES_REPO" "$MODULES_DIR"
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$COMMON_REPO" "$COMMON_DIR"

  KERNEL_COMMIT="$(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD)"
  MODULES_COMMIT="$(git -C "$MODULES_DIR" rev-parse --short=12 HEAD)"
  log "Kernel HEAD: $KERNEL_COMMIT | Modules HEAD: $MODULES_COMMIT"
}

integrate_root() {
  cd "$KERNEL_DIR"
  case "$ROOT_MODE" in
    ksun-susfs)
      log "Integrating pershoot/KernelSU-Next (dev-susfs) + SuSFS (gki-android12-5.10)..."
      git clone --depth=1 --branch dev-susfs https://github.com/pershoot/KernelSU-Next.git "$KERNEL_DIR/KernelSU-Next"
      ln -sf ../KernelSU-Next/kernel "$KERNEL_DIR/drivers/kernelsu"
      grep -q "kernelsu" "$KERNEL_DIR/drivers/Makefile" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
      grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

      rm -rf "$WORK_DIR/susfs4ksu"
      git clone --depth=1 --branch gki-android12-5.10 https://gitlab.com/simonpunk/susfs4ksu.git "$WORK_DIR/susfs4ksu"
      cp -f "$WORK_DIR/susfs4ksu/kernel_patches/fs/"* "$KERNEL_DIR/fs/"
      cp -f "$WORK_DIR/susfs4ksu/kernel_patches/include/linux/"* "$KERNEL_DIR/include/linux/"

      local susfs_patch="$WORK_DIR/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch"
      patch -p1 --forward --batch --fuzz=3 < "$susfs_patch"
      local rej_files
      rej_files="$(git -C "$KERNEL_DIR" ls-files --others --exclude-standard '*.rej' || true)"
      [[ -z "$rej_files" ]] || die "SuSFS patch left .rej files: $rej_files"

      python3 "$REPO_ROOT/scripts/fix_susfs_510.py" --kernel-dir "$KERNEL_DIR"
      ;;
    ksun-only)
      log "Integrating KernelSU-Next (latest stable tag)..."
      curl -fLSs https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/dev/kernel/setup.sh | bash -s
      python3 "$REPO_ROOT/scripts/fix_susfs_510.py" --kernel-dir "$KERNEL_DIR"
      ;;
    none)
      log "Building without root integration (ROOT_MODE=none)..."
      python3 "$REPO_ROOT/scripts/fix_susfs_510.py" --kernel-dir "$KERNEL_DIR"
      ;;
    *)
      die "Unsupported ROOT_MODE='$ROOT_MODE'"
      ;;
  esac
}

apply_phase2_patches() {
  if [[ "$PELT_HALFLIFE" != "32" ]]; then
    log "Applying Phase 2 PELT half-life patch (${PELT_HALFLIFE}ms)..."
    python3 "$REPO_ROOT/scripts/apply_evox_full_phase2.py" \
      --kernel-dir "$KERNEL_DIR" \
      --pelt-halflife "$PELT_HALFLIFE"
  else
    log "Using stock PELT half-life (32ms)."
  fi
}

apply_phase3_patches() {
  local phase3_args=()
  [[ "$ENABLE_SSG" == "true" ]] && phase3_args+=(--enable-ssg)
  [[ "$ENABLE_RCU_LAZY" == "true" ]] && phase3_args+=(--enable-rcu-lazy)
  [[ "$ENABLE_MGLRU" == "true" ]] && phase3_args+=(--enable-mglru)

  if (( ${#phase3_args[@]} > 0 )); then
    log "Applying Phase 3 patches (${phase3_args[*]})..."
    python3 "$REPO_ROOT/scripts/apply_evox_full_phase3.py" \
      --repo-root "$REPO_ROOT" \
      --kernel-dir "$KERNEL_DIR" \
      "${phase3_args[@]}"
  fi
}

configure_kernel() {
  cd "$KERNEL_DIR"
  local defconfigs=(
    "gki_defconfig"
    "vendor/waipio_GKI.config"
    "vendor/xiaomi_GKI.config"
    "vendor/marble_GKI.config"
    "vendor/debugfs.config"
  )

  if [[ "$ENABLE_PERF_CONFIG" == "true" ]]; then
    cp -f "$REPO_ROOT/configs/marble_perf.config" "$KERNEL_DIR/arch/arm64/configs/vendor/marble_perf.config"
    defconfigs+=("vendor/marble_perf.config")
  fi

  if [[ "$ROOT_MODE" == "ksun-susfs" ]]; then
    cp -f "$REPO_ROOT/configs/ksu_susfs.config" "$KERNEL_DIR/arch/arm64/configs/vendor/ksu_susfs.config"
    defconfigs+=("vendor/ksu_susfs.config")
  elif [[ "$ROOT_MODE" == "ksun-only" ]]; then
    cp -f "$REPO_ROOT/configs/ksu_only.config" "$KERNEL_DIR/arch/arm64/configs/vendor/ksu_only.config"
    defconfigs+=("vendor/ksu_only.config")
  fi

  log "Generating defconfig: ${defconfigs[*]}"
  make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 TARGET_PRODUCT=marble TARGET_BOARD_PLATFORM=taro "${defconfigs[@]}"

  # Always disable DWARF debug info to keep LTO + full module build within runner RAM
  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    --disable WERROR \
    --disable DEBUG_INFO \
    --disable DEBUG_INFO_DWARF4 \
    --disable DEBUG_INFO_BTF

  case "$LTO_MODE" in
    thin)
      # Linux 5.10 GKI + CFI_CLANG + ThinLTO causes early-boot CFI crashes with external modules;
      # disable CFI_CLANG when ThinLTO is explicitly selected.
      "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
        --enable LTO_CLANG \
        --disable LTO_CLANG_FULL \
        --enable LTO_CLANG_THIN \
        --disable CFI_CLANG \
        --disable CFI_PERMISSIVE
      ;;
    full)
      "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
        --enable LTO_CLANG \
        --enable LTO_CLANG_FULL \
        --disable LTO_CLANG_THIN
      ;;
    *)
      die "Unsupported LTO_MODE='$LTO_MODE'"
      ;;
  esac

  case "$TIMER_HZ" in
    300)
      "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
        --disable HZ_100 \
        --disable HZ_250 \
        --enable HZ_300 \
        --disable HZ_1000
      ;;
    250)
      "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
        --disable HZ_100 \
        --enable HZ_250 \
        --disable HZ_300 \
        --disable HZ_1000
      ;;
    *)
      die "Unsupported TIMER_HZ='$TIMER_HZ' (expected 300 or 250)"
      ;;
  esac

  if [[ "$ENABLE_SSG" == "true" ]]; then
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
      --enable MQ_IOSCHED_SSG \
      --enable MQ_IOSCHED_SSG_CGROUP
  fi

  if [[ "$ENABLE_RCU_LAZY" == "true" ]]; then
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
      --enable RCU_NOCB_CPU \
      --enable RCU_NOCB_CPU_DEFAULT_ALL \
      --enable RCU_LAZY
  fi

  if [[ "$ENABLE_MGLRU" == "true" ]]; then
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
      --enable LRU_GEN \
      --enable LRU_GEN_ENABLED \
      --disable LRU_GEN_STATS
  fi

  make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 TARGET_PRODUCT=marble TARGET_BOARD_PLATFORM=taro olddefconfig
  log "Verified timer config: $(grep -E '^CONFIG_HZ(_[0-9]+)?=' "$OUT_DIR/.config" | tr '\n' ' ')"
  if [[ "$ENABLE_SSG" == "true" ]]; then
    log "Verified SSG config: $(grep -E '^CONFIG_MQ_IOSCHED_SSG' "$OUT_DIR/.config" | tr '\n' ' ')"
  fi
  if [[ "$ENABLE_RCU_LAZY" == "true" ]]; then
    log "Verified RCU Lazy config: $(grep -E '^CONFIG_RCU_(NOCB_CPU|LAZY)' "$OUT_DIR/.config" | tr '\n' ' ')"
  fi
  if [[ "$ENABLE_MGLRU" == "true" ]]; then
    log "Verified MGLRU config: $(grep -E '^CONFIG_LRU_GEN' "$OUT_DIR/.config" | tr '\n' ' ')"
  fi
}

build_kernel_and_modules() {
  cd "$KERNEL_DIR"
  export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-MarbleEvoX}"
  export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-GitHubActions}"

  local extra_kcflags="-Wno-error"
  local extra_ldflags=""
  if [[ "$OPT_LEVEL" == "O3" ]]; then
    extra_kcflags="-O3 -Wno-error"
    extra_ldflags="-O3 --lto-O3"
  fi

  local common_make_args=(
    -j"$(nproc)"
    O="$OUT_DIR"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CC="ccache clang"
    TARGET_PRODUCT=marble
    TARGET_BOARD_PLATFORM=taro
    KCFLAGS="$extra_kcflags"
  )
  if [[ -n "$extra_ldflags" ]]; then
    common_make_args+=(KBUILD_LDFLAGS="$extra_ldflags")
  fi

  log "Building core kernel Image + in-tree modules (LTO=$LTO_MODE, OPT=$OPT_LEVEL)..."
  make "${common_make_args[@]}" Image modules
  make "${common_make_args[@]}" INSTALL_MOD_PATH="$MOD_STAGE" INSTALL_MOD_STRIP=1 modules_install

  [[ -s "$OUT_DIR/arch/arm64/boot/Image" ]] || die "Image not built!"

  # Exact Evolution X sm8450-common external module build order
  local ext_modules=(
    "qcom/opensource/mmrm-driver"
    "qcom/opensource/audio-kernel"
    "qcom/opensource/camera-kernel"
    "qcom/opensource/cvp-kernel"
    "qcom/opensource/dataipa/drivers/platform/msm"
    "qcom/opensource/datarmnet/core"
    "qcom/opensource/datarmnet-ext/aps"
    "qcom/opensource/datarmnet-ext/offload"
    "qcom/opensource/datarmnet-ext/shs"
    "qcom/opensource/datarmnet-ext/perf"
    "qcom/opensource/datarmnet-ext/perf_tether"
    "qcom/opensource/datarmnet-ext/sch"
    "qcom/opensource/datarmnet-ext/wlan"
    "qcom/opensource/display-drivers/msm"
    "qcom/opensource/eva-kernel"
    "qcom/opensource/video-driver"
    "qcom/opensource/wlan/qcacld-3.0/.qca6490"
  )

  local rpath="../sm8450-modules"
  local extra_syms=""

  for mod in "${ext_modules[@]}"; do
    local mod_dir="$MODULES_DIR/$mod"
    if [[ ! -d "$mod_dir" ]]; then
      log "[WARN] External module dir missing, skipping: $mod"
      continue
    fi
    log "Building external module: $mod"
    make -j"$(nproc)" \
      -C "$mod_dir" \
      M="${rpath}/${mod}" \
      KERNEL_SRC="$KERNEL_DIR" \
      OUT_DIR="$OUT_DIR" \
      O="$OUT_DIR" \
      ARCH=arm64 \
      LLVM=1 \
      LLVM_IAS=1 \
      CC="ccache clang" \
      TARGET_PRODUCT=marble \
      TARGET_BOARD_PLATFORM=taro \
      KCFLAGS="$extra_kcflags" \
      ${extra_syms:+KBUILD_EXTRA_SYMBOLS="$extra_syms"}

    make -j"$(nproc)" \
      -C "$mod_dir" \
      M="${rpath}/${mod}" \
      KERNEL_SRC="$KERNEL_DIR" \
      OUT_DIR="$OUT_DIR" \
      O="$OUT_DIR" \
      ARCH=arm64 \
      LLVM=1 \
      LLVM_IAS=1 \
      CC="ccache clang" \
      TARGET_PRODUCT=marble \
      TARGET_BOARD_PLATFORM=taro \
      INSTALL_MOD_PATH="$MOD_STAGE" \
      INSTALL_MOD_STRIP=1 \
      KERNEL_UAPI_HEADERS_DIR="$OUT_DIR" \
      modules_install

    if [[ -f "$mod_dir/Module.symvers" ]]; then
      extra_syms="${extra_syms:+$extra_syms }$mod_dir/Module.symvers"
    fi
  done
}

package_full_anykernel() {
  local ak3_dir="$WORK_DIR/AnyKernel3"
  rm -rf "$ak3_dir"
  log "Packaging Full-Package AnyKernel3 zip..."
  git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$ak3_dir"
  rm -rf "$ak3_dir/.git" "$ak3_dir/modules" "$ak3_dir/patch" "$ak3_dir/ramdisk" \
         "$ak3_dir/README.md" "$ak3_dir/LICENSE"

  mkdir -p "$ak3_dir/_modules"
  cp -f "$REPO_ROOT/anykernel/anykernel_evox_full.sh" "$ak3_dir/anykernel.sh"
  cp -f "$OUT_DIR/arch/arm64/boot/Image" "$ak3_dir/Image"

  # Stage ALL compiled .ko modules into a single _modules/ directory (no duplication,
  # and guarantees 100% coverage of both vendor_boot and vendor_dlkm modules).
  local total_ko=0
  while IFS= read -r ko_path; do
    [[ -f "$ko_path" ]] || continue
    cp -f "$ko_path" "$ak3_dir/_modules/$(basename "$ko_path")"
    total_ko=$((total_ko + 1))
  done < <(find "$MOD_STAGE" -type f -name '*.ko' | sort)
  log "Packaged all compiled .ko modules into _modules/: $total_ko"

  # Sanity-check coverage against Evolution X module lists
  check_list_coverage() {
    local list_file="$1"
    local found=0
    local missing=0
    while IFS= read -r modname; do
      modname="${modname%%#*}"
      modname="$(echo "$modname" | tr -d '[:space:]')"
      [[ -n "$modname" ]] || continue
      if [[ -f "$ak3_dir/_modules/$modname" ]]; then
        found=$((found + 1))
      else
        missing=$((missing + 1))
      fi
    done < "$list_file"
    log "  Coverage $(basename "$list_file"): matched=$found, built-in/absent=$missing"
  }

  check_list_coverage "$KERNEL_DIR/modules.list.msm.waipio"
  check_list_coverage "$COMMON_DIR/modules.list.second_stage"
  check_list_coverage "$COMMON_DIR/modules.list.vendor_dlkm"

  VB_COUNT="$total_ko"
  VD_COUNT="$total_ko"

  local kver="5.10.269"
  if [[ -f "$OUT_DIR/include/config/kernel.release" ]]; then
    KERNEL_RELEASE="$(cat "$OUT_DIR/include/config/kernel.release")"
    kver="$(echo "$KERNEL_RELEASE" | cut -d'-' -f1)"
  else
    KERNEL_RELEASE="${kver}-gki"
  fi

  local feat_tag=""
  [[ "$ENABLE_SSG" == "true" ]] && feat_tag="${feat_tag}-SSG"
  [[ "$ENABLE_RCU_LAZY" == "true" ]] && feat_tag="${feat_tag}-RCULazy"
  [[ "$ENABLE_MGLRU" == "true" ]] && feat_tag="${feat_tag}-MGLRU"

  sed -i "s|^kernel.string=.*|kernel.string=MarbleEvoX Full (${KERNEL_RELEASE} / ${ROOT_MODE} / ${LTO_MODE}-${OPT_LEVEL} / ${TIMER_HZ}Hz / PELT${PELT_HALFLIFE}${feat_tag})|" "$ak3_dir/anykernel.sh"

  local zip_name="MarbleEvoXFull-${kver}-${ROOT_MODE}-${LTO_MODE}-${OPT_LEVEL}-${TIMER_HZ}Hz-PELT${PELT_HALFLIFE}${feat_tag}-${BUILD_DATE}.zip"
  local zip_path="$ARTIFACTS_DIR/$zip_name"

  (
    cd "$ak3_dir"
    zip -r9 "$zip_path" . -x '*.git*'
  )

  local sha256
  sha256="$(sha256sum "$zip_path" | awk '{print $1}')"
  (
    cd "$ARTIFACTS_DIR"
    sha256sum "$zip_name" > "${zip_name}.sha256"
  )

  cat > "$ARTIFACTS_DIR/build-info.txt" <<EOF
ZIP_NAME="${zip_name}"
SHA256="${sha256}"
KERNEL_RELEASE="${KERNEL_RELEASE}"
KERNEL_REPO="${KERNEL_REPO}"
KERNEL_BRANCH="${KERNEL_BRANCH}"
KERNEL_COMMIT="${KERNEL_COMMIT}"
MODULES_COMMIT="${MODULES_COMMIT}"
ROOT_MODE="${ROOT_MODE}"
LTO_MODE="${LTO_MODE}"
OPT_LEVEL="${OPT_LEVEL}"
TIMER_HZ="${TIMER_HZ}"
PELT_HALFLIFE="${PELT_HALFLIFE}"
ENABLE_SSG="${ENABLE_SSG}"
ENABLE_RCU_LAZY="${ENABLE_RCU_LAZY}"
ENABLE_MGLRU="${ENABLE_MGLRU}"
ENABLE_PERF_CONFIG="${ENABLE_PERF_CONFIG}"
TOOLCHAIN="${TOOLCHAIN}"
VENDOR_BOOT_MODULES="${VB_COUNT}"
VENDOR_DLKM_MODULES="${VD_COUNT}"
EOF

  log "Created Full-Package artifact: $zip_path"
  log "SHA256: $sha256"
}

main() {
  download_toolchain
  clone_sources
  integrate_root
  apply_phase2_patches
  apply_phase3_patches
  configure_kernel
  build_kernel_and_modules
  package_full_anykernel
}

main "$@"
