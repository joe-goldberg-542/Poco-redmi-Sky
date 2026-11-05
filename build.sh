#!/usr/bin/env bash
set -eo pipefail

WORKDIR="$(pwd)"
RELEASE_DIR="$WORKDIR/artifacts"

KERNEL_NAME="sky"
TIMEZONE="Asia/Damascus"
ANYKERNEL_REPO="https://github.com/ahmed-alnassif/AK3-GKID"

KERNEL_DEFCONFIG="gki_defconfig"
KERNEL_VERSION="6.6"
ANDROID_RELEASE="15"

sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

RELEASE="$(date +v%y.%m.%d)${RUN_NUM}"

mkdir -p "$RELEASE_DIR"

GKI_RELEASES_REPO="https://github.com/${GITHUB_REPOSITORY:-joe-goldberg-542/Gki-6-6}"
AK3_ZIP_NAME="$KERNEL_NAME-VARIANT-REL-KVER.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"

source "$WORKDIR/functions.sh"

IFS='|' read -r KERNEL_REPO KERNEL_BRANCH KERNEL_KMI <<< "$(resolve_kernel_source)"

echo "KERNEL_VERSION=$KERNEL_VERSION" >> "$GITHUB_ENV"
echo "ANDROID_RELEASE=$ANDROID_RELEASE" >> "$GITHUB_ENV"
echo "KERNEL_SOURCE_REPO=$(simplify_gh_url "$KERNEL_REPO")" >> "$GITHUB_ENV"
echo "KERNEL_SOURCE_BRANCH=$KERNEL_BRANCH" >> "$GITHUB_ENV"

echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")" >> "$GITHUB_ENV"
echo "KERNEL_NAME=${KERNEL_NAME}${RUN_NUM}" >> "$GITHUB_ENV"
echo "RELEASE_NAME=$KERNEL_NAME $RELEASE" >> "$GITHUB_ENV"
echo "RELEASE=$RELEASE" >> "$GITHUB_ENV"

BUILD_LOGS="$RELEASE_DIR/build.log"
exec > >(tee -a "$BUILD_LOGS") 2>&1

trap 'echo "SCRIPT EXIT at $(date)" >> "$BUILD_LOGS"' EXIT
trap 'echo "[-] ERROR at line $LINENO: [[$BASH_COMMAND]]" >> "$BUILD_LOGS"' ERR
trap 'echo "[-] Received SIGTERM at $(date) - possible GitHub kill" >> "$BUILD_LOGS"' TERM
trap 'echo "[-] Received SIGINT at $(date)" >> "$BUILD_LOGS"' INT

log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC"

cd "$KSRC"
LINUX_VERSION=$(make kernelversion)
LINUX_VERSION_CODE=${LINUX_VERSION//./}
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
echo "LINUX_VERSION=$LINUX_VERSION" >> "$GITHUB_ENV"
cd "$WORKDIR"

log "Setting Kernel variant"
case "$KSU" in
  "KSU") VARIANT="KernelSU" ;;
  "no") VARIANT="Vanilla" ;;
  "vnlto") VARIANT="Vanilla+NoLTO" ;;
  *) VARIANT="Vanilla" ;;
esac

susfs_included && VARIANT+="+SuSFS"
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_DIR="$WORKDIR/susfs"
SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"

SUSFS_BRANCH="$(resolve_susfs_branch)"
SUSFS_PATCH="$SUSFS_BRANCH"

log "Changelog of repos"
clone_susfs 5
cd "$SUSFS_DIR"
git log --pretty=format:"- [%h](https://${SUSFS_URL#https://}/commit/%H) %s" -5 "$SUSFS_BRANCH" \
  > "$RELEASE_DIR/susfs_changelog-${KERNEL_VERSION}.txt"
cd "$WORKDIR"

generate_gh_changelog "xiaomi-ravelin/android_kernel_xiaomi_sm4450" "$KERNEL_BRANCH" 10 "$RELEASE_DIR/android_kernel-6.6_changelog.txt"
generate_gh_changelog "maxsteeel/nomount" "dev" 5 "$RELEASE_DIR/nomount_changelog.txt"
generate_gh_changelog "tiann/KernelSU" "main" 5 "$RELEASE_DIR/ksu_changelog.txt"

echo "::group::[*] Downloading Clang"
CLANG_BIN="$WORKDIR/neutron-clang/bin"
mkdir -p "$WORKDIR/neutron-clang"
cd "$WORKDIR/neutron-clang"
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") --patch=glibc
cd "$WORKDIR"
if [ ! -d "$CLANG_BIN" ]; then
  error "Clang not found in ${CLANG_BIN}."
  exit 1
fi

export PATH="${CLANG_BIN}:$PATH"
echo "::endgroup::"

export CC="clang"
export CXX="clang++"

COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')
echo "COMPILER_STRING=$COMPILER_STRING" >> "$GITHUB_ENV"

cd "$KSRC"

echo "::group::[+] pahole installation"
build_and_install_pahole
echo "::endgroup::"

echo "::group::[+] Applied patches"

export DROIDSPACES="false"
export NH="false"

