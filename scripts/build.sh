#!/usr/bin/env bash
# build.sh — Build Homebrew bottles, skipping packages that are already up to date.
# Runs on GitHub Actions macos-15-intel runner (Sequoia, Intel x86_64).
# Target: MacBook Pro 2017 running macOS Ventura (13).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_FILE="$REPO_ROOT/packages.txt"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/bottles}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
FORCE_BUILD="${FORCE_BUILD:-false}"

export HOMEBREW_NO_AUTO_UPDATE="1"
export HOMEBREW_NO_INSTALL_CLEANUP="1"

mkdir -p "$OUTPUT_DIR"

echo "=== Homebrew Bottle Builder ==="
echo "Output dir  : $OUTPUT_DIR"
echo "Force build : $FORCE_BUILD"
echo ""

# ──────────────────────────────────────────────────────────────
# Version cache — stored as temp files instead of associative
# arrays to maintain bash 3.2 compatibility on macOS.
# Each file is named after the package and contains its version.
# ──────────────────────────────────────────────────────────────
VERSIONS_CACHE_DIR="$(mktemp -d)"

fetch_released_versions() {
  if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "⚠️  GITHUB_REPOSITORY not set — will build all packages"
    return
  fi

  echo "🔍 Fetching released asset list from GitHub..."

  local api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/stable"
  local response
  response=$(curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    "$api_url" 2>/dev/null) || {
    echo "⚠️  Could not fetch release info (no release yet or network error) — will build all"
    return
  }

  # Parse bottle filenames and cache the version per package.
  # Bottle filename format: ffmpeg--7.1.sequoia.bottle.tar.gz
  while IFS= read -r asset_name; do
    if [[ "$asset_name" =~ ^([a-zA-Z0-9_@.-]+)--([^.]+)\. ]]; then
      local pkg="${BASH_REMATCH[1]}"
      local ver="${BASH_REMATCH[2]}"
      echo "$ver" > "$VERSIONS_CACHE_DIR/$pkg"
      echo "  Found in release: $pkg @ $ver"
    fi
  done < <(echo "$response" | jq -r '.assets[].name // empty')

  echo ""
}

get_released_version() {
  local pkg="$1"
  local cache_file="$VERSIONS_CACHE_DIR/$pkg"
  if [ -f "$cache_file" ]; then
    cat "$cache_file"
  else
    echo ""
  fi
}

# ──────────────────────────────────────────────────────────────
# Determine whether a package needs to be built.
# Returns 0 (build needed) or 1 (skip).
# ──────────────────────────────────────────────────────────────
needs_build() {
  local pkg="$1"

  if [ "$FORCE_BUILD" = "true" ]; then
    echo "  → Force build enabled"
    return 0
  fi

  local latest_version
  latest_version=$(brew info --json=v1 "$pkg" 2>/dev/null | \
    jq -r '.[0].versions.stable // empty')

  if [ -z "$latest_version" ]; then
    echo "  → Could not determine latest version, building to be safe"
    return 0
  fi

  local released_version
  released_version=$(get_released_version "$pkg")

  echo "  → Latest  : $latest_version"
  echo "  → Released: ${released_version:-<none>}"

  if [ -z "$released_version" ]; then
    echo "  → No bottle found in release, will build"
    return 0
  fi

  if [ "$latest_version" = "$released_version" ]; then
    echo "  → Already up to date, skipping ✓"
    return 1
  fi

  echo "  → Newer version available, will build"
  return 0
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

# Read package list, ignoring comments and blank lines
mapfile -t PACKAGES < <(grep -v '^\s*#' "$PACKAGES_FILE" | grep -v '^\s*$')

echo "Packages in list: ${PACKAGES[*]}"
echo ""

echo "🔄 Updating Homebrew..."
brew update --quiet
echo ""

fetch_released_versions

BUILT=()
SKIPPED=()
FAILED=()

for pkg in "${PACKAGES[@]}"; do
  echo "──────────────────────────────────────"
  echo "📦 $pkg"
  echo "──────────────────────────────────────"

  if ! needs_build "$pkg"; then
    SKIPPED+=("$pkg")
    echo ""
    continue
  fi

  # Uninstall first for a clean build
  brew uninstall --ignore-dependencies "$pkg" 2>/dev/null || true

  if brew install --build-bottle "$pkg"; then
    echo "  ✅ Install OK, creating bottle..."

    # Resolve the actual installed version directory from Cellar.
    # brew info returns the base version (e.g. 20190702) but the Cellar
    # directory may include a revision suffix (e.g. 20190702_1), so we
    # read the real path directly instead of constructing it from the version.
    pkg_cellar="$(brew --cellar)/$pkg"
    cellar_path=$(ls -dt "$pkg_cellar"/*/  2>/dev/null | head -1 | sed 's|/$||')
    pkg_version=$(basename "$cellar_path")

    if [ ! -d "$cellar_path" ]; then
      echo "  ⚠️  Cellar path not found: $cellar_path"
      FAILED+=("$pkg")
      continue
    fi

    # Create bottle tar.gz directly from the Cellar directory.
    # brew bottle no longer produces a tar.gz — we create it manually.
    # Filename format: <pkg>--<version>.sequoia.bottle.tar.gz
    bottle_name="${pkg}--${pkg_version}.sequoia.bottle.tar.gz"
    bottle_path="$OUTPUT_DIR/$bottle_name"

    echo "  📦 Packing: $bottle_name"
    tar -czf "$bottle_path" \
      -C "$(brew --cellar)" \
      "$pkg/$pkg_version"

    # Generate JSON metadata (used by update_formula.sh)
    brew bottle \
      --json \
      --root-url "https://github.com/${GITHUB_REPOSITORY}/releases/download/stable" \
      "$pkg" 2>/dev/null || true

    find . -maxdepth 1 -name "*.bottle.json" -exec mv {} "$OUTPUT_DIR/" \;

    echo "  ✅ Done: $pkg @ $pkg_version ($(du -h "$bottle_path" | cut -f1))"
    BUILT+=("$pkg")
  else
    echo "  ❌ Install failed: $pkg"
    FAILED+=("$pkg")
  fi

  echo ""
done

# Clean up temp cache
rm -rf "$VERSIONS_CACHE_DIR"

# ──────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────
echo "══════════════════════════════════════"
echo "Build Summary"
echo "══════════════════════════════════════"
echo "✅ Built   (${#BUILT[@]}): ${BUILT[*]:-none}"
echo "⏭️  Skipped (${#SKIPPED[@]}): ${SKIPPED[*]:-none}"
echo "❌ Failed  (${#FAILED[@]}): ${FAILED[*]:-none}"
echo ""

if [ ${#BUILT[@]} -eq 0 ] && [ ${#FAILED[@]} -eq 0 ]; then
  echo "Nothing new to build — all packages are up to date."
fi

ls -lh "$OUTPUT_DIR/" 2>/dev/null || true

echo "BUILT_COUNT=${#BUILT[@]}"   >> "${GITHUB_OUTPUT:-/dev/null}"
echo "FAILED_COUNT=${#FAILED[@]}" >> "${GITHUB_OUTPUT:-/dev/null}"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "⚠️  Some packages failed to build. Check logs above."
  exit 1
fi