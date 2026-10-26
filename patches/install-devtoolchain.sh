#!/bin/bash
# install-devtoolchain.sh - download and install the Go and/or Rust toolchains.
#
# kan-linux skill: x86_64 Linux only. Toolchains come from the official
# release tarballs and are installed under /opt so they stay out of the
# system package manager. Add the bin directories to your PATH afterwards,
# e.g. in ~/.bashrc:
#
#   export PATH="/opt/go/bin:/opt/rust/rustc/bin:/opt/rust/cargo/bin:$PATH"
#
# Official distribution URLs only (go.dev, static.rust-lang.org).
# No third-party mirrors.
set -euo pipefail

GO_DEFAULT_VERSION=1.27.2
RUST_DEFAULT_VERSION=1.99.1
GO_ROOT=/opt/go
RUST_ROOT=/opt/rust
# kan-linux is x86_64-only; keep these in sync with the distro target.
GO_TARBALL_OS_ARCH=linux-amd64
RUST_TARBALL_TRIPLE=x86_64-unknown-linux-gnu

log()  { echo "[install-devtoolchain] $*"; }
die()  { echo "[install-devtoolchain] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-devtoolchain.sh [go|rust|all] [--version <ver>] [--force]

Download and install the Go and/or Rust toolchains to /opt.

  go      Install the Go toolchain to /opt/go
  rust    Install the Rust toolchain to /opt/rust
  all     Install both (default)

Options:
  --version <ver>   Go: release version, e.g. 1.27.2
                    Rust: release version, e.g. 1.99.1
                    With 'all', applies to the toolchain named just before it;
                    otherwise use separate invocations.
  --force           Reinstall even if the toolchain is already present

After installation add the toolchains to your PATH:

  export PATH="/opt/go/bin:/opt/rust/rustc/bin:/opt/rust/cargo/bin:$PATH"

Examples:
  install-devtoolchain.sh
  install-devtoolchain.sh go --version 1.27.2
  install-devtoolchain.sh rust --version 1.99.1
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

fetch() {
    local url="$1" dest="$2"
    if have curl; then
        curl -fL --progress-bar "$url" -o "$dest"
    elif have wget; then
        wget -O "$dest" "$url"
    else
        die "neither curl nor wget is available"
    fi
}

# Go's release tarball unpacks to a "go/" directory. Extract into /opt so the
# toolchain lands at /opt/go with GOROOT=/opt/go and binaries in /opt/go/bin.
install_go() {
    local version="$1"
    local tmp tarball url

    if [ -x "${GO_ROOT}/bin/go" ] && [ "$FORCE" -eq 0 ]; then
        log "Go is already installed at ${GO_ROOT} ($(${GO_ROOT}/bin/go version 2>/dev/null || echo unknown))"
        log "use --force to reinstall"
        return 0
    fi

    # Accept both "1.27.2" and "go1.27.2".
    version="${version#go}"
    tarball="go${version}.${GO_TARBALL_OS_ARCH}.tar.gz"
    url="https://go.dev/dl/${tarball}"
    tmp="$(mktemp -d)"

    log "Downloading Go ${version} from ${url}"
    fetch "$url" "${tmp}/${tarball}"

    log "Installing Go to ${GO_ROOT}"
    rm -rf "${GO_ROOT}"
    tar -C /opt -xzf "${tmp}/${tarball}"
    rm -rf "$tmp"

    [ -x "${GO_ROOT}/bin/go" ] || die "Go install failed: ${GO_ROOT}/bin/go not found"
    log "Go installed: $(${GO_ROOT}/bin/go version)"
}

# Rust's combined standalone tarball unpacks to component directories
# (rustc/, cargo/, rust-std-*/, ...). Extract into /opt/rust so binaries land
# at /opt/rust/rustc/bin and /opt/rust/cargo/bin — the layout the PATH hint
# assumes. rustup cannot produce this split.
install_rust() {
    local version="$1"
    local tmp triple tarball url

    if [ -x "${RUST_ROOT}/rustc/bin/rustc" ] && [ "$FORCE" -eq 0 ]; then
        log "Rust is already installed at ${RUST_ROOT} ($(${RUST_ROOT}/rustc/bin/rustc --version 2>/dev/null || echo unknown))"
        log "use --force to reinstall"
        return 0
    fi

    triple="${RUST_TARBALL_TRIPLE}"
    tarball="rust-${version}-${triple}.tar.xz"
    url="https://static.rust-lang.org/dist/${tarball}"
    tmp="$(mktemp -d)"

    log "Downloading Rust ${version} from ${url}"
    fetch "$url" "${tmp}/${tarball}"

    log "Installing Rust to ${RUST_ROOT}"
    rm -rf "${RUST_ROOT}"
    mkdir -p "${RUST_ROOT}"
    # --strip-components=1 drops the rust-<ver>-<triple>/ wrapper so we get
    # /opt/rust/{rustc,cargo,rust-std-*}/ directly.
    tar -C "${RUST_ROOT}" --strip-components=1 -xJf "${tmp}/${tarball}"
    rm -rf "$tmp"

    # rust-std 与 rustc 是分开的组件树；rustc 只认自己 sysroot 下的
    # lib/rustlib/<triple>/lib，不合并会报 E0463 (can't find crate for `std`)。
    local std_lib sysroot_triple
    for std_lib in "${RUST_ROOT}"/rust-std-*/lib/rustlib/${RUST_TARBALL_TRIPLE}/lib; do
        [ -d "${std_lib}" ] || continue
        sysroot_triple="${RUST_ROOT}/rustc/lib/rustlib/${RUST_TARBALL_TRIPLE}"
        mkdir -p "${sysroot_triple}"
        [ -d "${sysroot_triple}/lib" ] || cp -a "${std_lib}" "${sysroot_triple}/lib"
    done

    [ -x "${RUST_ROOT}/rustc/bin/rustc" ] || die "Rust install failed: ${RUST_ROOT}/rustc/bin/rustc not found"
    [ -x "${RUST_ROOT}/cargo/bin/cargo" ] || die "Rust install failed: ${RUST_ROOT}/cargo/bin/cargo not found"
    log "Rust installed: $(${RUST_ROOT}/rustc/bin/rustc --version)"
    log "Cargo installed: $(${RUST_ROOT}/cargo/bin/cargo --version)"
}

main() {
    local target=""
    local go_version="$GO_DEFAULT_VERSION"
    local rust_version="$RUST_DEFAULT_VERSION"
    local last_target=""
    FORCE=0

    while [ $# -gt 0 ]; do
        case "$1" in
            go|rust|all)
                target="$1"
                last_target="$1"
                ;;
            --version)
                shift
                [ $# -gt 0 ] || die "--version requires an argument"
                case "${last_target:-go}" in
                    rust) rust_version="${1#rust-}" ;;
                    *)    go_version="${1#go}" ;;
                esac
                ;;
            --force|-f)
                FORCE=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1 (try --help)"
                ;;
        esac
        shift
    done

    [ -n "$target" ] || target="all"

    case "$target" in
        go)   install_go "$go_version" ;;
        rust) install_rust "$rust_version" ;;
        all)
            install_go "$go_version"
            install_rust "$rust_version"
            ;;
    esac

    cat <<'EOF'

Done. Add the toolchains to your PATH (for example in ~/.bashrc):

  export PATH="/opt/go/bin:/opt/rust/rustc/bin:/opt/rust/cargo/bin:$PATH"
EOF
}

main "$@"
