#!/usr/bin/env bash

resolve_kernel_source() {
  echo "https://github.com/suvojeet-sengupta/android_kernel_xiaomi_sm4450|lineage-24.0|android15-6.6"
}
resolve_susfs_branch() {
  echo "gki-android15-6.6"
}

susfs_included() {
  [ "$KSU_SUSFS" == "true" ]
  return $?
}

simplify_gh_url() {
  local URL="$1"
  echo "$URL" | sed "s|https://github.com/||g" | sed "s|.git||g"
}

log() {
  echo -e "[*] $*"
}
info() { log "$@"; }

success() {
  echo -e "[+] $*"
}

warning() {
  echo -e "[!] $*"
}

error() {
  echo -e "[-] $*"
}

retry() {
    local max_attempts=5
    local delay=2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        error "Command failed (attempt $attempt/$max_attempts): $*"
        log "Retrying in ${delay}s..."
        sleep $delay
        delay=$((delay + 1))
        attempt=$((attempt + 1))
    done

    error "Command failed after $max_attempts attempts: $*" >&2
    return 1
}

curl() { retry command curl "$@"; }
wget() { retry command wget "$@"; }

bash() {
    case "$*" in
        *curl*|*wget*|*git*clone*|*git*fetch*|*git*pull*|*git*push*|*git*ls-remote*|*git*submodule*)
            retry command bash "$@"
            ;;
        *)
            command bash "$@"
            ;;
    esac
}

git() {
    local cmd="$1"
    shift
    case "$cmd" in
        clone|fetch|pull|push|ls-remote|submodule)
            retry command git "$cmd" "$@"
            ;;
        *)
            command git "$cmd" "$@"
            ;;
    esac
}

export -f retry curl git wget bash

generate_gh_changelog() {
    local repo="$1"
    local branch="$2"
    local count="${3:-5}"
    local output="$4"

    gh api "repos/${repo}/commits?sha=${branch}&per_page=${count}" \
        --jq '.[] | "- [" + .sha[0:7] + "](" + .html_url + ") " + (.commit.message | split("\n")[0])' \
        > "$output"
}

build_and_install_pahole() {
    local pahole_dir="$HOME/.local/src/pahole"
    local install_prefix="$HOME/.local"
    local bin_dir="$install_prefix/bin"
    local lib_dir="$install_prefix/lib"
    local start_dir
    start_dir="$(pwd)"

    export PATH="$bin_dir:$PATH"
    export LD_LIBRARY_PATH="$lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    mkdir -p "$bin_dir"

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get remove -y --purge dwarves pahole 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
        hash -r
    fi

    local missing=()
    for pkg in cmake libdw-dev libelf-dev zlib1g-dev; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} )); then
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing[@]}" || {
            error "failed to install build deps: ${missing[*]}"
            return 1
        }
    fi

    if [[ ! -d "$pahole_dir/.git" ]]; then
        rm -rf "$pahole_dir"
        git clone --depth=1 https://git.kernel.org/pub/scm/devel/pahole/pahole.git "$pahole_dir" || {
            error "failed to clone pahole"
            return 1
        }
    else
        git -C "$pahole_dir" fetch --depth=1 origin master
        git -C "$pahole_dir" reset --hard origin/master
    fi

    local build_dir="$pahole_dir/build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir" || return 1

    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_prefix" \
        -DCMAKE_INSTALL_RPATH="$lib_dir" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -D__LIB=lib \
        .. || {
        error "cmake failed"
        cd "$start_dir"
        return 1
    }

    make -j"$(nproc)" || {
        error "pahole build failed"
        cd "$start_dir"
        return 1
    }

    make install || {
        error "pahole install failed"
        cd "$start_dir"
        return 1
    }

    cd "$start_dir"
    hash -r

    if ! command -v pahole >/dev/null 2>&1; then
        error "pahole not found in PATH after install"
        return 1
    fi

    success "pahole $(pahole --version | head -1) installed to $bin_dir"
    return 0
}

clone_susfs() {
    DEPTH=${1:-50}
    if [ ! -d "$SUSFS_DIR" ]; then
        log "Cloning $SUSFS_URL (branch $SUSFS_BRANCH, depth $DEPTH)"
        git clone --depth=$DEPTH -q "$SUSFS_URL" -b "$SUSFS_BRANCH" "$SUSFS_DIR"
    else
        log "$SUSFS_DIR already exists, reusing existing clone"
    fi
}

