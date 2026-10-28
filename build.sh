#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

trap 'code=$?; echo "error: build failed at line ${LINENO} (exit ${code})" >&2' ERR

usage() {
	cat <<'EOF'
Usage: ./build.sh [options]

Build the current git checkout of Impactor.

Options:
  --release            Build release profile (default)
  --debug              Build debug/dev profile
  --profile <name>     Build a specific Cargo profile
  --bundle             Build macOS Impactor.app bundle (default on macOS)
  --no-bundle          Build binaries only
  --pull               Run "git pull --ff-only" before building
  --clean              Run "make clean" before building
  --skip-codesign      Skip ad-hoc codesigning of the macOS app bundle
  -h, --help           Show this help

Environment:
  PROFILE=release|debug|<cargo-profile>
  BUNDLE=1|0           macOS app bundle toggle
  CODESIGN=1|0         macOS ad-hoc codesign toggle
  APPIMAGE=1           Linux Makefile packaging toggle
  FLATPAK=1            Linux Makefile packaging toggle
  NSIS=1               Windows Makefile installer toggle

By default this builds the current local git state. Use --pull only when you
want to update the current branch before compiling.
EOF
}

log() {
	printf '\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
	printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2
}

note() {
	printf '\033[1;36mnote:\033[0m %s\n' "$*" >&2
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

setup_cargo() {
	local cargo_home="${CARGO_HOME:-}"
	if [[ -z "$cargo_home" ]]; then
		[[ -n "${HOME:-}" ]] || die "HOME or CARGO_HOME is required to install Rust"
		cargo_home="${HOME}/.cargo"
	fi

	if ! command -v cargo >/dev/null 2>&1 && [[ -x "${cargo_home}/bin/cargo" ]]; then
		export PATH="${cargo_home}/bin:${PATH:-}"
	fi

	if ! command -v cargo >/dev/null 2>&1; then
		log "Cargo not found; installing the stable Rust toolchain"
		if command -v curl >/dev/null 2>&1; then
			curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
		elif command -v wget >/dev/null 2>&1; then
			wget -qO- https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
		else
			die "curl or wget is required to install Rust"
		fi
		export PATH="${cargo_home}/bin:${PATH:-}"
	fi

	command -v cargo >/dev/null 2>&1 || die "Rust installation completed but cargo was not found in ${cargo_home}/bin"
}

repo_root() {
	if git rev-parse --show-toplevel >/dev/null 2>&1; then
		git rev-parse --show-toplevel
	else
		CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
	fi
}

workspace_version() {
	awk '
		/^\[workspace\.package\]$/ { in_pkg = 1; next }
		/^\[/ { in_pkg = 0 }
		in_pkg && $1 == "version" {
			gsub(/"/, "", $3)
			print $3
			exit
		}
	' Cargo.toml
}

target_dir_for_profile() {
	case "$1" in
		release)
			printf 'release\n'
			;;
		debug | dev)
			printf 'debug\n'
			;;
		*)
			printf '%s\n' "$1"
			;;
	esac
}

cargo_build_profile() {
	local profile="$1"
	local -a args
	args=(build --bins --workspace)

	case "$profile" in
		release)
			args+=(--release)
			;;
		debug | dev)
			;;
		*)
			args+=(--profile "$profile")
			;;
	esac

	cargo "${args[@]}"
}

print_git_state() {
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		warn "not inside a git work tree"
		return
	fi

	local branch commit
	branch="$(git branch --show-current 2>/dev/null || true)"
	commit="$(git rev-parse --short HEAD 2>/dev/null || true)"
	[[ -n "$branch" ]] || branch="detached"
	[[ -n "$commit" ]] || commit="unknown"
	log "Git: ${branch}@${commit}"

	if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
		note "working tree has local changes; building current local state"
	fi
}

set_macos_build_version() {
	local arch="$1"
	local binary="$2"

	if ! command -v vtool >/dev/null 2>&1; then
		warn "vtool not found; skipping Mach-O build-version update"
		return
	fi

	local tmp="${binary}.vtool.$$"
	rm -f "$tmp"
	if vtool -arch "$arch" -set-build-version 1 10.12 26.0 -output "$tmp" "$binary" >/dev/null; then
		mv "$tmp" "$binary"
	else
		rm -f "$tmp"
		warn "vtool build-version update skipped for ${binary}"
	fi
}