if [ "$KSU" = "KSU" ]; then
  log "Official KernelSU Integration..."

  rm -rf KernelSU drivers/kernelsu
  sed -i '/kernelsu/d' drivers/Makefile 2>/dev/null || true
  sed -i '/kernelsu/d' drivers/Kconfig 2>/dev/null || true

  # susfsREADME.md Prerequisite #1: clone Official KernelSU without tag (main)
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main

  if susfs_included; then
    clone_susfs
    apply_susfs_patches
  fi
fi

if [ "$NM" = "true" ]; then
  integrate_nomount_manual
  VARIANT+="+NoMount"
fi

echo "VARIANT=$VARIANT" >> "$GITHUB_ENV"
echo "::endgroup::"
set +eo pipefail

AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

log "Applying inline defconfigs..."

cat << 'EOF' >> arch/arm64/configs/gki_defconfig
CONFIG_RCU_TRACE=n
EOF

if [ "$KSU" != "no" ] && [ "$KSU" != "vnlto" ]; then
  cat << 'EOF' >> arch/arm64/configs/gki_defconfig
CONFIG_KSU=y
CONFIG_HEADERS_INSTALL=y
CONFIG_EXT4_FS=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_OVERLAY_FS=y
EOF
fi

if [ "$NM" = "true" ]; then
  echo "CONFIG_NOMOUNT=y" >> arch/arm64/configs/gki_defconfig
fi

if susfs_included; then
  cat << 'EOF' >> arch/arm64/configs/gki_defconfig
CONFIG_KSU_SUSFS=y
CONFIG_THREAD_INFO_IN_TASK=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MEMFD=y
CONFIG_KSU_SUSFS_SUS_PROC_FD_LINK=y
EOF
fi

export KCFLAGS="-w"
export HOSTCFLAGS="-Wno-error -Wno-incompatible-pointer-types-discards-qualifiers"

# If KSU variant is explicitly Vanilla+NoLTO, force LTO=none
if [ "$KSU" = "vnlto" ]; then
  LTO="none"
fi

LINKER_SHIM="$WORKDIR/clang-lto-linker"
MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  HOSTCFLAGS="-Wno-error -Wno-incompatible-pointer-types-discards-qualifiers"
  EXTRA_CFLAGS="-Wno-error -Wno-incompatible-pointer-types-discards-qualifiers"
  -j"$(nproc --all)"
  O="$OUTDIR"
)

if [ "${LTO:-full}" = "thin" ]; then
  log "ThinLTO enabled (Cache removed)"
  cat > "$LINKER_SHIM" << SHIM
#!/usr/bin/env bash
JOBCOUNT=\$(( \$(nproc --all) / 2 ))
exec ld.lld "\$@" --thinlto-jobs=\$JOBCOUNT
SHIM
  chmod +x "$LINKER_SHIM"
  MAKE_ARGS+=(LD="$LINKER_SHIM" HOSTLD="$LINKER_SHIM")
fi

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"

echo "::group::[*] Generating config"
if [ -f "arch/arm64/configs/vendor/parrot_perf.config" ]; then
  log "Cleaning Suvkernel name from vendor/parrot_perf.config"
  sed -i '/CONFIG_LOCALVERSION/d' arch/arm64/configs/vendor/parrot_perf.config

  log "Merging gki_defconfig + vendor/parrot_perf.config for POCO M6 Pro 5G (Sky)"
  make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG" vendor/parrot_perf.config
else
  make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"
fi

log "Setting schedutil (Default), WALT Kept Alive, None IO, Lz4 zRAM & Stock GKI Localversion"
LATEST_COMMIT_HASH=$(git rev-parse --short=12 HEAD)
./scripts/config --file "$OUTDIR/.config" \
  -e CPU_FREQ_GOV_SCHEDUTIL \
  -e CPU_FREQ_DEFAULT_GOV_SCHEDUTIL \
  -d CPU_FREQ_DEFAULT_GOV_PERFORMANCE \
  -d CPU_FREQ_DEFAULT_GOV_POWERSAVE \
  -d CPU_FREQ_DEFAULT_GOV_WALT \
  -e CRYPTO_LZ4 \
  --set-str ZRAM_DEF_COMP "lz4" \
  --set-str CONFIG_LOCALVERSION "-android15-11-g${LATEST_COMMIT_HASH}" \
  -d CONFIG_LOCALVERSION_AUTO

case "${LTO:-full}" in
  "full")
    log "Enabling Full Clang LTO..."
    ./scripts/config --file "$OUTDIR/.config" \
      -d LTO_NONE \
      -d LTO_CLANG_THIN \
      -e LTO_CLANG \
      -e LTO_CLANG_FULL
    ;;
  "thin")
    log "Enabling Thin Clang LTO..."
    ./scripts/config --file "$OUTDIR/.config" \
      -d LTO_NONE \
      -d LTO_CLANG_FULL \
      -e LTO_CLANG \
      -e LTO_CLANG_THIN
    ;;
  "none")
    log "Disabling LTO..."
    ./scripts/config --file "$OUTDIR/.config" \
      -e LTO_NONE \
      -d LTO_CLANG \
      -d LTO_CLANG_FULL \
      -d LTO_CLANG_THIN
    ;;
