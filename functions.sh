#!/usr/bin/env bash

resolve_kernel_source() {
  echo "https://github.com/xiaomi-ravelin/android_kernel_xiaomi_sm4450|lineage-24.0|android15-6.6"
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

cleanup_abi_gki_protected_exports() {
    local files_found=0

    for path in "android" "."; do
        if [[ -d "$path" ]] && compgen -G "$path/*protected_exports*" > /dev/null; then
            rm -rf "$path"/*protected_exports*
            files_found=1
        fi
    done

    if [[ $files_found -eq 0 ]]; then
        success "No ABI GKI protected exports files found to remove"
    else
        success "Removed ABI GKI protected exports file(s)"
    fi
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

apply_susfs_patches() {
    log "Applying SUSFS patches"
    cp -R $SUSFS_PATCHES/fs/* ./fs
    cp -R $SUSFS_PATCHES/include/linux/* ./include/linux/
    patch -p1 --fuzz=3 < "$SUSFS_PATCHES/50_add_susfs_in_${SUSFS_PATCH}.patch"
    
    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
    echo "SUSFS_VERSION=$SUSFS_VERSION" >> $GITHUB_ENV
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
