#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/Evolution-X-Devices/kernel_xiaomi_sm8450.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-cnb}"
ROOT_MODE="${ROOT_MODE:-ksun-susfs}"
LTO_MODE="${LTO_MODE:-full}"
ENABLE_PERF_PATCHES="${ENABLE_PERF_PATCHES:-true}"
TOOLCHAIN="${TOOLCHAIN:-rvclang-20.1.1}"
LOCALVERSION_SUFFIX="${LOCALVERSION_SUFFIX:-}"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
KERNEL_DIR="${KERNEL_DIR:-$WORK_DIR/kernel}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$REPO_ROOT/toolchains/$TOOLCHAIN}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
BUILD_DATE="$(date -u +%Y%m%d-%H%M)"

mkdir -p "$WORK_DIR" "$TOOLCHAIN_DIR" "$ARTIFACTS_DIR"

log() {
  echo "[MarblePerf] $*"
}

die() {
  echo "[MarblePerf][ERROR] $*" >&2
  exit 1
}

download_toolchain() {
  local tc_url=""
  case "$TOOLCHAIN" in
    rvclang-20.1.1)
      tc_url="https://github.com/Rv-Project/RvClang/releases/download/20.1.1/RvClang-20.1.1-bolt-pgo-full_lto.tar.gz"
      ;;
    zyc-16.0.6)
      tc_url="https://github.com/ZyCromerZ/Clang/releases/download/16.0.6-20260807-release/Clang-16.0.6-20260807.tar.gz"
      ;;
    *)
      die "Unsupported TOOLCHAIN='$TOOLCHAIN' (expected rvclang-20.1.1 or zyc-16.0.6)"
      ;;
  esac

  local existing_clang=""
  existing_clang="$(find "$TOOLCHAIN_DIR" -maxdepth 3 -type f -name clang 2>/dev/null | head -n1 || true)"
  if [[ -z "$existing_clang" ]]; then
    log "Downloading toolchain $TOOLCHAIN..."
    local archive="$WORK_DIR/toolchain.tar.gz"
    curl -fL --retry 3 --retry-delay 5 -o "$archive" "$tc_url"
    tar -xf "$archive" -C "$TOOLCHAIN_DIR"
    rm -f "$archive"
    existing_clang="$(find "$TOOLCHAIN_DIR" -maxdepth 3 -type f -name clang | head -n1 || true)"
  else
    log "Reusing cached toolchain at $TOOLCHAIN_DIR"
  fi

  [[ -n "$existing_clang" ]] || die "Could not locate clang binary in $TOOLCHAIN_DIR"
  CLANG_BIN_DIR="$(dirname "$existing_clang")"
  export PATH="$CLANG_BIN_DIR:$PATH"
  log "Using compiler: $(clang --version | head -n1)"
}

clone_kernel() {
  rm -rf "$KERNEL_DIR"
  log "Cloning $KERNEL_REPO (branch: $KERNEL_BRANCH)..."
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
  KERNEL_COMMIT="$(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD)"
  log "Kernel HEAD: $KERNEL_COMMIT"
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
      [[ -f "$susfs_patch" ]] || die "Missing SuSFS patch: $susfs_patch"

      if ! patch -p1 --forward --batch --fuzz=3 < "$susfs_patch"; then
        log "SuSFS patch had rejects:"
        find "$KERNEL_DIR" -name '*.rej' -print -exec head -n 40 {} + || true
        die "Failed to apply SuSFS patch cleanly"
      fi

      local rej_files
      rej_files="$(find "$KERNEL_DIR" -name '*.rej' -print -quit || true)"
      if [[ -n "$rej_files" ]]; then
        find "$KERNEL_DIR" -name '*.rej' -print -exec head -n 40 {} + || true
        die "SuSFS patch left .rej files"
      fi

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
      die "Unsupported ROOT_MODE='$ROOT_MODE' (expected ksun-susfs, ksun-only, or none)"
      ;;
  esac
}

APPLIED_PATCHES=()
SKIPPED_PATCHES=()

apply_perf_patches() {
  if [[ "$ENABLE_PERF_PATCHES" != "true" ]]; then
    log "Performance patches disabled (ENABLE_PERF_PATCHES=$ENABLE_PERF_PATCHES)"
    return
  fi

  cd "$KERNEL_DIR"
  rm -rf "$WORK_DIR/kernel_patches"
  log "Fetching WildKernels/kernel_patches..."
  git clone --depth=1 https://github.com/WildKernels/kernel_patches.git "$WORK_DIR/kernel_patches"

  # Strictly KMI-safe patches only (excludes struct-layout-altering patches like file_struct_8bytes_align.patch)
  local patches=(
    "reduce_cache_pressure.patch"
    "minimise_wakeup_time.patch"
    "int_sqrt.patch"
    "f2fs_reduce_congestion.patch"
    "reduce_freeze_timeout.patch"
    "increase_sk_mem_packets.patch"
    "silence_irq_cpu_logspam.patch"
    "silence_system_logspam.patch"
    "avoid_extra_s2idle_wake_attempts.patch"
  )

  for p in "${patches[@]}"; do
    local patch_path="$WORK_DIR/kernel_patches/common/$p"
    if [[ ! -f "$patch_path" ]]; then
      log "[SKIPPED] $p (not found in upstream repo)"
      SKIPPED_PATCHES+=("$p (missing)")
      continue
    fi

    if patch -p1 --dry-run --forward -F3 -s --batch < "$patch_path" >/dev/null 2>&1; then
      patch -p1 --forward -F3 --batch < "$patch_path"
      log "[APPLIED] $p"
      APPLIED_PATCHES+=("$p")
    else
      log "[SKIPPED] $p (already upstream or context drift)"
      SKIPPED_PATCHES+=("$p")
    fi
  done
}

