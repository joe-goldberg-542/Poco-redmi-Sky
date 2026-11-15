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

integrate_bakasu() {
    local start_dir
    start_dir="$(pwd)"

    log "Integrating BakaSU..."
    rm -rf KernelSU FinaSU BakaSU drivers/kernelsu
    sed -i '/kernelsu/d' drivers/Makefile 2>/dev/null || true
    sed -i '/kernelsu/d' drivers/Kconfig 2>/dev/null || true

    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | command bash -s main

    cd KernelSU
    command git config --local remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    command git fetch --quiet origin --prune
    command git checkout -B main origin/main

    python3 - << 'EOF'
import json
import os
import subprocess
import time
import urllib.request

OWNER = "Baka-SU"
REPO = "BakaSU"
BASE = "main"
CUTOFF = int(time.time()) - (90 * 86400)
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

def gh_api(path):
    url = f"https://api.github.com/repos/{OWNER}/{REPO}{path}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "BakaSU-Merger"
    }
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode())

def run_git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)

drafts = set()
try:
    for pr in gh_api("/pulls?state=open&per_page=100"):
        ref = pr.get("head", {}).get("ref")
        if ref and pr.get("draft", False):
            drafts.add(ref)
except Exception as e:
    print(f"[WARN] PR fetch error: {e}")

def is_green(sha):
    try:
        runs = gh_api(f"/commits/{sha}/check-runs?per_page=100").get("check_runs", [])
        if not runs:
            return False
        ok = False
        for r in runs:
            if r.get("status") != "completed":
                return False
            c = r.get("conclusion")
            if c == "success":
                ok = True
            elif c not in ("skipped", "neutral"):
                return False
        return ok
    except Exception:
        return False

fmt = "%(refname:short)|%(objectname)|%(committerdate:unix)"
refs = run_git(
    "for-each-ref", "--sort=-committerdate", f"--format={fmt}", "refs/remotes/origin/"
).stdout.strip().splitlines()

merged = []
for line in refs:
    if "|" not in line:
        continue
    ref, sha, ts = line.split("|", 2)
    branch = ref.replace("origin/", "", 1)

    if branch in (BASE, "HEAD") or int(ts) < CUTOFF:
        continue

    ahead_str = run_git("rev-list", "--count", f"origin/{BASE}..{ref}").stdout.strip()
    ahead = int(ahead_str) if ahead_str.isdigit() else 0
    if ahead <= 0 or branch in drafts or not is_green(sha):
        continue

    res = run_git("merge", "--no-edit", "-m", f"Merge {branch} into {BASE}", ref)
    if res.returncode == 0:
        merged.append(branch)
        print(f"[OK] Merged into {BASE}: {branch} (+{ahead})")
    else:
        run_git("merge", "--abort")
        print(f"[SKIP] Conflict: {branch}")

print(f"Total dynamic branches merged into {BASE}: {len(merged)}")
EOF

    cd "$start_dir"
}

clone_susfs() {
    DEPTH=${1:-1}
    if [ ! -d "$SUSFS_DIR" ]; then
        log "Cloning $SUSFS_URL (branch $SUSFS_BRANCH, depth $DEPTH)"
        git clone --depth=$DEPTH -q "$SUSFS_URL" -b "$SUSFS_BRANCH" "$SUSFS_DIR"
    else
        log "$SUSFS_DIR already exists, reusing existing clone"
    fi
}

apply_susfs_patches() {
    log "Applying SUSFS kernel patches"

    cp "$SUSFS_PATCHES/50_add_susfs_in_${SUSFS_PATCH}.patch" ./
    cp -R "$SUSFS_PATCHES/fs/"* ./fs/
    cp -R "$SUSFS_PATCHES/include/linux/"* ./include/linux/

    patch -p1 --fuzz=3 < "50_add_susfs_in_${SUSFS_PATCH}.patch"
    echo "CFLAGS_susfs.o += -Wno-unused-function" >> ./fs/Makefile

    rm -f ./android/abi_gki_protected_exports_aarch64 \
          ./android/abi_gki_protected_exports_x86_64

    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
    echo "SUSFS_VERSION=$SUSFS_VERSION" >> "$GITHUB_ENV"
}

