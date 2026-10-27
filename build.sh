#!/usr/bin/env bash
set -eo pipefail

if [ -n "${_BUILD_SH_RUNNING:-}" ]; then
  echo "[-] CRITICAL ERROR: Infinite loop detected! You accidentally pasted build.sh code inside functions.sh!"
  exit 1
fi
export _BUILD_SH_RUNNING=1

WORKDIR="$(pwd)"
RELEASE_DIR="$WORKDIR/artifacts"

KERNEL_NAME="sky"
USER=""
HOST="sky"
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

# Clean any pre-existing .rej files committed in the upstream kernel repo
find "$KSRC" -name "*.rej" -type f -delete || true

cd "$KSRC"

# Fix duplicate dtbs / dtbs_install / scripts_dtc / dt_binding_check target warnings in root Makefile
python3 - << 'EOF'
with open("Makefile", "r") as f:
    lines = f.readlines()

dt_check_indices = [i for i, l in enumerate(lines) if l.startswith("dt_binding_check:")]
if len(dt_check_indices) > 1:
    first_dt_check = dt_check_indices[0]
    block_start = None
    for i in range(first_dt_check, max(-1, first_dt_check - 50), -1):
        if lines[i].startswith("ifneq ($(dtstree),)"):
            block_start = i
            break
    block_end = first_dt_check
    while block_end + 1 < len(lines) and lines[block_end + 1].startswith("	"):
        block_end += 1
    if block_start is not None:
        for i in range(block_start, block_end + 1):
            lines[i] = "# " + lines[i]
        with open("Makefile", "w") as f:
            f.writelines(lines)
        print("[+] Fixed duplicate dtbs/scripts_dtc/dt_binding_check target recipes in Makefile")
EOF

LINUX_VERSION=$(make kernelversion)
LINUX_VERSION_CODE=${LINUX_VERSION//./}
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
echo "LINUX_VERSION=$LINUX_VERSION" >> "$GITHUB_ENV"
cd "$WORKDIR"

log "Setting Kernel variant"
case "$KSU" in
  "SKSU") VARIANT="SukiSU-Ultra" ;;
  "FinaSU") VARIANT="FinaSU" ;;
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
find "$SUSFS_DIR" -name "*.rej" -type f -delete || true
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

cleanup_abi_gki_protected_exports

if [ -d "kernel/sched/walt" ]; then
  log "Patching WALT governor (Retaining App Launch Boost)"
  sed -i 's/queue_work(input_boost_wq, &input_boost_work);/\/\* killed schedutil-style \*\//g' kernel/sched/walt/input-boost.c
  sed -i 's/if (wg_policy->tunables->pl)/if (0)/g' kernel/sched/walt/cpufreq_walt.c
  sed -i 's/#define DEFAULT_HISPEED_LOAD 90/#define DEFAULT_HISPEED_LOAD 105/g' kernel/sched/walt/cpufreq_walt.c
  sed -i 's/if (wrq->ed_task)/if (0)/g' kernel/sched/walt/walt.c
  sed -i 's/if (should_apply_suh_freq_boost(cluster))/if (0)/g' kernel/sched/walt/walt.c
  sed -i 's/if (wrq->lrb_pipeline_start_time)/if (0)/g' kernel/sched/walt/walt.c
  sed -i 's/wtg->sched_boost_enable\[BALANCE_BOOST\] = true/wtg->sched_boost_enable\[BALANCE_BOOST\] = false/g' kernel/sched/walt/boost.c
  sed -i 's/#define DEFAULT_SILVER_RTG_BOOST_FREQ 1000000/#define DEFAULT_SILVER_RTG_BOOST_FREQ 0/g' kernel/sched/walt/cpufreq_walt.c
  sed -i 's/#define DEFAULT_GOLD_RTG_BOOST_FREQ 768000/#define DEFAULT_GOLD_RTG_BOOST_FREQ 0/g' kernel/sched/walt/cpufreq_walt.c
fi

