#!/bin/sh
# Dev tool: pull an AYLO engine release (Charles-Mahoudeau/rtype) into a cache dir and run the game on it.
#
# Usage: tools/engine.sh [-v <nightly|tag>] <command> [args...]
#   engine_pull   download + verify (SHA256SUMS) + extract the engine; skipped when already cached
#   path          print the path of the cached aylo-runtime (pulls first if needed)
#   run [args]    run the game in a window on the pulled engine (pulls first if needed); args go to aylo-runtime,
#                 e.g. `tools/engine.sh run --server --ticks 600`
#   test          run tools/run_engine_test.sh (M0 headless self-test) on the pulled engine
#
# Version: -v flag > $AYLO_ENGINE_VERSION > first line of tools/engine.version (if present) > "nightly".
# Cache:   $AYLO_ENGINE_CACHE, else ${XDG_CACHE_HOME:-$HOME/.cache}/hackathon-rubix/engine.
# Needs the GitHub CLI (`gh`, logged in) and unzip (or a tar that reads zip).
# `nightly` is rolling: engine_pull asks GitHub which build is current and only downloads when it is not cached.
# Offline, an already pulled build of the selected version is used as is.
set -u

repo=Charles-Mahoudeau/rtype
dir=$(cd "$(dirname "$0")/.." && pwd)
cache=${AYLO_ENGINE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/hackathon-rubix/engine}

die() { echo "engine.sh: $*" >&2; exit 1; }
log() { echo "engine.sh: $*" >&2; }

version=${AYLO_ENGINE_VERSION:-}
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  [ $# -ge 2 ] || die "$1 needs a value (nightly or a tag such as v0.1.0)"
  version=$2
  shift 2
fi
if [ -z "$version" ] && [ -f "$dir/tools/engine.version" ]; then
  version=$(sed -n '1{s/[[:space:]]*$//;p;q;}' "$dir/tools/engine.version")
fi
version=${version:-nightly}
case "$version" in *[!A-Za-z0-9._-]*|"") die "invalid engine version '$version'" ;; esac

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=macos-arm64; exe=aylo-runtime ;;
  Linux-x86_64) platform=linux-x86_64; exe=aylo-runtime ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64) platform=windows-x86_64; exe=aylo-runtime.exe ;;
  *) die "no engine build for $(uname -s) $(uname -m) (releases: macos-arm64, linux-x86_64, windows-x86_64)" ;;
esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

unpack() {
  if command -v unzip >/dev/null 2>&1; then unzip -q -o "$1" -d "$2"
  else tar -xf "$1" -C "$2"; fi
}

# Last pulled build of this version, kept in a pointer file so offline runs still work.
pointer="$cache/$version.current"

pulled_runtime() {
  [ -f "$pointer" ] || return 1
  rt="$cache/$(cat "$pointer")/runtime/$exe"
  [ -x "$rt" ] || return 1
  printf '%s\n' "$rt"
}

engine_pull() {
  command -v gh >/dev/null 2>&1 || {
    pulled_runtime >/dev/null && { log "gh not found, using the cached $version build"; return 0; }
    die "gh (GitHub CLI) is required to download the engine"
  }
  asset=$(gh release view "$version" -R "$repo" --json assets \
    --jq ".assets[].name | select(endswith(\"-$platform.zip\"))" 2>/dev/null | head -n 1)
  if [ -z "$asset" ]; then
    pulled_runtime >/dev/null && { log "cannot reach release '$version', using the cached build"; return 0; }
    die "no $platform asset found in $repo release '$version' (is 'gh auth status' ok, and does the release exist?)"
  fi
  name=${asset%.zip}
  if [ -x "$cache/$name/runtime/$exe" ]; then
    log "$name already pulled"
  else
    mkdir -p "$cache" || die "cannot create $cache"
    tmp=$(mktemp -d "$cache/.pull.XXXXXX") || die "cannot create a temp dir in $cache"
    trap 'rm -rf "$tmp"' EXIT INT TERM
    log "downloading $asset ($version)"
    gh release download "$version" -R "$repo" -D "$tmp" -p "$asset" -p SHA256SUMS --clobber \
      || die "download of $asset failed"
    if [ -f "$tmp/SHA256SUMS" ]; then
      want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS" | head -n 1)
      [ -n "$want" ] || die "SHA256SUMS has no entry for $asset"
      [ "$(sha256 "$tmp/$asset")" = "$want" ] || die "checksum mismatch for $asset"
      log "checksum ok"
    else
      log "warning: release has no SHA256SUMS, skipping verification"
    fi
    mkdir "$tmp/x" && unpack "$tmp/$asset" "$tmp/x" || die "cannot extract $asset"
    [ -d "$tmp/x/$name" ] || die "unexpected archive layout (no $name/ folder)"
    rm -rf "$cache/$name"
    mv "$tmp/x/$name" "$cache/$name" || die "cannot move the engine into $cache"
    rm -rf "$tmp"
    trap - EXIT INT TERM
    [ -x "$cache/$name/runtime/$exe" ] || chmod +x "$cache/$name/runtime/$exe" 2>/dev/null
    [ -x "$cache/$name/runtime/$exe" ] || die "$cache/$name/runtime/$exe is missing after extraction"
    log "pulled $name"
  fi
  printf '%s\n' "$name" >"$pointer"
}

ensure_runtime() {
  engine_pull || exit 1
  pulled_runtime || die "engine runtime not found after pull"
}

case "$cmd" in
  engine_pull) engine_pull || exit 1; echo "$(pulled_runtime)" ;;
  path) ensure_runtime ;;
  run) rt=$(ensure_runtime) || exit 1; exec "$rt" "$dir" "$@" ;;
  test) rt=$(ensure_runtime) || exit 1; exec "$dir/tools/run_engine_test.sh" "$rt" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; [ -z "$cmd" ] && exit 2; die "unknown command '$cmd'" ;;
esac