apply_bakasu_manual_hooks() {
    log "Applying BakaSU manual hooks and SELinux symbol exports"

    python3 - << 'EOF'
import re
from pathlib import Path

def patch_file(path_str, fn):
    p = Path(path_str)
    if not p.exists():
        raise SystemExit(f"Missing file: {path_str}")
    orig = p.read_text()
    updated = fn(orig)
    if orig != updated:
        p.write_text(updated)
        print(f"[OK] Patched {path_str}")

def patch_stat(s):
    if "ksu_handle_newfstat_ret" in s:
        return s
    ext = (
        "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n"
        "\t\t\t\tint *flags);\n\n"
        "extern void ksu_handle_newfstat_ret(unsigned int *fd, "
        "struct stat __user **statbuf_ptr);\n"
        "#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)\n"
        "extern void ksu_handle_fstat64_ret(unsigned long *fd, "
        "struct stat64 __user **statbuf_ptr);\n"
        "#endif\n"
        "#endif\n\n"
    )
    s = re.sub(r'(SYSCALL_DEFINE4\(newfstatat,)', ext + r'\1', s, count=1)
    s = re.sub(
        r'(\terror = vfs_fstatat\(dfd, filename, &stat, flag\);)',
        '#ifdef CONFIG_KSU_MANUAL_HOOK\n'
        '\tksu_handle_stat(&dfd, &filename, &flag);\n'
        '#endif\n\\1',
        s
    )
    s = re.sub(
        r'(SYSCALL_DEFINE2\(newfstat,[\s\S]*?cp_new_stat\(&stat, statbuf\);\n)',
        r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n'
        r'\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n',
        s, count=1
    )
    s = re.sub(
        r'(SYSCALL_DEFINE2\(fstat64,[\s\S]*?cp_new_stat64\(&stat, statbuf\);\n)',
        r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n'
        r'\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n',
        s, count=1
    )
    return s

def patch_exec(s):
    if "ksu_handle_post_execveat" in s:
        return s
    ext = (
        "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t\tvoid *argv, void *envp, int *flags);\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t\tvoid *argv, void *envp, int *flags, int *retval);\n"
        "#endif\n\n"
    )
    s = re.sub(
        r'(static int do_execveat_common\(int fd, struct filename \*filename,)',
        ext + r'\1', s, count=1
    )
    s = re.sub(
        r'(static int do_execveat_common\([\s\S]*?)(\tif \(IS_ERR\(filename\)\))',
        r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n'
        r'\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n'
        r'#endif\n\n\2',
        s, count=1
    )
    s = re.sub(
        r'(static int do_execveat_common\([\s\S]*?out_ret:\n)',
        r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n'
        r'\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);\n'
        r'#endif\n',
        s, count=1
    )
    return s

def patch_open(s):
    if "ksu_handle_faccessat" in s:
        return s
    ext = (
        "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
        "\t\t\t\tint *mode, int *flags);\n"
        "#endif\n\n"
    )
    return re.sub(
        r'(SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\n\{\n)',
        ext + r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n'
        r'\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n',
        s, count=1
    )

def patch_reboot(s):
    if "ksu_handle_sys_reboot" in s:
        return s
    ext = (
        "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "extern int ksu_handle_sys_reboot(int magic1, int magic2, "
        "unsigned int cmd, void __user **arg);\n"
        "#endif\n\n"
    )
    s = re.sub(r'(SYSCALL_DEFINE4\(reboot,)', ext + r'\1', s, count=1)
    return re.sub(
        r'(SYSCALL_DEFINE4\(reboot,[\s\S]*?)(\tif \(!ns_capable\(pid_ns->user_ns, CAP_SYS_BOOT\)\))',
        r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n'
        r'\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\2',
        s, count=1
    )

def patch_selinuxfs(s):
    s = re.sub(
        r'static\s+(ssize_t\s+\(\*write_op\[\]\)\(struct file \*, char \*, size_t\)\s*=\s*\{)',
        r'\1', s
    )
    return re.sub(
        r'static\s+(const\s+struct\s+file_operations\s+sel_handle_status_ops\s*=\s*\{)',
        r'\1', s
    )

def patch_selinux_services(s):
    s = re.sub(r'static\s+(void\s+security_dump_masked_av\s*\()', r'\1', s)
    return re.sub(r'static\s+(void\s+context_struct_compute_av\s*\()', r'\1', s)

patch_file("fs/stat.c", patch_stat)
patch_file("fs/exec.c", patch_exec)
patch_file("fs/open.c", patch_open)
patch_file("kernel/reboot.c", patch_reboot)
patch_file("security/selinux/selinuxfs.c", patch_selinuxfs)
patch_file("security/selinux/ss/services.c", patch_selinux_services)
EOF
}

integrate_nomount_manual() {
    log "Applying NoMount"

    rm -rf "$WORKDIR/nomount"
    git clone -q --depth=1 -b dev https://github.com/maxsteeel/nomount.git "$WORKDIR/nomount"

    if ! grep -q 'source "fs/nomount/Kconfig"' ./fs/Kconfig; then
        sed -i '/endmenu/i source "fs/nomount/Kconfig"' ./fs/Kconfig
    fi

    if ! grep -q 'CONFIG_NOMOUNT' ./fs/Makefile; then
        echo 'obj-$(CONFIG_NOMOUNT) += nomount/' >> ./fs/Makefile
    fi

    mkdir -p ./fs/nomount
    cp -f "$WORKDIR/nomount/kernel/src/"* ./fs/nomount/
}
