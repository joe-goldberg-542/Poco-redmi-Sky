#!/usr/bin/env bash

resolve_kernel_source() {
  echo "https://github.com/suvojeet-sengupta/android_kernel_xiaomi_sm4450|lineage-24.0|android15-6.6"
}

resolve_susfs_branch() {
  echo "gki-android15-6.6-dev"
}

resolve_git_branch() {
  local repo="$1"
  local preferred="$2"
  local fallback="$3"

  if command git ls-remote --exit-code --heads "$repo" "$preferred" >/dev/null 2>&1; then
    echo "$preferred"
  else
    warning "Branch '$preferred' not found in $repo, falling back to '$fallback'" >&2
    echo "$fallback"
  fi
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
        > "$output" || warning "Failed to generate changelog for ${repo}@${branch}"
}

insert_kconfig_source() {
    local kconfig_file="$1"
    local source_line="$2"

    python3 - "$kconfig_file" "$source_line" << 'EOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
line = sys.argv[2].strip()

if not path.exists():
    raise SystemExit(f"[-] Missing Kconfig file: {path}")

lines = path.read_text().splitlines(keepends=True)
lines = [l for l in lines if l.strip() != line]

last_endmenu = -1
for i, l in enumerate(lines):
    if l.strip() == "endmenu":
        last_endmenu = i

entry = line + "\n"
if last_endmenu != -1:
    lines.insert(last_endmenu, entry)
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append(entry)

path.write_text("".join(lines))
EOF
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
        git clone --depth=1 --recurse-submodules --shallow-submodules https://github.com/acmel/dwarves.git "$pahole_dir" || {
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

apply_kyber_default_patch() {
    local kroot="."
    [ -d "common/block" ] && kroot="common"
    local elevator_file="$kroot/block/elevator.c"

    if [ ! -f "$elevator_file" ]; then
        error "Missing $elevator_file"
        return 1
    fi

    log "Patching $elevator_file to set kyber as default I/O scheduler..."
    python3 - "$elevator_file" << 'EOF'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
src = path.read_text()

if 'elevator_find_get(q, "kyber")' in src:
    sys.exit(0)

pattern = re.compile(
    r'(elevator_get_default\s*\([^)]*\)\s*\{[\s\S]*?)'
    r'return\s+elevator_find_get\s*\(\s*q\s*,\s*"([^"]+)"\s*\)\s*;'
)

def repl(m):
    fallback = m.group(2)
    return (
        m.group(1)
        + '{\n'
        + '\t\tstruct elevator_type *e = elevator_find_get(q, "kyber");\n'
        + '\t\tif (e)\n'
        + '\t\t\treturn e;\n'
        + f'\t\treturn elevator_find_get(q, "{fallback}");\n'
        + '\t}'
    )

updated, count = pattern.subn(repl, src, count=1)
if count == 0:
    raise SystemExit("[-] Could not find default elevator in elevator_get_default()")

path.write_text(updated)
EOF
    success "Default kernel I/O scheduler patched to kyber"
}

integrate_finasu_manual() {
    local finasu_repo="https://github.com/LyraVoid/FinaSU.git"
    local finasu_branch
    finasu_branch="$(resolve_git_branch "$finasu_repo" "${FINASU_BRANCH:-dev}" "master")"
    local driver_dir="drivers"
    local symlink_target="../FinaSU/kernel"

    if [ -d "common/drivers" ]; then
        driver_dir="common/drivers"
        symlink_target="../../FinaSU/kernel"
    fi

    log "Cleaning previous KernelSU/BakaSU/FinaSU integrations..."
    rm -rf KernelSU FinaSU BakaSU "$driver_dir/kernelsu"
    sed -i '/kernelsu/d' "$driver_dir/Makefile" 2>/dev/null || true
    sed -i '/kernelsu/d' "$driver_dir/Kconfig" 2>/dev/null || true

    log "Cloning FinaSU ($finasu_branch) with full git metadata..."
    git clone -q -b "$finasu_branch" "$finasu_repo" ./FinaSU

    if [ ! -d "./FinaSU/kernel" ]; then
        error "FinaSU/kernel directory not found after clone!"
        return 1
    fi

    log "Manually wiring FinaSU into $driver_dir..."
    ln -sfn "$symlink_target" "$driver_dir/kernelsu"

    if ! grep -q 'kernelsu/' "$driver_dir/Makefile"; then
        printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$driver_dir/Makefile"
    fi

    insert_kconfig_source "$driver_dir/Kconfig" 'source "drivers/kernelsu/Kconfig"'

    local finasu_ver
    finasu_ver=$(command git -C ./FinaSU describe --tags --always 2>/dev/null || command git -C ./FinaSU rev-parse --short HEAD)
    success "FinaSU manually integrated (${finasu_ver} @ ${finasu_branch})"
}

clone_susfs() {
    local DEPTH=${1:-1}
    if [ ! -d "$SUSFS_DIR" ]; then
        log "Cloning $SUSFS_URL (branch $SUSFS_BRANCH, depth $DEPTH)"
        git clone --depth="$DEPTH" -q "$SUSFS_URL" -b "$SUSFS_BRANCH" "$SUSFS_DIR"
    else
        log "$SUSFS_DIR already exists, reusing existing clone"
    fi
}

apply_susfs_manual() {
    local kroot="."
    [ -d "common/fs" ] && kroot="common"

    local patch_file
    patch_file=$(find "$SUSFS_PATCHES" -maxdepth 1 -type f -name "50_add_susfs_in_*.patch" | head -n 1)
    if [ -z "$patch_file" ] || [ ! -f "$patch_file" ]; then
        error "SUSFS patch not found in $SUSFS_PATCHES"
        return 1
    fi

    local patch_name
    patch_name=$(basename "$patch_file")

    log "Manually copying SUSFS kernel files into $kroot/fs and $kroot/include/linux..."
    cp -rf "$SUSFS_PATCHES/fs/"* "$kroot/fs/"
    cp -rf "$SUSFS_PATCHES/include/linux/"* "$kroot/include/linux/"

    log "Manually applying SUSFS kernel patch ($patch_name)..."
    cp -f "$patch_file" "$kroot/$patch_name"
    (
        cd "$kroot" || exit 1
        patch -p1 --forward --fuzz=3 < "$patch_name"
    )
    rm -f "$kroot/$patch_name"

    if ! grep -q 'CFLAGS_susfs.o' "$kroot/fs/Makefile"; then
        printf '\nCFLAGS_susfs.o += -Wno-unused-function\n' >> "$kroot/fs/Makefile"
    fi

    rm -f "$kroot/android/abi_gki_protected_exports_aarch64" \
          "$kroot/android/abi_gki_protected_exports_x86_64"

    if [ ! -f "$kroot/include/linux/susfs.h" ]; then
        error "include/linux/susfs.h missing after SUSFS copy!"
        return 1
    fi

    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' "$kroot/include/linux/susfs.h" | awk '{print $3}' | tr -d '"')
    echo "SUSFS_VERSION=$SUSFS_VERSION" >> "$GITHUB_ENV"
    success "SUSFS manually integrated (version: ${SUSFS_VERSION:-unknown})"
}

integrate_nomount_manual() {
    local nomount_repo="https://github.com/maxsteeel/nomount.git"
    local nomount_branch
    nomount_branch="$(resolve_git_branch "$nomount_repo" "${NOMOUNT_BRANCH:-dev}" "master")"
    local kroot="."
    [ -d "common/fs" ] && kroot="common"

    log "Cleaning previous NoMount integration..."
    rm -rf "$WORKDIR/nomount" "$kroot/fs/nomount"
    sed -i '/CONFIG_NOMOUNT/d' "$kroot/fs/Makefile" 2>/dev/null || true

    log "Cloning NoMount ($nomount_branch)..."
    git clone -q --depth=1 -b "$nomount_branch" "$nomount_repo" "$WORKDIR/nomount"

    if [ ! -d "$WORKDIR/nomount/kernel/src" ]; then
        error "NoMount kernel/src directory not found!"
        return 1
    fi

    log "Manually wiring NoMount into $kroot/fs/nomount..."
    mkdir -p "$kroot/fs/nomount"
    cp -rf "$WORKDIR/nomount/kernel/src/"* "$kroot/fs/nomount/"

    insert_kconfig_source "$kroot/fs/Kconfig" 'source "fs/nomount/Kconfig"'

    if ! grep -q 'CONFIG_NOMOUNT' "$kroot/fs/Makefile"; then
        printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "$kroot/fs/Makefile"
    fi

    success "NoMount manually integrated ($nomount_branch)"
}