if [ "$KSU" = "FinaSU" ]; then
  log "FinaSU Integration (Exact as reference build.yml)..."

  rm -rf KernelSU FinaSU drivers/kernelsu
  sed -i '/kernelsu/d' drivers/Makefile 2>/dev/null || true
  sed -i '/kernelsu/d' drivers/Kconfig 2>/dev/null || true

  git clone -b dev https://github.com/LyraVoid/FinaSU.git FinaSU
  find FinaSU -name "*.rej" -type f -delete || true

  mkdir -p /tmp/finasu_ci
  ARTIFACT_ID=$(gh api "/repos/LyraVoid/FinaSU/actions/artifacts?name=manager&per_page=10" \
    --jq '.artifacts | map(select(.expired == false)) | .[0].id // empty' 2>/dev/null || true)

  if [ -n "$ARTIFACT_ID" ] && gh api "/repos/LyraVoid/FinaSU/actions/artifacts/$ARTIFACT_ID/zip" > /tmp/finasu_ci/artifact.zip 2>/dev/null; then
    unzip -q -o /tmp/finasu_ci/artifact.zip -d /tmp/finasu_ci/
  elif curl -fL "https://nightly.link/LyraVoid/FinaSU/workflows/build/dev/manager.zip" -o /tmp/finasu_ci/artifact.zip; then
    unzip -q -o /tmp/finasu_ci/artifact.zip -d /tmp/finasu_ci/
  fi

  CI_APK=$(find /tmp/finasu_ci -name "*.apk" | head -n 1)
  if [ -n "$CI_APK" ] && [ -f "$CI_APK" ]; then
    log "Found Manager APK: $CI_APK"
    cp "$CI_APK" "$RELEASE_DIR/FinaSU-Manager.apk"
    export APK_TO_SYNC="$CI_APK"
  else
    export APK_TO_SYNC=""
  fi

  python3 - << 'EOF'
import os, re, struct, hashlib, glob

apk_path = os.environ.get("APK_TO_SYNC", "")
expected_size = None
expected_hash = None

if apk_path and os.path.exists(apk_path):
    with open(apk_path, "rb") as f:
        data = f.read()
    eocd = data.rfind(b"PK\x05\x06")
    if eocd != -1:
        cd_offset = struct.unpack("<I", data[eocd+16:eocd+20])[0]
        if data[cd_offset-16:cd_offset] == b"APK Sig Block 42":
            block_size = struct.unpack("<Q", data[cd_offset-24:cd_offset-16])[0]
            pos = cd_offset - block_size
            while pos < cd_offset - 24:
                pair_len = struct.unpack("<Q", data[pos:pos+8])[0]
                pair_id = struct.unpack("<I", data[pos+8:pos+12])[0]
                if pair_id in (0x7109871a, 0xf05368c0):
                    val = data[pos+12:pos+8+pair_len]
                    digests_len = struct.unpack("<I", val[12:16])[0]
                    certs_off = 16 + digests_len
                    cert_len = struct.unpack("<I", val[certs_off+4:certs_off+8])[0]
                    cert_bytes = val[certs_off+8:certs_off+8+cert_len]
                    expected_size = f"0x{cert_len:04x}"
                    expected_hash = hashlib.sha256(cert_bytes).hexdigest()
                    break
                pos += 8 + pair_len

if expected_size and expected_hash:
    print(f"Syncing FinaSU CI APK Signature -> size: {expected_size}, hash: {expected_hash}")
    for kfile in glob.glob("FinaSU/kernel/**/Kbuild", recursive=True) + glob.glob("FinaSU/kernel/**/Makefile", recursive=True):
        if os.path.exists(kfile):
            with open(kfile, "r") as f:
                content = f.read()
            content = re.sub(r'0x0*33b', expected_size, content)
            content = re.sub(r'c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6', expected_hash, content)
            with open(kfile, "w") as f:
                f.write(content)
EOF

  ln -sf $(pwd)/FinaSU/kernel drivers/kernelsu
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
  sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

  if susfs_included; then
    clone_susfs
    apply_susfs_patches
  fi
