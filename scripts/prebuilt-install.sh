#!/usr/bin/env bash
# prebuilt-install.sh — install the tools that publish their own macOS x86_64 builds.
#
# Why this exists: on macOS 13 Intel, Homebrew no longer ships bottles and MacPorts only
# covers what it packages — but most tools publish an official darwin/amd64 binary
# themselves. Those need no package manager, no bottle farm and no compiling, and several
# of them update themselves afterwards (deno upgrade, rclone selfupdate, yt-dlp -U).
#
# Layout:  ~/.local/opt/<tool>/<tool>   and a symlink at ~/.local/bin/<tool>
# Nothing here touches /usr/local (Homebrew) or /opt/local (MacPorts).
#
# Usage:
#   scripts/prebuilt-install.sh            # install everything missing
#   scripts/prebuilt-install.sh jq gh      # only these
#   scripts/prebuilt-install.sh --list     # show the manifest
#   PREBUILT_DEST=/somewhere scripts/prebuilt-install.sh
set -uo pipefail

DEST="${PREBUILT_DEST:-$HOME/.local}"
BIN="$DEST/bin"
OPT="$DEST/opt"

# name|url|binary-name-in-archive|how
#   how: auto (by extension) or "single" for a bare executable, or "go" for the go tarball
MANIFEST=$(cat <<'EOF'
jq|https://github.com/jqlang/jq/releases/latest/download/jq-macos-amd64|jq|single
fzf|https://github.com/junegunn/fzf/releases/latest/download/fzf-0.74.5-darwin_amd64.tar.gz|fzf|auto
gh|https://github.com/cli/cli/releases/latest/download/gh_2.103.3_macOS_amd64.zip|gh|auto
gitleaks|https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_8.30.1_darwin_x64.tar.gz|gitleaks|auto
rclone|https://github.com/rclone/rclone/releases/latest/download/rclone-v1.75.2-osx-amd64.zip|rclone|auto
yt-dlp|https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos|yt-dlp|single
git-filter-repo|https://raw.githubusercontent.com/newren/git-filter-repo/main/git-filter-repo|git-filter-repo|single
docker-compose|https://github.com/docker/compose/releases/latest/download/docker-compose-darwin-x86_64|docker-compose|single
colima|https://github.com/abiosoft/colima/releases/latest/download/colima-Darwin-x86_64|colima|single
limactl|https://github.com/lima-vm/lima/releases/latest/download/lima-2.2.1-Darwin-x86_64.tar.gz|limactl|auto
nasm|https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/macosx/nasm-2.16.03-macosx.zip|nasm|auto
deno|https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip|deno|auto
docker|https://download.docker.com/mac/static/stable/x86_64/docker-29.9.2.tgz|docker|auto
go|https://go.dev/dl/go1.27.3.darwin-amd64.tar.gz|go|tree
EOF
)

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

extract_and_install() {
  local name="$1" url="$2" want="$3" how="$4"
  local tmp rc=0
  tmp="$(mktemp -d)"
  echo "  ↓ $name"
  if ! curl -fsSL --retry 3 --max-time 900 -o "$tmp/artifact" "$url"; then
    echo "    ✗ download failed: $url"; rm -rf "$tmp"; return 1
  fi
  case "$how" in
    tree)
      # Go ships a full toolchain tree (GOROOT), not a single binary.
      mkdir -p "$tmp/x"
      if ! tar xzf "$tmp/artifact" -C "$tmp/x"; then echo "    ✗ extract failed"; rm -rf "$tmp"; return 1; fi
      rm -rf "$OPT/$name"; mv "$tmp/x/$name" "$OPT/$name"
      ln -sfn "$OPT/$name/bin/$name" "$BIN/$name"
      rm -rf "$tmp"
      echo "    ✓ $BIN/$name → $("$BIN/$name" version 2>&1 | head -1)"
      return 0 ;;
    single)
      install -m 755 "$tmp/artifact" "$OPT/$name/$name" 2>/dev/null ||
        { mkdir -p "$OPT/$name"; install -m 755 "$tmp/artifact" "$OPT/$name/$name"; } ;;
    *)
      case "$url" in
        *.zip) unzip -q "$tmp/artifact" -d "$tmp/x" || rc=1 ;;
        *.tar.gz|*.tgz) mkdir -p "$tmp/x" && tar xzf "$tmp/artifact" -C "$tmp/x" || rc=1 ;;
        *.tar.xz) mkdir -p "$tmp/x" && tar xJf "$tmp/artifact" -C "$tmp/x" || rc=1 ;;
        *) echo "    ✗ unknown archive type: $url"; rc=1 ;;
      esac
      if [ "$rc" -ne 0 ]; then echo "    ✗ extract failed"; rm -rf "$tmp"; return 1; fi
      mkdir -p "$OPT/$name"
      local found
      found=$(find "$tmp/x" -type f -name "$(basename "$want")" -perm -u+x 2>/dev/null | head -1)
      [ -n "$found" ] || found=$(find "$tmp/x" -type f -name "$(basename "$want")" 2>/dev/null | head -1)
      if [ -z "$found" ]; then
        echo "    ✗ $want not found in archive"; rm -rf "$tmp"; return 1
      fi
      install -m 755 "$found" "$OPT/$name/$name" ;;
  esac
  ln -sfn "$OPT/$name/$name" "$BIN/$name"
  rm -rf "$tmp"
  echo "    ✓ $BIN/$name → $("$BIN/$name" --version 2>&1 | head -1 || echo 'installed')"
}

main() {
  local -a wanted=()
  case "${1:-}" in
    --list) printf '%s\n' "$MANIFEST" | cut -d'|' -f1,2 | column -t -s'|'; return 0 ;;
    --help|-h) usage; return 0 ;;
    "") while IFS='|' read -r n _; do wanted+=("$n"); done <<<"$MANIFEST" ;;
    *) wanted=("$@") ;;
  esac

  mkdir -p "$BIN" "$OPT"
  local failures=0 installed=0
  while IFS='|' read -r name url want how; do
    [ -n "${name:-}" ] || continue
    if [ "${#wanted[@]}" -gt 0 ]; then
      local hit=0
      for w in "${wanted[@]}"; do [ "$w" = "$name" ] && hit=1; done
      [ "$hit" = "1" ] || continue
    fi
    extract_and_install "$name" "$url" "$want" "$how" || failures=$((failures + 1))
    installed=$((installed + 1))
  done <<<"$MANIFEST"

  echo ""
  echo "installed: $installed  failed: $failures"
  echo "PATH note: $BIN must come before /opt/local/bin and /usr/local/bin"
  [ "$failures" -eq 0 ]
}

main "$@"
