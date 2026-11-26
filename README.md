# MarblePerf Kernel Builder (POCO F5 / `marble`)

Repository ini siap di-push ke GitHub untuk meng-compile **custom kernel performa tinggi + KernelSU-Next + SuSFS** secara otomatis menggunakan **GitHub Actions** (tanpa perlu setup Linux/WSL2 di PC).

---

## Target Perangkat & Kompatibilitas

- **Device:** Xiaomi POCO F5 / Redmi Note 12 Turbo (`marble` / `marblein`)
- **ROM Target:** Evolution X 12.2 (Android 17)
- **Base Kernel:** [`Evolution-X-Devices/kernel_xiaomi_sm8450`](https://github.com/Evolution-X-Devices/kernel_xiaomi_sm8450) branch **`cnb`** (Linux **`5.10.269-gki`**)
- **Root & Stealth (Opsional):**
  - [`pershoot/KernelSU-Next`](https://github.com/pershoot/KernelSU-Next) (`dev-susfs`)
  - [`simonpunk/susfs4ksu`](https://gitlab.com/simonpunk/susfs4ksu) (`gki-android12-5.10`)

> **Penting:** Branch `cnb` (`5.10.269`) dipilih khusus agar cocok 100% dengan kernel bawaan Evolution X 12.2 Android 17 (`5.10.269-gki`) beserta seluruh modul `.ko` di `vendor_boot` / `vendor_dlkm`. Jangan arahkan ke branch `cnb-6.6` kecuali ROM kamu memang sudah memakai kernel 6.6.

---

## Fitur Optimasi yang Disertakan

1. **Compiler & LTO:**
   - Pilihan **RvClang 20.1.1 (BOLT + PGO + Full LTO)** atau **ZyCromerZ Clang 16.0.6**
   - Dukungan **Full LTO** (performa maksimal) dan **Thin LTO** (build lebih cepat)
   - `CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y`
2. **Jaringan & Memori:**
   - **TCP BBR** sebagai congestion control default + **FQ / FQ-CoDel**
   - **ZRAM LZ4 / ZSTD** & `TMPFS_XATTR` / `TMPFS_POSIX_ACL`
3. **Efisiensi & Responsivitas:**
   - **Boeffla Wakelock Blocker** aktif
   - Mengurangi overhead debug (`DEBUG_INFO`, `SCHED_DEBUG`, `SLUB_DEBUG_ON` dimatikan tanpa merusak KMI/MODVERSIONS/CFI)
   - Patch performa *KMI-safe* pilihan dari `WildKernels/kernel_patches` (tanpa mengubah layout struct yang bisa memutus kompatibilitas modul)

---

## Cara Pakai di GitHub Actions

### 1. Push Repository ke GitHub
Buat repository baru di GitHub (public atau private), lalu jalankan di terminal folder ini:

```bash
git add .
git commit -m "Initial POCO F5 kernel builder"
git remote add origin https://github.com/<USERNAME_KAMU>/<NAMA_REPO>.git
git push -u origin main
```

### 2. Jalankan Build di GitHub Actions
1. Buka repository kamu di browser -> klik tab **Actions**.
2. Di sebelah kiri, pilih workflow **Build POCO F5 (marble) Kernel**.
3. Klik **Run workflow** dan pilih opsi sesuai kebutuhan:
   - `root_mode`: `ksun-susfs` *(rekomendasi)*, `ksun-only`, atau `none`
   - `lto_mode`: `full` *(performa maksimal)* atau `thin` *(lebih cepat selesai)*
   - `enable_perf_patches`: `true` *(centang)*
   - `toolchain`: `rvclang-20.1.1` *(rekomendasi)* atau `zyc-16.0.6`
   - `kernel_branch`: `cnb`
   - `create_release`: `true` jika ingin otomatis jadi GitHub Release, atau `false` untuk unduh dari Artifacts
4. Tunggu proses selesai (biasanya ~15–30 menit untuk Full LTO pada run pertama, dan lebih cepat pada run berikutnya karena `ccache`).
5. Setelah hijau, buka hasil run tersebut lalu unduh zip di bagian **Artifacts** (bernama `MarblePerf-EvoX17-5.10.269-...zip`).

---

## Panduan Flashing & Keamanan (Wajib Baca)

### 1. Backup `boot.img` Bawaan Terlebih Dahulu
Sebelum flash apa pun, **wajib backup `boot` slot aktif** (lewat TWRP/OrangeFox backup *Boot*, atau ekstrak `boot.img` dari ZIP ROM Evolution X 12.2 / `adb shell dd` jika sudah root).

### 2. Flash Kernel (AnyKernel3)
1. Reboot ke custom recovery (**OrangeFox** / **TWRP** yang sudah support Android 16/17).
2. Pilih file `.zip` hasil download dari GitHub Actions -> **Swipe to Flash** -> **Reboot System**.
   - Script `anykernel.sh` hanya mengganti kernel `Image` di partisi `boot` (GKI 2.0) tanpa mengubah ramdisk atau DTB bawaan ROM.

### 3. Setup Root (Jika Memilih `ksun-susfs`)
1. Install aplikasi **KernelSU-Next Manager** (APK resmi dari rilis [`pershoot/KernelSU-Next`](https://github.com/pershoot/KernelSU-Next/releases) atau `KernelSU-Next/KernelSU-Next`).
2. *(Opsional untuk SuSFS)* Install modul **susfs4ksu** dari [`simonpunk/susfs4ksu`](https://gitlab.com/simonpunk/susfs4ksu/-/tree/gki-android12-5.10) untuk mengatur spoof/hide lewat UI atau CLI `ksu_susfs`.

### 4. Cara Mengembalikan Jika Terjadi Bootloop
1. Tahan tombol **Power + Volume Down** untuk masuk **Fastboot**, atau **Power + Volume Up** untuk masuk **Recovery**.
2. Flash ulang `boot.img` bawaan ROM (`fastboot flash boot boot.img` atau restore backup *Boot* di Recovery), lalu reboot.
