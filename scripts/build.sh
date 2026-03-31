#!/usr/bin/env bash
# build.sh — Tự động build toàn bộ Dependency Tree để đạt mục tiêu Zero Local Build.
# Chạy trên GitHub Actions macos-15-intel (Sequoia).
# Đích đến: MacBook Pro 2017 (macOS 13 Ventura).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_FILE="$REPO_ROOT/packages.txt"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/bottles}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
FORCE_BUILD="${FORCE_BUILD:-false}"

# Tag của runner hiện tại (Sequoia)
# LƯU Ý: Nếu muốn máy Mac 13 nhận diện được, ta cần xử lý phần này kỹ ở script update_formula.
OS_TAG="sequoia" 

export HOMEBREW_NO_AUTO_UPDATE="1"
export HOMEBREW_NO_INSTALL_CLEANUP="1"

mkdir -p "$OUTPUT_DIR"

echo "=== Homebrew Full-Stack Bottle Builder ==="
echo "Target OS Tag: $OS_TAG"
echo "Output dir   : $OUTPUT_DIR"
echo ""

# --- [Phần Cache Version giữ nguyên như cũ của bạn] ---
VERSIONS_CACHE_DIR="$(mktemp -d)"
fetch_released_versions() {
  if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "⚠️  GITHUB_REPOSITORY not set — will build all"
    return
  fi
  echo "🔍 Fetching released asset list..."
  local api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/stable"
  local response
  response=$(curl -sf -H "Authorization: Bearer ${GITHUB_TOKEN:-}" "$api_url" 2>/dev/null) || return

  while IFS= read -r asset_name; do
    if [[ "$asset_name" =~ ^([a-zA-Z0-9_@.-]+)--([^.]+)\. ]]; then
      echo "${BASH_REMATCH[2]}" > "$VERSIONS_CACHE_DIR/${BASH_REMATCH[1]}"
    fi
  done < <(echo "$response" | jq -r '.assets[].name // empty')
}

get_released_version() {
  [ -f "$VERSIONS_CACHE_DIR/$1" ] && cat "$VERSIONS_CACHE_DIR/$1" || echo ""
}

needs_build() {
  local pkg="$1"
  [ "$FORCE_BUILD" = "true" ] && return 0
  local latest_version
  latest_version=$(brew info --json=v1 "$pkg" 2>/dev/null | jq -r '.[0].versions.stable // empty')
  [ -z "$latest_version" ] && return 0
  local released_version=$(get_released_version "$pkg")
  [ "$latest_version" = "$released_version" ] && return 1
  return 0
}

# ──────────────────────────────────────────────────────────────
# 1. PHÂN TÍCH DEPENDENCY (CẢI TIẾN QUAN TRỌNG)
# ──────────────────────────────────────────────────────────────

# Đọc danh sách gói gốc (Leaves)
mapfile -t LEAVES < <(grep -v '^\s*#' "$PACKAGES_FILE" | grep -v '^\s*$')

echo "🔍 Đang phân tích toàn bộ cây phụ thuộc cho: ${LEAVES[*]}"

# Lấy toàn bộ deps theo thứ tự topological (thứ tự build chuẩn)
# --include-build: Bao gồm cả các công cụ cần để build
# --topological: Đảm bảo gói phụ thuộc liệt kê trước gói chính
ALL_DEPS=$(brew deps --include-build --topological "${LEAVES[@]}")

# Hợp nhất Leaves và Deps, loại bỏ trùng lặp nhưng giữ nguyên thứ tự
# awk này đảm bảo gói nào xuất hiện trước (dependency) sẽ được giữ lại trước
FINAL_PACKAGES=($(echo "$ALL_DEPS ${LEAVES[*]}" | tr ' ' '\n' | awk 'NF && !x[$0]++'))

echo "📦 Tổng số gói cần kiểm tra (bao gồm dependencies): ${#FINAL_PACKAGES[@]}"
echo "------------------------------------------"

# ──────────────────────────────────────────────────────────────
# 2. MAIN BUILD LOOP
# ──────────────────────────────────────────────────────────────

echo "🔄 Updating Homebrew..."
brew update --quiet
fetch_released_versions

BUILT=()
SKIPPED=()
FAILED=()

for pkg in "${FINAL_PACKAGES[@]}"; do
  echo "📦 Processing: $pkg"
  
  if ! needs_build "$pkg"; then
    echo "  ⏭️  Skipping (Already in release)"
    SKIPPED+=("$pkg")
    # Cài đặt gói đã skip để các gói sau có dependency mà dùng
    brew install "$pkg" 2>/dev/null || true
    continue
  fi

  echo "  🛠️  Building bottle..."
  # Gỡ cài đặt bản cũ nếu có để tránh xung đột build
  brew uninstall --ignore-dependencies "$pkg" 2>/dev/null || true

  # Cài đặt và build bottle
  if brew install --build-bottle "$pkg"; then
    pkg_cellar="$(brew --cellar)/$pkg"
    cellar_path=$(ls -dt "$pkg_cellar"/*/ 2>/dev/null | head -1 | sed 's|/$||')
    pkg_version=$(basename "$cellar_path")

    # Đóng gói thủ công theo định dạng của bạn
    bottle_name="${pkg}--${pkg_version}.${OS_TAG}.bottle.tar.gz"
    bottle_path="$OUTPUT_DIR/$bottle_name"

    tar -czf "$bottle_path" -C "$(brew --cellar)" "$pkg/$pkg_version"

    # Tạo JSON metadata
    brew bottle --json --root-url "https://github.com/${GITHUB_REPOSITORY}/releases/download/stable" "$pkg" 2>/dev/null || true
    find . -maxdepth 1 -name "*.bottle.json" -exec mv {} "$OUTPUT_DIR/" \;

    echo "  ✅ Success: $pkg @ $pkg_version"
    BUILT+=("$pkg")
  else
    echo "  ❌ Failed: $pkg"
    FAILED+=("$pkg")
  fi
done

# Cleanup & Summary (giữ nguyên logic của bạn)
rm -rf "$VERSIONS_CACHE_DIR"
echo "✅ Built: ${#BUILT[@]} | ⏭️  Skipped: ${#SKIPPED[@]} | ❌ Failed: ${#FAILED[@]}"
exit $(( ${#FAILED[@]} > 0 ))