configure_kernel() {
  cd "$KERNEL_DIR"
  cp -f "$REPO_ROOT/configs/marble_perf.config" "$KERNEL_DIR/arch/arm64/configs/vendor/marble_perf.config"

  local defconfigs=(
    "gki_defconfig"
    "vendor/waipio_GKI.config"
    "vendor/xiaomi_GKI.config"
    "vendor/marble_GKI.config"
    "vendor/marble_perf.config"
  )

  if [[ "$ROOT_MODE" == "ksun-susfs" ]]; then
    cp -f "$REPO_ROOT/configs/ksu_susfs.config" "$KERNEL_DIR/arch/arm64/configs/vendor/ksu_susfs.config"
    defconfigs+=("vendor/ksu_susfs.config")
  elif [[ "$ROOT_MODE" == "ksun-only" ]]; then
    cp -f "$REPO_ROOT/configs/ksu_only.config" "$KERNEL_DIR/arch/arm64/configs/vendor/ksu_only.config"
    defconfigs+=("vendor/ksu_only.config")
  fi

  log "Generating defconfig: ${defconfigs[*]}"
  make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 TARGET_PRODUCT=marble "${defconfigs[@]}"

  case "$LTO_MODE" in
    full)
      "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
        --enable LTO_CLANG \
        --enable LTO_CLANG_FULL \
        --disable LTO_CLANG_THIN
      ;;
    thin)
      "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
        --enable LTO_CLANG \
        --disable LTO_CLANG_FULL \
        --enable LTO_CLANG_THIN
      ;;
    *)
      die "Unsupported LTO_MODE='$LTO_MODE' (expected full or thin)"
      ;;
  esac

  if [[ -n "$LOCALVERSION_SUFFIX" ]]; then
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
      --set-str LOCALVERSION "-gki${LOCALVERSION_SUFFIX}"
  else
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
      --set-str LOCALVERSION "-gki"
  fi

  make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 TARGET_PRODUCT=marble olddefconfig

  # Verify critical configs survived olddefconfig
  grep -q '^CONFIG_MODVERSIONS=y$' "$OUT_DIR/.config" || die "CONFIG_MODVERSIONS=y missing after olddefconfig!"
  grep -q '^CONFIG_DEFAULT_BBR=y$' "$OUT_DIR/.config" || die "CONFIG_DEFAULT_BBR=y missing after olddefconfig!"
  if [[ "$ROOT_MODE" == "ksun-susfs" ]]; then
    grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config" || die "CONFIG_KSU=y missing after olddefconfig!"
    grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config" || die "CONFIG_KSU_SUSFS=y missing after olddefconfig!"
  elif [[ "$ROOT_MODE" == "ksun-only" ]]; then
    grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config" || die "CONFIG_KSU=y missing after olddefconfig!"
  fi
}

build_kernel() {
  cd "$KERNEL_DIR"
  log "Starting kernel Image build (LTO=$LTO_MODE, jobs=$(nproc))..."
  export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-MarblePerf}"
  export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-GitHubActions}"

  make -j"$(nproc)" \
    O="$OUT_DIR" \
    ARCH=arm64 \
    LLVM=1 \
    LLVM_IAS=1 \
    CC="ccache clang" \
    TARGET_PRODUCT=marble \
    KCFLAGS="-Wno-error" \
    Image

  IMAGE_PATH="$OUT_DIR/arch/arm64/boot/Image"
  [[ -s "$IMAGE_PATH" ]] || die "Build failed: $IMAGE_PATH not found or empty"
  log "Kernel Image built successfully: $(du -h "$IMAGE_PATH" | awk '{print $1}')"
}

package_anykernel() {
  local ak3_dir="$WORK_DIR/AnyKernel3"
  rm -rf "$ak3_dir"
  log "Packaging AnyKernel3 flashable zip..."
  git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$ak3_dir"
  rm -rf "$ak3_dir/.git" "$ak3_dir/modules" "$ak3_dir/patch" "$ak3_dir/ramdisk" \
         "$ak3_dir/README.md" "$ak3_dir/LICENSE"

  cp -f "$REPO_ROOT/anykernel/anykernel.sh" "$ak3_dir/anykernel.sh"
  cp -f "$OUT_DIR/arch/arm64/boot/Image" "$ak3_dir/Image"

  local kver="5.10.269"
  if [[ -f "$OUT_DIR/include/config/kernel.release" ]]; then
    KERNEL_RELEASE="$(cat "$OUT_DIR/include/config/kernel.release")"
    kver="$(echo "$KERNEL_RELEASE" | cut -d'-' -f1)"
  else
    KERNEL_RELEASE="${kver}-gki"
  fi

  sed -i "s|^kernel.string=.*|kernel.string=MarblePerf Kernel (${KERNEL_RELEASE} / ${ROOT_MODE} / ${LTO_MODE}-lto)|" "$ak3_dir/anykernel.sh"

  local zip_name="MarblePerf-EvoX17-${kver}-${ROOT_MODE}-${LTO_MODE}-${BUILD_DATE}.zip"
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
ROOT_MODE="${ROOT_MODE}"
LTO_MODE="${LTO_MODE}"
TOOLCHAIN="${TOOLCHAIN}"
ENABLE_PERF_PATCHES="${ENABLE_PERF_PATCHES}"
APPLIED_PATCHES="${APPLIED_PATCHES[*]:-none}"
SKIPPED_PATCHES="${SKIPPED_PATCHES[*]:-none}"
EOF

  log "Created artifact: $zip_path"
  log "SHA256: $sha256"
}

main() {
  download_toolchain
  clone_kernel
  integrate_root
  apply_perf_patches
  configure_kernel
  build_kernel
  package_anykernel
}

main "$@"
