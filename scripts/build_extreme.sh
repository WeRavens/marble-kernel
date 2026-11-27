#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/Pzqqt/android_kernel_xiaomi_marble.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-bouquet_ci}"
TCP_CONG="${TCP_CONG:-bbr}"
LTO_MODE="${LTO_MODE:-thin}"
BUILD_KSU="${BUILD_KSU:-true}"
BUILD_SUSFS="${BUILD_SUSFS:-true}"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
WORK_DIR="${WORK_DIR:-$HOME/extreme_work}"
KERNEL_DIR="$WORK_DIR/kernel"
DIST_DIR="$HOME/dist"
TOOLCHAIN_ARCHIVE="$HOME/build_toolchain/llvm-23.1.6-x86_64.tar.xz"
BUILD_DATE="$(date -u +%Y%m%d-%H%M)"

mkdir -p "$WORK_DIR" "$DIST_DIR" "$ARTIFACTS_DIR" "$HOME/.local/bin" "$HOME/build_toolchain"
export PATH="$HOME/.local/bin:$PATH"

log() {
  echo "[MarbleExtreme] $*"
}

die() {
  echo "[MarbleExtreme][ERROR] $*" >&2
  exit 1
}

setup_tools() {
  if [[ ! -f "$TOOLCHAIN_ARCHIVE" ]]; then
    log "Downloading Slim LLVM 23.1.6..."
    curl -fL --retry 3 --retry-delay 5 \
      -o "$TOOLCHAIN_ARCHIVE" \
      "https://mirrors.edge.kernel.org/pub/tools/llvm/files/llvm-23.1.6-x86_64.tar.xz"
  else
    log "Reusing cached Slim LLVM 23.1.6 archive"
  fi

  if [[ ! -x "$HOME/build_toolchain/llvm-23.1.6-x86_64/bin/clang" ]]; then
    log "Extracting Slim LLVM 23.1.6..."
    tar -xJf "$TOOLCHAIN_ARCHIVE" -C "$HOME/build_toolchain"
  fi

  if [[ ! -x "$HOME/.local/bin/7za" ]]; then
    log "Installing 7za 26.06..."
    rm -rf /tmp/7z2606
    mkdir -p /tmp/7z2606
    curl -fL --retry 3 -o /tmp/7z2606/7z.tar.xz \
      "https://github.com/ip7z/7zip/releases/download/26.06/7z2606-linux-x64.tar.xz"
    tar -xJf /tmp/7z2606/7z.tar.xz -C /tmp/7z2606
    cp -f /tmp/7z2606/7zzs "$HOME/.local/bin/7za"
    chmod +x "$HOME/.local/bin/7za"
    rm -rf /tmp/7z2606
  fi

  if [[ ! -x "$HOME/.local/bin/hdiffz" || ! -x "$HOME/.local/bin/hpatchz" ]]; then
    log "Installing HDiffPatch v4.12.2..."
    rm -rf /tmp/hdiffpatch
    mkdir -p /tmp/hdiffpatch
    curl -fL --retry 3 -o /tmp/hdiffpatch/hdiff.zip \
      "https://github.com/sisong/HDiffPatch/releases/download/v4.12.2/hdiffpatch_v4.12.2_bin_linux64.zip"
    7za x -y /tmp/hdiffpatch/hdiff.zip -o/tmp/hdiffpatch >/dev/null
    cp -f /tmp/hdiffpatch/linux64/hdiffz "$HOME/.local/bin/hdiffz"
    cp -f /tmp/hdiffpatch/linux64/hpatchz "$HOME/.local/bin/hpatchz"
    chmod +x "$HOME/.local/bin/hdiffz" "$HOME/.local/bin/hpatchz"
    rm -rf /tmp/hdiffpatch
  fi
}

clone_kernel() {
  rm -rf "$KERNEL_DIR"
  log "Cloning $KERNEL_REPO (branch: $KERNEL_BRANCH)..."
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
  KERNEL_COMMIT="$(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD)"
  log "Kernel HEAD: $KERNEL_COMMIT"
}

apply_extreme_tuning() {
  local defcfg="$KERNEL_DIR/arch/arm64/configs/marble_defconfig"
  [[ -f "$defcfg" ]] || die "Missing $defcfg"

  log "Applying MarbleExtreme tuning to marble_defconfig (TCP=$TCP_CONG, LTO=$LTO_MODE)..."

  if [[ "$TCP_CONG" == "bbr" ]]; then
    sed -i '/^CONFIG_DEFAULT_WESTWOOD=/d; /^CONFIG_DEFAULT_TCP_CONG=/d; /^CONFIG_DEFAULT_BBR=/d; /^CONFIG_TCP_CONG_BBR=/d' "$defcfg"
    cat >> "$defcfg" <<'EOF'

# MarbleExtreme: TCP BBR default congestion control
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
EOF
  fi

  if [[ "$LTO_MODE" == "full" ]]; then
    sed -i '/^CONFIG_LTO_CLANG_THIN=/d; /^CONFIG_LTO_CLANG_FULL=/d' "$defcfg"
    cat >> "$defcfg" <<'EOF'

# MarbleExtreme: Full Clang LTO
CONFIG_LTO_CLANG_FULL=y
# CONFIG_LTO_CLANG_THIN is not set
EOF
  fi

  # Disable DWARF debug info to avoid runner OOM during LTO vmlinux link
  # (Image & stripped .ko modules are unaffected)
  sed -i '/^CONFIG_DEBUG_INFO=/d; /^CONFIG_DEBUG_INFO_DWARF4=/d; /^CONFIG_DEBUG_INFO_BTF=/d' "$defcfg"
  cat >> "$defcfg" <<'EOF'

# MarbleExtreme: Disable debug info to keep LTO link within runner RAM
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_INFO_DWARF4 is not set
# CONFIG_DEBUG_INFO_BTF is not set
EOF

  # Commit defconfig tweak locally so git status stays clean for build_bouquet.sh trap cleanup
  git -C "$KERNEL_DIR" config user.name "MarbleExtreme"
  git -C "$KERNEL_DIR" config user.email "marble@local"
  git -C "$KERNEL_DIR" add "$defcfg"
  git -C "$KERNEL_DIR" commit -m "MarbleExtreme: Apply TCP=${TCP_CONG} LTO=${LTO_MODE}" || true
}

