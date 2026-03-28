#!/usr/bin/env bash
# build.sh — Build Homebrew bottles, chỉ build những package có version mới
# Chạy trên GitHub Actions macos-15-intel runner (Sequoia, Intel x86_64)
# Target: MacBook Pro 2017 chạy macOS Ventura (13)

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
# Lấy released version của một package từ GitHub release assets
# Dùng file tạm thay vì associative array (bash 3.2 compatible)
# ──────────────────────────────────────────────────────────────
VERSIONS_CACHE_DIR="$(mktemp -d)"

fetch_released_versions() {
  if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "⚠️  GITHUB_REPOSITORY không được set — build tất cả"
    return
  fi

  echo "🔍 Fetching released asset list from GitHub..."

  local api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/stable"
  local response
  response=$(curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    "$api_url" 2>/dev/null) || {
    echo "⚠️  Không lấy được release info (chưa có release hoặc lỗi mạng) — build tất cả"
    return
  }

  # Parse filename bottle → lưu version vào file tạm theo tên package
  # Bottle filename format: ffmpeg--7.1.ventura.bottle.tar.gz
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
# Kiểm tra package có cần build không
# Returns 0 (cần build) hoặc 1 (skip)
# ──────────────────────────────────────────────────────────────
needs_build() {
  local pkg="$1"

  if [ "$FORCE_BUILD" = "true" ]; then
    echo "  → Force build mode"
    return 0
  fi

  local latest_version
  latest_version=$(brew info --json=v1 "$pkg" 2>/dev/null | \
    jq -r '.[0].versions.stable // empty')

  if [ -z "$latest_version" ]; then
    echo "  → Không lấy được version info, build để chắc"
    return 0
  fi

  local released_version
  released_version=$(get_released_version "$pkg")

  echo "  → Latest  : $latest_version"
  echo "  → Released: ${released_version:-<none>}"

  if [ -z "$released_version" ]; then
    echo "  → Chưa có bottle, sẽ build"
    return 0
  fi

  if [ "$latest_version" = "$released_version" ]; then
    echo "  → Đã có bottle mới nhất, skip ✓"
    return 1
  fi

  echo "  → Version mới hơn, sẽ build"
  return 0
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────
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

  brew uninstall --ignore-dependencies "$pkg" 2>/dev/null || true

  if brew install --build-bottle "$pkg"; then
    echo "  ✅ Install OK, bottling..."

    if brew bottle \
        --json \
        --root-url "https://github.com/${GITHUB_REPOSITORY}/releases/download/stable" \
        "$pkg"; then

      find . -maxdepth 1 -name "*.bottle.tar.gz" -exec mv {} "$OUTPUT_DIR/" \;
      find . -maxdepth 1 -name "*.bottle.json"   -exec mv {} "$OUTPUT_DIR/" \;
      echo "  ✅ Bottled: $pkg"
      BUILT+=("$pkg")
    else
      echo "  ⚠️  Bottle failed for $pkg"
      FAILED+=("$pkg")
    fi
  else
    echo "  ❌ Install failed for $pkg"
    FAILED+=("$pkg")
  fi

  echo ""
done

# Cleanup temp dir
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
  echo "⚠️  Some packages failed. Check logs above."
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# Lấy danh sách assets đang có trong release "stable" trên GitHub
# Trả về map: package_name → version đang có (hoặc rỗng nếu chưa có)
# ──────────────────────────────────────────────────────────────
declare -A RELEASED_VERSIONS

fetch_released_versions() {
  if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "⚠️  GITHUB_REPOSITORY không được set, bỏ qua version check — build tất cả"
    return
  fi

  echo "🔍 Fetching released asset list from GitHub..."

  local api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/stable"
  local response
  response=$(curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    "$api_url" 2>/dev/null) || {
    echo "⚠️  Không lấy được release info (release chưa tồn tại hoặc lỗi mạng) — build tất cả"
    return
  }

  # Parse tên các file bottle đang có
  # Homebrew bottle filename format: <pkg>--<version>.<os>.<arch>.bottle.tar.gz
  while IFS= read -r asset_name; do
    if [[ "$asset_name" =~ ^([a-zA-Z0-9_@.-]+)--([^.]+)\. ]]; then
      local pkg="${BASH_REMATCH[1]}"
      local ver="${BASH_REMATCH[2]}"
      RELEASED_VERSIONS["$pkg"]="$ver"
      echo "  Found in release: $pkg @ $ver"
    fi
  done < <(echo "$response" | jq -r '.assets[].name // empty')

  echo ""
}

# ──────────────────────────────────────────────────────────────
# Kiểm tra package có cần build không
# Returns 0 (cần build) hoặc 1 (skip)
# ──────────────────────────────────────────────────────────────
needs_build() {
  local pkg="$1"

  if [ "$FORCE_BUILD" = "true" ]; then
    echo "  → Force build mode, building anyway"
    return 0
  fi

  # Lấy version mới nhất trên Homebrew
  local latest_version
  latest_version=$(brew info --json=v1 "$pkg" 2>/dev/null | \
    jq -r '.[0].versions.stable // empty')

  if [ -z "$latest_version" ]; then
    echo "  → Không lấy được version info, build để chắc"
    return 0
  fi

  local released_version="${RELEASED_VERSIONS[$pkg]:-}"

  echo "  → Latest  : $latest_version"
  echo "  → Released: ${released_version:-<none>}"

  if [ -z "$released_version" ]; then
    echo "  → Chưa có bottle, sẽ build"
    return 0
  fi

  if [ "$latest_version" = "$released_version" ]; then
    echo "  → Đã có bottle mới nhất, skip ✓"
    return 1
  fi

  echo "  → Version mới hơn, sẽ build"
  return 0
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

# Đọc danh sách packages, bỏ qua comment và dòng trống
mapfile -t PACKAGES < <(grep -v '^\s*#' "$PACKAGES_FILE" | grep -v '^\s*$')

echo "Packages in list: ${PACKAGES[*]}"
echo ""

# Cập nhật Homebrew
echo "🔄 Updating Homebrew..."
brew update --quiet
echo ""

# Lấy version đang có trên release
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

  # Uninstall trước nếu đã cài (build sạch)
  brew uninstall --ignore-dependencies "$pkg" 2>/dev/null || true

  # Install với --build-bottle để tạo relocatable binary
  if brew install --build-bottle "$pkg"; then
    echo "  ✅ Install OK, bottling..."

    # Tạo bottle, root-url trỏ tới GitHub Release
    if brew bottle \
        --json \
        --root-url "https://github.com/${GITHUB_REPOSITORY}/releases/download/stable" \
        "$pkg"; then

      # Di chuyển bottle files vào output dir
      find . -maxdepth 1 -name "*.bottle.tar.gz" -exec mv {} "$OUTPUT_DIR/" \;
      find . -maxdepth 1 -name "*.bottle.json"   -exec mv {} "$OUTPUT_DIR/" \;
      echo "  ✅ Bottled: $pkg"
      BUILT+=("$pkg")
    else
      echo "  ⚠️  Bottle failed for $pkg"
      FAILED+=("$pkg")
    fi
  else
    echo "  ❌ Install failed for $pkg"
    FAILED+=("$pkg")
  fi

  echo ""
done

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

if [ ${#BUILT[@]} -eq 0 ]; then
  echo "Nothing new to build — all packages are up to date."
fi

ls -lh "$OUTPUT_DIR/" 2>/dev/null || true

# Ghi kết quả ra file để workflow đọc
echo "BUILT_COUNT=${#BUILT[@]}"   >> "${GITHUB_OUTPUT:-/dev/null}"
echo "FAILED_COUNT=${#FAILED[@]}" >> "${GITHUB_OUTPUT:-/dev/null}"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "⚠️  Some packages failed. Check logs above."
  exit 1
fi
