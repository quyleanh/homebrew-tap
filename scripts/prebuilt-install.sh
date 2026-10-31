#!/usr/bin/env bash
# prebuilt-install.sh — install the tools that publish their own macOS x86_64 builds.
#
# Why this exists: on macOS 13 Intel, Homebrew no longer ships bottles and MacPorts only
# covers what it packages — but most tools publish an official darwin/amd64 binary
# themselves. Those need no package manager, no bottle farm and no compiling, and several
# update themselves afterwards (deno upgrade, rclone selfupdate, yt-dlp -U).
#
# Versions are resolved from each project's *latest* release at run time, so this doubles
# as the updater: re-run it and everything moves to the newest official build.
#
# Layout:  ~/.local/opt/<tool>/        and symlinks in ~/.local/bin/
# Nothing here touches /usr/local (Homebrew) or /opt/local (MacPorts).
#
# Usage:
#   scripts/prebuilt-install.sh            # install/update everything
#   scripts/prebuilt-install.sh --check    # resolve newest versions, download nothing
#   scripts/prebuilt-install.sh jq gh      # only these
#   scripts/prebuilt-install.sh --list     # show the manifest
#   PREBUILT_DEST=/somewhere scripts/prebuilt-install.sh
set -uo pipefail

DEST="${PREBUILT_DEST:-$HOME/.local}"
BIN="$DEST/bin"
OPT="$DEST/opt"

# name|source|asset-pattern|how
#   source: gh:<owner>/<repo> | godev | nodejs | nasm | dockerstatic | raw:<url>
#   how:    auto (by extension) | single (bare executable) | tree (archive holds bin/)
MANIFEST=$(cat <<'EOF'
jq|gh:jqlang/jq|^jq-macos-amd64$|single
fzf|gh:junegunn/fzf|fzf-.*-darwin_amd64\.tar\.gz$|auto
gh|gh:cli/cli|gh_.*_macOS_amd64\.zip$|auto
gitleaks|gh:gitleaks/gitleaks|gitleaks_.*_darwin_x64\.tar\.gz$|auto
rclone|gh:rclone/rclone|rclone-.*-osx-amd64\.zip$|auto
yt-dlp|gh:yt-dlp/yt-dlp|^yt-dlp_macos$|single
docker-compose|gh:docker/compose|docker-compose-darwin-x86_64$|single
colima|gh:abiosoft/colima|colima-Darwin-x86_64$|single
limactl|gh:lima-vm/lima|lima-.*-Darwin-x86_64\.tar\.gz$|auto
deno|gh:denoland/deno|^deno-x86_64-apple-darwin\.zip$|auto
nasm|nasm|nasm-.*-macosx\.zip$|auto
docker|dockerstatic|docker-[0-9.]+\.tgz$|auto
go|godev|darwin-amd64\.tar\.gz$|tree
node|nodejs|darwin-x64\.tar\.gz$|tree
git-filter-repo|raw:https://raw.githubusercontent.com/newren/git-filter-repo/main/git-filter-repo|git-filter-repo$|single
EOF
)

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

# Resolve the newest official darwin/amd64 asset URL for one manifest row.
resolve_url() {
  local src="$1" pat="$2"
  case "$src" in
    gh:*)
      local repo="${src#gh:}" json=""
      if command -v gh >/dev/null 2>&1; then
        json=$(gh api "repos/$repo/releases/latest" 2>/dev/null)
      fi
      [ -n "$json" ] || json=$(curl -sS --max-time 25 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
      printf '%s' "$json" | jq -r --arg p "$pat" '[.assets[] | select(.name | test($p))] | first | .browser_download_url // empty' 2>/dev/null
      ;;
    raw:*) printf '%s' "${src#raw:}" ;;
    godev)
      curl -sS --max-time 25 "https://go.dev/dl/?mode=json" 2>/dev/null |
        jq -r '[.[] | select(.stable)][0].files[] | select(.os=="darwin" and .arch=="amd64" and .kind=="archive") | "https://go.dev/dl/"+.filename' 2>/dev/null | head -1
      ;;
    nodejs)
      curl -sS --max-time 25 "https://nodejs.org/dist/latest-v26.x/SHASUMS256.txt" 2>/dev/null |
        awk '/darwin-x64\.tar\.gz$/ { print "https://nodejs.org/dist/latest-v26.x/" $2; exit }'
      ;;
    nasm)
      local v
      v=$(curl -sS --max-time 25 "https://www.nasm.us/pub/nasm/releasebuilds/" 2>/dev/null |
        grep -oE '2\.[0-9]+\.[0-9]+' | sort -uV | tail -1)
      [ -n "$v" ] && printf 'https://www.nasm.us/pub/nasm/releasebuilds/%s/macosx/nasm-%s-macosx.zip' "$v" "$v"
      ;;
    dockerstatic)
      local v
      v=$(curl -sS --max-time 25 "https://download.docker.com/mac/static/stable/x86_64/" 2>/dev/null |
        grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | sort -uV | tail -1)
      [ -n "$v" ] && printf 'https://download.docker.com/mac/static/stable/x86_64/%s' "$v"
      ;;
  esac
}