fi

if [ "$NM" = "true" ]; then
  log "Applying NoMount (dev)"
  curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s dev
  find NoMount -name "*.rej" -type f -delete 2>/dev/null || true
  VARIANT+="+NoMount"
fi

echo "VARIANT=$VARIANT" >> "$GITHUB_ENV"
echo "::endgroup::"
set +eo pipefail

AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

log "Applying inline defconfigs..."

./scripts/config --file arch/arm64/configs/gki_defconfig -d RCU_TRACE

if [ "$KSU" != "no" ]; then
  ./scripts/config --file arch/arm64/configs/gki_defconfig \
    -e KSU \
    -e HEADERS_INSTALL \
    -e EXT4_FS \
    -d KSU_DEBUG \
    -e KSU_SENTINEL \
    -e KALLSYMS \
    -e KALLSYMS_ALL \
    -e KPROBES \
    -e HAVE_KPROBES \
    -e KPROBE_EVENTS \
    -e OVERLAY_FS
fi

if [ "$NM" = "true" ]; then
  ./scripts/config --file arch/arm64/configs/gki_defconfig -e NOMOUNT
fi

if susfs_included; then
  ./scripts/config --file arch/arm64/configs/gki_defconfig \
    -e KSU_SUSFS \
    -e THREAD_INFO_IN_TASK \
    -e KSU_SUSFS_SUS_MAP \
    -e KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -e KSU_INLINE_HOOK \
    -e KSU_SUSFS_SUS_MEMFD \
    -e KSU_SUSFS_SUS_PROC_FD_LINK
fi

if [ "${TODO:-kernel}" = "kernel" ]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  ./scripts/config --file arch/arm64/configs/gki_defconfig --set-str LOCALVERSION "-android15-11-g${LATEST_COMMIT_HASH}"
  ./scripts/config --file arch/arm64/configs/gki_defconfig --disable LOCALVERSION_AUTO
  sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion
fi

export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(git -C "$KSRC" log -1 --format=%cd --date=format-local:'%a %b %d %T %z %Y')
export KCFLAGS="-w"
export HOSTCFLAGS="-w -Wno-error -Wno-incompatible-pointer-types-discards-qualifiers -Wno-unused-but-set-global -Wno-unknown-warning-option"
export KBUILD_HOSTCFLAGS="$HOSTCFLAGS"

LINKER_SHIM="$WORKDIR/clang-lto-linker"
MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  HOSTCFLAGS="$HOSTCFLAGS"
  EXTRA_CFLAGS="-w -Wno-error -Wno-incompatible-pointer-types-discards-qualifiers"
  KSU_REQUIRE_PREINIT=1
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
  log "Merging gki_defconfig + vendor/parrot_perf.config for POCO M6 Pro 5G (Sky)"
  make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG" vendor/parrot_perf.config
else
  make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"
fi

log "Injecting LTO Method: ${LTO:-full}"
if [ "${LTO:-full}" = "full" ]; then
  ./scripts/config --file "$OUTDIR/.config" -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG_FULL
  MAKE_ARGS+=(LTO=full)
elif [ "${LTO:-full}" = "thin" ]; then
  ./scripts/config --file "$OUTDIR/.config" -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL
  MAKE_ARGS+=(LTO=thin)
elif [ "${LTO:-full}" = "none" ]; then
  ./scripts/config --file "$OUTDIR/.config" -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL
  MAKE_ARGS+=(LTO=none)
fi
make "${MAKE_ARGS[@]}" olddefconfig > /dev/null
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
log "Zipping anykernel"
if [ ! -f "$KERNEL_IMAGE" ]; then
  error "$KERNEL_IMAGE not found."
  exit 1
fi
cp "$KERNEL_IMAGE" .
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd "$WORKDIR"

echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> "$GITHUB_ENV"
mkdir -p "$RELEASE_DIR"
mv "$WORKDIR"/*.zip "$RELEASE_DIR"