package_macos_app() {
	local arch="$1"
	local suffix="$2"
	local bin="dist/plumeimpactor-${suffix}"
	local app="dist/Impactor.app"
	local template="package/macos/Impactor.app"

	[[ -x "$bin" ]] || die "missing built binary: ${bin}"
	[[ -d "$template" ]] || die "missing app template: ${template}"

	log "Packaging ${app} (${arch})"
	rm -rf "$app"
	cp -R "$template" "$app"
	mkdir -p "$app/Contents/MacOS"

	set_macos_build_version "$arch" "$bin"

	cp "$bin" "$app/Contents/MacOS/Impactor"
	chmod +x "$app/Contents/MacOS/Impactor"

	# Ship the CLI binaries inside the bundle as well.
	local cli cli_bin
	for cli in plumeimpactor plumesign; do
		cli_bin="dist/${cli}-${suffix}"
		[[ -x "$cli_bin" ]] || die "missing built binary: ${cli_bin}"
		set_macos_build_version "$arch" "$cli_bin"
		cp "$cli_bin" "$app/Contents/MacOS/${cli}"
		chmod +x "$app/Contents/MacOS/${cli}"
	done

	if [[ "$PROFILE" == "release" ]] && command -v strip >/dev/null 2>&1; then
		strip "$app/Contents/MacOS/Impactor" || warn "strip failed; keeping unstripped app binary"
	fi

	local version
	version="$(workspace_version)"
	if [[ -z "$version" ]]; then
		version="$(git describe --tags --always 2>/dev/null || printf '0.0.0')"
	fi

	if [[ -x /usr/libexec/PlistBuddy ]]; then
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "$app/Contents/Info.plist" || warn "failed to set CFBundleShortVersionString"
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version}" "$app/Contents/Info.plist" || warn "failed to set CFBundleVersion"
	else
		warn "PlistBuddy not found; app version was not updated"
	fi

	if [[ "$CODESIGN" == "1" ]]; then
		if command -v codesign >/dev/null 2>&1; then
			codesign --force --deep --sign - "$app" >/dev/null
			codesign --verify --deep --strict "$app"
		else
			warn "codesign not found; app bundle is unsigned"
		fi
	fi
}

setup_macos_toolchain() {
	export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
	export CC="$(xcrun --sdk macosx --find clang)"
	export CXX="$(xcrun --sdk macosx --find clang++)"
	export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.13}"
}

build_macos() {
	local arch suffix target_dir
	arch="$(uname -m)"
	suffix="macos-${arch}"
	target_dir="$(target_dir_for_profile "$PROFILE")"

	log "Building macOS binaries (${PROFILE}, ${arch})"
	cargo_build_profile "$PROFILE"

	mkdir -p dist
	cp "target/${target_dir}/plumeimpactor" "dist/plumeimpactor-${suffix}"
	cp "target/${target_dir}/plumesign" "dist/plumesign-${suffix}"

	if [[ "$BUNDLE" == "1" ]]; then
		package_macos_app "$arch" "$suffix"
		rm -rf "target/${target_dir}/Impactor.app"
		cp -R dist/Impactor.app "target/${target_dir}/Impactor.app"
	fi
}

build_linux() {
	need_cmd make
	log "Building Linux binaries (${PROFILE})"
	make linux "PROFILE=${PROFILE}" "APPIMAGE=${APPIMAGE:-0}" "FLATPAK=${FLATPAK:-0}"
}

build_windows() {
	need_cmd make
	log "Building Windows binaries (${PROFILE})"
	make windows "PROFILE=${PROFILE}" "NSIS=${NSIS:-0}"
}

print_artifacts() {
	log "Artifacts"
	local artifact
	for artifact in dist/plumeimpactor-* dist/plumesign-* dist/Impactor-*; do
		[[ -e "$artifact" ]] || continue
		ls -lh "$artifact"
	done

	if [[ -d dist/Impactor.app ]]; then
		du -sh dist/Impactor.app
		if command -v codesign >/dev/null 2>&1; then
			codesign --verify --deep --strict dist/Impactor.app && printf 'codesign: ok\n'
		fi
	fi
}

PROFILE="${PROFILE:-release}"
BUNDLE="${BUNDLE:-1}"
CODESIGN="${CODESIGN:-1}"
DO_PULL=0
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--release)
			PROFILE="release"
			;;
		--debug)
			PROFILE="debug"
			;;
		--profile)
			shift
			[[ $# -gt 0 ]] || die "--profile requires a value"
			PROFILE="$1"
			;;
		--profile=*)
			PROFILE="${1#*=}"
			;;
		--bundle)
			BUNDLE=1
			;;
		--no-bundle)
			BUNDLE=0
			;;
		--pull)
			DO_PULL=1
			;;
		--clean)
			DO_CLEAN=1
			;;
		--skip-codesign)
			CODESIGN=0
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
	shift
done

need_cmd git
setup_cargo

ROOT="$(repo_root)"
cd "$ROOT"

[[ -f Cargo.toml ]] || die "Cargo.toml not found in ${ROOT}"

log "Repository: ${ROOT}"
print_git_state

if [[ "$DO_PULL" == "1" ]]; then
	log "Updating current branch"
	git pull --ff-only
	print_git_state
fi

if [[ "$DO_CLEAN" == "1" ]]; then
	need_cmd make
	log "Cleaning previous build outputs"
	make clean
fi

case "$(uname -s)" in
	Darwin)
		setup_macos_toolchain
		build_macos
		;;
	Linux)
		build_linux
		;;
	MINGW* | MSYS* | CYGWIN*)
		build_windows
		;;
	*)
		die "unsupported OS: $(uname -s)"
		;;
esac

print_artifacts
log "Build complete"