# ==============================================================================
# 1. OFFICIAL KERNELSU - MANUAL INTEGRATION
# ==============================================================================
integrate_ksu_manual() {
    log "Integrating Official KernelSU (tiann/KernelSU) manually..."

    # Clean any existing KSU directories/entries in kernel source
    rm -rf KernelSU FinaSU drivers/kernelsu
    sed -i '/kernelsu/d' drivers/Makefile 2>/dev/null || true
    sed -i '/kernelsu/d' drivers/Kconfig 2>/dev/null || true

    # Clone Official KernelSU
    git clone https://github.com/tiann/KernelSU.git KernelSU

    # If SUSFS is enabled, ensure KernelSU commit matches 10_enable_susfs_for_ksu.patch
    if susfs_included; then
        clone_susfs 50
        local ksu_patch="$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch"
        if [ -f "$ksu_patch" ]; then
            if ! patch -d KernelSU -p1 --dry-run --fuzz=3 < "$ksu_patch" >/dev/null 2>&1; then
                warning "Latest KernelSU HEAD drifted from SUSFS patch; looking up synced commit from SUSFS history..."
                local synced_commit
                synced_commit=$(git -C "$SUSFS_DIR" log -n 50 --grep="KernelSU" -i --pretty=format:"%s %b" \
                    | grep -oE '\b[0-9a-f]{7,40}\b' | head -n 1 || true)
                if [ -n "$synced_commit" ] && git -C KernelSU cat-file -e "${synced_commit}^{commit}" 2>/dev/null; then
                    log "Rolling back KernelSU to SUSFS-synced commit: $synced_commit"
                    git -C KernelSU checkout "$synced_commit"
                else
                    local susfs_ts
                    susfs_ts=$(git -C "$SUSFS_DIR" log -1 --format="%ct" -- "kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch")
                    if [ -n "$susfs_ts" ]; then
                        local fallback_commit
                        fallback_commit=$(git -C KernelSU rev-list -n 1 --before="$susfs_ts" main || true)
                        if [ -n "$fallback_commit" ]; then
                            log "Rolling back KernelSU to timestamp-matched commit: $fallback_commit"
                            git -C KernelSU checkout "$fallback_commit"
                        fi
                    fi
                fi
            fi
        fi
    fi

    # Manual symlink & Kbuild integration (instead of running KernelSU/kernel/setup.sh)
    ln -sf ../KernelSU/kernel drivers/kernelsu

    if ! grep -q "kernelsu" drivers/Makefile; then
        echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
    fi

    if ! grep -q "drivers/kernelsu/Kconfig" drivers/Kconfig; then
        sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    fi

    # Download latest Official KernelSU Manager APK into artifacts
    local ksu_apk_url
    ksu_apk_url=$(gh api repos/tiann/KernelSU/releases/latest --jq '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' 2>/dev/null | head -n 1 || true)
    if [ -n "$ksu_apk_url" ]; then
        log "Downloading Official KernelSU Manager APK..."
        curl -sL "$ksu_apk_url" -o "$RELEASE_DIR/KernelSU-Manager.apk" || true
    fi

    success "Official KernelSU linked manually into drivers/kernelsu"
}