esac

sed -i 's/CONFIG_CMDLINE="/CONFIG_CMDLINE="elevator=none /' "$OUTDIR/.config"

make "${MAKE_ARGS[@]}" olddefconfig > /dev/null

log "DEBUG: Checking .config for LTO"
grep "CONFIG_LTO" "$OUTDIR/.config" || true
echo "::endgroup::"

if susfs_included; then
  log "DEBUG: Checking defconfig for SUSFS"
  grep -i susfs ./arch/arm64/configs/gki_defconfig || error "SUSFS NOT FOUND in defconfig!"
  echo ""

  log "DEBUG: Checking .config for SUSFS"
  grep CONFIG_KSU_SUSFS "$OUTDIR/.config" || error "SUSFS NOT ENABLED in .config!"
  grep CONFIG_KSU_SUSFS_SUS_MAP "$OUTDIR/.config" || error "SUSFS_SUS_MAP not enabled!"
  echo ""

  if grep -q "CONFIG_KSU_SUSFS" ./arch/arm64/configs/gki_defconfig && ! grep -q "CONFIG_KSU_SUSFS=y" "$OUTDIR/.config"; then
    warning "SUSFS in defconfig but not in .config - checking dependencies..."
    grep "depends on" $(find . -name "Kconfig" -exec grep -l "KSU_SUSFS" {} \;) 2>/dev/null || error "No dependency info found"
  fi
fi

if [ "$TEST" = "yes" ]; then
  success "Pipeline test done"
  mkdir -p "$RELEASE_DIR"
  echo "test-${VARIANT}" > "$RELEASE_DIR/test-${VARIANT}.zip"
  exit 0
fi

if [[ $TODO == "defconfig" ]]; then
  log "Copying defconfig"
  mkdir -p "$RELEASE_DIR"
  cp "$OUTDIR/.config" "$RELEASE_DIR/config-${VARIANT}.txt"
  exit 0
fi

echo "::group::[*] Swap & Memory Optimization for LTO"

info "Initial storage: $(df -h / | awk 'NR==2 {print $4}') available"
info "Initial memory:  $(free -h | awk '/^Mem:/ {print $7}') available"

if [ -f /swapfile ]; then
  sudo swapoff /swapfile 2>/dev/null || true
  sudo rm -f /swapfile
fi
if [ -f /mnt/swapfile ]; then
  sudo swapoff /mnt/swapfile 2>/dev/null || true
  sudo rm -f /mnt/swapfile
fi

warning "Creating 15GB swap for Heavy Link-Time Optimization (Full LTO)"
sudo fallocate -l 15G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=15360 status=none
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
success "15GB swap created and activated"

sudo sysctl -w vm.swappiness=90
sudo sysctl -w vm.vfs_cache_pressure=200
sudo sysctl -w vm.dirty_ratio=5
sudo sysctl -w vm.dirty_background_ratio=2
sudo sysctl -w vm.drop_caches=3
sudo sysctl -w vm.overcommit_memory=1

success "Final storage: $(df -h / | awk 'NR==2 {print $4}') available"
success "Final memory:  $(free -h | awk '/^Mem:/ {print $7}') available | Swap: $(free -h | awk '/^Swap:/ {print $2}')"
echo "::endgroup::"

set -eo pipefail
echo "::group::[*] Building kernel"
make "${MAKE_ARGS[@]}" CC="clang" CXX="clang++"
echo "::endgroup::"

cd "$WORKDIR"

log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 "$ANYKERNEL_REPO" anykernel

AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
sed -i \
  -e "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT} by Ahmed Al-Nassif (ahmed-alnassif)/g" \
  -e "s/supported_kernel=\".*\"/supported_kernel=\"${KERNEL_VERSION}\"/g" \
  "$WORKDIR/anykernel/anykernel.sh"

cd anykernel
log "Zipping anykernel and creating Enforcer Init.rc"
if [ ! -f "$KERNEL_IMAGE" ]; then
  error "$KERNEL_IMAGE not found."
  exit 1
fi
cp "$KERNEL_IMAGE" .

mkdir -p overlay.d
cat << 'EOF' > overlay.d/init.special.rc
on property:sys.boot_completed=1
    write /proc/sys/vm/swappiness 60
    write /proc/sys/vm/vfs_cache_pressure 100
    write /sys/block/sda/queue/scheduler none
    write /sys/block/sdb/queue/scheduler none
    write /sys/block/sdc/queue/scheduler none
    write /sys/block/mmcblk0/queue/scheduler none
EOF

# Update AnyKernel script to automatically parse our custom init modifications for swapping and io
sed -i '/write_boot;/i \
insert_line init.rc "init.special.rc" after "import /init.environ.rc" "import /init.special.rc";' anykernel.sh

zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd "$WORKDIR"

echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> "$GITHUB_ENV"
mkdir -p "$RELEASE_DIR"
mv "$WORKDIR"/*.zip "$RELEASE_DIR"