install_one() {
  local name="$1" url="$2" how="$3"
  local tmp rc=0 found
  tmp="$(mktemp -d)"
  if ! curl -fsSL --retry 3 --max-time 900 -o "$tmp/artifact" "$url"; then
    echo "    ✗ download failed: $url"; rm -rf "$tmp"; return 1
  fi
  mkdir -p "$OPT/$name"
  case "$how" in
    single)
      install -m 755 "$tmp/artifact" "$OPT/$name/$name" || rc=1
      [ "$rc" -eq 0 ] || { rm -rf "$tmp"; return 1; }
      ln -sfn "$OPT/$name/$name" "$BIN/$name"
      ;;
    tree)
      mkdir -p "$tmp/x"
      case "$url" in
        *.tar.gz|*.tgz) tar xzf "$tmp/artifact" -C "$tmp/x" || rc=1 ;;
        *.tar.xz) tar xJf "$tmp/artifact" -C "$tmp/x" || rc=1 ;;
        *) echo "    ✗ unknown archive: $url"; rc=1 ;;
      esac
      [ "$rc" -eq 0 ] || { echo "    ✗ extract failed"; rm -rf "$tmp"; return 1; }
      local binroot
      binroot=$(find "$tmp/x" -maxdepth 2 -type d -name bin 2>/dev/null | head -1)
      [ -n "$binroot" ] || { echo "    ✗ no bin/ in archive"; rm -rf "$tmp"; return 1; }
      rm -rf "$OPT/$name"; mv "$(dirname "$binroot")" "$OPT/$name"
      for b in "$OPT/$name"/bin/*; do [ -x "$b" ] && ln -sfn "$b" "$BIN/$(basename "$b")"; done
      rm -rf "$tmp"
      echo "    ✓ $name → $(ls "$OPT/$name/bin" | tr '\n' ' ')($("$OPT/$name/bin/$name" --version 2>/dev/null | head -1 || echo ''))"
      return 0
      ;;
    *)
      mkdir -p "$tmp/x"
      case "$url" in
        *.zip) unzip -q "$tmp/artifact" -d "$tmp/x" || rc=1 ;;
        *.tar.gz|*.tgz) tar xzf "$tmp/artifact" -C "$tmp/x" || rc=1 ;;
        *.tar.xz) tar xJf "$tmp/artifact" -C "$tmp/x" || rc=1 ;;
        *) echo "    ✗ unknown archive: $url"; rc=1 ;;
      esac
      [ "$rc" -eq 0 ] || { echo "    ✗ extract failed"; rm -rf "$tmp"; return 1; }
      found=$(find "$tmp/x" -type f -name "$name" -perm -u+x 2>/dev/null | head -1)
      [ -n "$found" ] || found=$(find "$tmp/x" -type f -name "$name" 2>/dev/null | head -1)
      [ -n "$found" ] || { echo "    ✗ $name not found in $url"; rm -rf "$tmp"; return 1; }
      install -m 755 "$found" "$OPT/$name/$name" || rc=1
      [ "$rc" -eq 0 ] || { rm -rf "$tmp"; return 1; }
      ln -sfn "$OPT/$name/$name" "$BIN/$name"
      ;;
  esac
  rm -rf "$tmp"
  echo "    ✓ $name → $("$BIN/$name" --version 2>&1 | head -1)"
}

main() {
  local mode="install" only=()
  case "${1:-}" in
    --help|-h) usage; return 0 ;;
    --list) printf '%s\n' "$MANIFEST" | cut -d'|' -f1,2,3 | column -t -s'|'; return 0 ;;
    --check) mode="check"; shift ;;
    *) while [ $# -gt 0 ]; do only+=("$1"); shift; done ;;
  esac

  mkdir -p "$BIN" "$OPT"
  local failures=0 processed=0
  while IFS='|' read -r name src pat how; do
    [ -n "${name:-}" ] || continue
    if [ "${#only[@]}" -gt 0 ]; then
      local hit=0
      for w in "${only[@]}"; do [ "$w" = "$name" ] && hit=1; done
      [ "$hit" = "1" ] || continue
    fi
    printf '  %-16s ' "$name"
    local url
    url=$(resolve_url "$src" "$pat")
    if [ -z "$url" ]; then
      echo "✗ no release asset matches $pat"; failures=$((failures + 1)); continue
    fi
    if [ "$mode" = "check" ]; then
      echo "$url"; processed=$((processed + 1)); continue
    fi
    install_one "$name" "$url" "$how" || failures=$((failures + 1))
    processed=$((processed + 1))
  done <<<"$MANIFEST"

  echo ""
  if [ "$mode" = "check" ]; then
    echo "resolved: $processed  unresolved: $failures"
  else
    echo "processed: $processed  failed: $failures"
    echo "PATH note: $BIN must come before /opt/local/bin and /usr/local/bin"
  fi
  [ "$failures" -eq 0 ]
}

main "$@"