# ==============================================================================
# 2. SUSFS - MANUAL INTEGRATION (susfsREADME.md Steps 3 to 11)
# ==============================================================================
apply_susfs_patches_manual() {
    log "Applying SUSFS patches manually (susfsREADME.md instructions)..."

    # Step 3 & 7: Copy and apply 10_enable_susfs_for_ksu.patch inside KernelSU
    if [ -d "./KernelSU" ] && [ -f "$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
        cp "$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch" ./KernelSU/
        (
            cd ./KernelSU
            log "Patching KernelSU with 10_enable_susfs_for_ksu.patch..."
            patch -p1 --fuzz=3 < 10_enable_susfs_for_ksu.patch
        )
    fi

    # Step 4, 5, 6: Copy fs/*, include/linux/*, and 50_add_susfs_in_*.patch to kernel root
    cp "$SUSFS_PATCHES/50_add_susfs_in_${SUSFS_PATCH}.patch" ./
    cp -R "$SUSFS_PATCHES/fs/"* ./fs/
    cp -R "$SUSFS_PATCHES/include/linux/"* ./include/linux/

    # Step 8: Apply 50_add_susfs_in_kernel patch
    log "Patching Kernel with 50_add_susfs_in_${SUSFS_PATCH}.patch..."
    patch -p1 --fuzz=3 < "50_add_susfs_in_${SUSFS_PATCH}.patch"
    echo "CFLAGS_susfs.o += -Wno-unused-function" >> ./fs/Makefile

    # Step 11: Remove ABI protected exports on Android 14+ GKI so Wi-Fi/vendor modules load
    rm -f ./android/abi_gki_protected_exports_aarch64 ./android/abi_gki_protected_exports_x86_64

    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
    echo "SUSFS_VERSION=$SUSFS_VERSION" >> "$GITHUB_ENV"
    success "SUSFS ${SUSFS_VERSION} manually integrated"
}

# ==============================================================================
# 3. KERNELSU MANUAL SOURCE HOOKS (Kernelsuhow-to-integrate-for-non-gki.md)
# ==============================================================================
apply_ksu_manual_hooks() {
    # Prerequisite #2 & #3 of susfsREADME.md:
    # SUSFS v2.0.0+ already patches sucompat & inline hooks in fs/exec.c, fs/open.c,
    # fs/stat.c, etc. Only inject manual hooks into files that do NOT already have them.
    log "Verifying / applying manual KernelSU C hooks..."

    python3 - << 'EOF'
import os, re

def patch_if_missing(filepath, marker, pattern, replacement):
    if not os.path.exists(filepath):
        return
    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    if marker in content:
        print(f"[*] {filepath}: '{marker}' already present (handled by SUSFS/kernel), skipping.")
        return
    new_content, count = re.subn(pattern, replacement, content, count=1, flags=re.M)
    if count > 0:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(new_content)
        print(f"[+] {filepath}: manually hooked '{marker}'.")
    else:
        print(f"[!] {filepath}: target function pattern not matched for '{marker}', skipping.")

# 1. fs/exec.c (do_execveat_common)
patch_if_missing(
    "fs/exec.c",
    "ksu_handle_execveat",
    r"(^static int do_execveat_common\([^\)]*\)\s*\{)",
    r"""#ifdef CONFIG_KSU
extern bool ksu_execveat_hook __read_mostly;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
			void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
				 void *argv, void *envp, int *flags);
#endif
\1
#ifdef CONFIG_KSU
	if (unlikely(ksu_execveat_hook))
		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	else
		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif"""
)

# 2. fs/open.c (do_faccessat)
patch_if_missing(
    "fs/open.c",
    "ksu_handle_faccessat",
    r"(^long do_faccessat\(int dfd, const char __user \*filename, int mode(?:, int flags)?\)\s*\{)",
    r"""#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
			 int *flags);
#endif
\1
#ifdef CONFIG_KSU
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif"""
)

# 3. fs/stat.c (vfs_statx)
patch_if_missing(
    "fs/stat.c",
    "ksu_handle_stat",
    r"(^int vfs_statx\(int dfd, struct filename \*filename, int flags,[\s\S]*?\{|^int vfs_statx\(int dfd, const char __user \*filename, int flags,[\s\S]*?\{)",
    r"""#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
\1
#ifdef CONFIG_KSU
	ksu_handle_stat(&dfd, (const char __user **)&filename, &flags);
#endif"""
)

# 4. fs/read_write.c (vfs_read)
patch_if_missing(
    "fs/read_write.c",
    "ksu_handle_vfs_read",
    r"(^ssize_t vfs_read\(struct file \*file, char __user \*buf, size_t count, loff_t \*pos\)\s*\{\s*ssize_t ret;)",
    r"""#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
			size_t *count_ptr, loff_t **pos);
#endif
\1
#ifdef CONFIG_KSU
	if (unlikely(ksu_vfs_read_hook))
		ksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif"""
)

# 5. drivers/input/input.c (input_handle_event - Safe Mode)
patch_if_missing(
    "drivers/input/input.c",
    "ksu_handle_input_handle_event",
    r"(^static void input_handle_event\(struct input_dev \*dev,\s*unsigned int type, unsigned int code, int value\)\s*\{\s*int disposition = input_get_disposition\(dev, type, code, &value\);)",
    r"""#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
\1
#ifdef CONFIG_KSU
	if (unlikely(ksu_input_hook))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif"""
)

# 6. fs/devpts/inode.c (devpts_get_priv - fixes 'pm' in terminal)
patch_if_missing(
    "fs/devpts/inode.c",
    "ksu_handle_devpts",
    r"(^void \*devpts_get_priv\(struct dentry \*dentry\)\s*\{)",
    r"""#ifdef CONFIG_KSU
extern int ksu_handle_devpts(struct inode*);
#endif
\1
#ifdef CONFIG_KSU
	ksu_handle_devpts(dentry->d_inode);
#endif"""
)
EOF
}

# ==============================================================================
# 4. NOMOUNT - MANUAL BUILT-IN INTEGRATION (NOmountREADME.md Method 3)
# ==============================================================================
integrate_nomount_manual() {
    local branch="${1:-dev}"
    local nomount_dir="$WORKDIR/nomount"

    log "Integrating NoMount ($branch) manually (Method 3)..."

    rm -rf "$nomount_dir"
    git clone -q --depth=1 -b "$branch" https://github.com/maxsteeel/nomount.git "$nomount_dir"

    # Step 3: Copy src/* to fs/nomount/
    mkdir -p ./fs/nomount
    cp -rf "$nomount_dir/kernel/src/"* ./fs/nomount/

    # Step 1: Add source "fs/nomount/Kconfig" to fs/Kconfig
    if ! grep -q 'fs/nomount/Kconfig' ./fs/Kconfig; then
        sed -i '/endmenu/i source "fs/nomount/Kconfig"' ./fs/Kconfig
    fi

    # Step 2: Add obj-$(CONFIG_NOMOUNT) += nomount/ to fs/Makefile
    if ! grep -q 'CONFIG_NOMOUNT' ./fs/Makefile; then
        echo 'obj-$(CONFIG_NOMOUNT) += nomount/' >> ./fs/Makefile
    fi

    success "NoMount manually integrated into fs/nomount"
}