build_all() {
  cd "$KERNEL_DIR"
  chmod +x ./build_bouquet.sh
  rm -rf "$DIST_DIR"/* "$HOME/Bouquet_marble_out"

  log "Step 1/3: Building full kernel Image + vendor_boot/vendor_dlkm modules + dtb/dtbo..."
  ./build_bouquet.sh
  cp -rf "$HOME/Bouquet_marble_out/"* "$DIST_DIR/"

  KSU_STATUS="skipped"
  SUSFS_STATUS="skipped"

  if [[ "$BUILD_KSU" == "true" ]]; then
    log "Step 2/3: Building Image_ksu (tiann/KernelSU)..."
    rm -rf "$HOME/KernelSU"
    git clone --depth=1 https://github.com/tiann/KernelSU.git "$HOME/KernelSU"
    ./build_bouquet.sh --noclean --ksu -- Image
    cp -f "$HOME/Bouquet_marble_out/"Image_ksu* "$DIST_DIR/"
    KSU_STATUS="included"
  fi

  if [[ "$BUILD_SUSFS" == "true" ]]; then
    log "Step 3/3: Building Image_susfs (KernelSU + SuSFS gki-android12-5.10)..."
    if [[ ! -d "$HOME/KernelSU" ]]; then
      git clone --depth=1 https://github.com/tiann/KernelSU.git "$HOME/KernelSU"
    fi
    rm -rf "$HOME/susfs4ksu"
    git clone --depth=1 --branch gki-android12-5.10 https://gitlab.com/simonpunk/susfs4ksu.git "$HOME/susfs4ksu"
    if ./build_bouquet.sh --susfs -- Image; then
      cp -f "$HOME/Bouquet_marble_out/"Image_susfs* "$DIST_DIR/"
      SUSFS_STATUS="included"
    else
      log "WARNING: Image_susfs failed (likely upstream 10_enable_susfs_for_ksu.patch drift); continuing with Image + Image_ksu"
      SUSFS_STATUS="failed-skipped"
    fi
  fi
}

package_ak3() {
  local ak3_dir="$HOME/AnyKernel3"
  rm -rf "$ak3_dir"
  log "Packaging full AnyKernel3 zip via Pzqqt/AnyKernel3 (Marble-Bouquet)..."
  git clone --depth=1 --branch Marble-Bouquet https://github.com/Pzqqt/AnyKernel3.git "$ak3_dir"
  cd "$ak3_dir"

  rm -f ./Image*
  cp -f "$DIST_DIR/devicetree/ukee.dtb" ./_dtb/dtb
  cp -f "$DIST_DIR/devicetree/dtbo.img" ./_dtb/dtbo.img
  cp -f "$DIST_DIR/alt_kernel_modules/"* ./_modules_hyperos/_alt/
  cp -f "$DIST_DIR/vendor_boot_modules/"* ./_modules_hyperos/_vendor_boot_modules/
  cp -f "$DIST_DIR/vendor_dlkm_modules/"* ./_modules_hyperos/_vendor_dlkm_modules/
  cp -f "$DIST_DIR/"Image* ./

  local tag_ver="extreme-${TCP_CONG}-${LTO_MODE}-${BUILD_DATE}-${KERNEL_COMMIT}"
  python3 ./make_package.py "$tag_ver"

  local built_zip
  built_zip="$(ls -1 "$ak3_dir"/Bouquet-Kernel-*.zip | head -n1 || true)"
  [[ -s "$built_zip" ]] || die "Package zip not found in $ak3_dir"

  local final_name="MarbleExtreme-5.10.275-${TCP_CONG}-${LTO_MODE}-${BUILD_DATE}.zip"
  cp -f "$built_zip" "$ARTIFACTS_DIR/$final_name"

  local sha256
  sha256="$(sha256sum "$ARTIFACTS_DIR/$final_name" | awk '{print $1}')"
  (
    cd "$ARTIFACTS_DIR"
    sha256sum "$final_name" > "${final_name}.sha256"
  )

  cat > "$ARTIFACTS_DIR/build-info.txt" <<EOF
ZIP_NAME="${final_name}"
SHA256="${sha256}"
KERNEL_REPO="${KERNEL_REPO}"
KERNEL_BRANCH="${KERNEL_BRANCH}"
KERNEL_COMMIT="${KERNEL_COMMIT}"
TCP_CONG="${TCP_CONG}"
LTO_MODE="${LTO_MODE}"
TOOLCHAIN="slim-llvm-23.1.6 (-O3 --lto-O3)"
KSU_STATUS="${KSU_STATUS}"
SUSFS_STATUS="${SUSFS_STATUS}"
EOF

  log "Created full-package artifact: $ARTIFACTS_DIR/$final_name"
  log "SHA256: $sha256"
}

main() {
  setup_tools
  clone_kernel
  apply_extreme_tuning
  build_all
  package_ak3
}

main "$@"
