#!/usr/bin/env bash
# build.sh — Build Homebrew bottles cho tất cả packages trong packages.txt
# Chạy trên GitHub Actions macos-13 runner (Ventura, Intel x86_64)
# Binary được build với MACOSX_DEPLOYMENT_TARGET=12.0 để tương thích Monterey+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_FILE="$REPO_ROOT/packages.txt"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/bottles}"

# macOS deployment target — tương thích từ Monterey (12.0) trở lên
export MACOSX_DEPLOYMENT_TARGET="12.0"
export HOMEBREW_MACOS_VERSION_FORMULA_TARGET="12"

mkdir -p "$OUTPUT_DIR"

echo "=== Homebrew Bottle Builder ==="
echo "Deployment target: $MACOSX_DEPLOYMENT_TARGET"
echo "Output dir: $OUTPUT_DIR"
echo ""

# Đọc danh sách packages, bỏ qua comment và dòng trống
mapfile -t PACKAGES < <(grep -v '^\s*#' "$PACKAGES_FILE" | grep -v '^\s*$' | xargs)

echo "Packages to build: ${PACKAGES[*]}"
echo ""

# Cập nhật Homebrew trước
brew update --quiet

BUILT=()
FAILED=()

for pkg in "${PACKAGES[@]}"; do
  echo "──────────────────────────────────────"
  echo "📦 Building: $pkg"
  echo "──────────────────────────────────────"

  # Uninstall trước nếu đã cài (để build sạch)
  brew uninstall --ignore-dependencies "$pkg" 2>/dev/null || true

  # Build bottle
  # --build-bottle: build với relocatable paths
  # --force: overwrite nếu đã tồn tại
  if brew install --build-bottle "$pkg"; then
    echo "✅ Install OK, bottling..."

    # Tạo bottle file
    if brew bottle --json --root-url "https://github.com/${GITHUB_REPOSITORY}/releases/download/stable" "$pkg"; then
      # Di chuyển bottle vào output dir
      find . -maxdepth 1 -name "*.bottle.tar.gz" -exec mv {} "$OUTPUT_DIR/" \;
      find . -maxdepth 1 -name "*.bottle.json" -exec mv {} "$OUTPUT_DIR/" \;
      echo "✅ Bottled: $pkg"
      BUILT+=("$pkg")
    else
      echo "⚠️  Bottle failed for $pkg (will skip)"
      FAILED+=("$pkg")
    fi
  else
    echo "❌ Install failed for $pkg"
    FAILED+=("$pkg")
  fi

  echo ""
done

echo "══════════════════════════════════════"
echo "Build Summary"
echo "══════════════════════════════════════"
echo "✅ Built:  ${#BUILT[@]} packages: ${BUILT[*]:-none}"
echo "❌ Failed: ${#FAILED[@]} packages: ${FAILED[*]:-none}"
echo ""
echo "Bottles saved to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR/" 2>/dev/null || true

# Exit với lỗi nếu có package quan trọng bị fail
if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "⚠️  Some packages failed to build. Check logs above."
  exit 1
fi
