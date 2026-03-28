#!/usr/bin/env bash
# install.sh — Cài đặt private Homebrew Tap trên máy
# Chạy một lần duy nhất để setup, sau đó dùng brew bình thường
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/homebrew-tap/main/install.sh | bash
#   hoặc: bash install.sh YOUR_USERNAME

set -euo pipefail

GITHUB_USERNAME="${1:-}"

# Nếu không truyền argument, hỏi
if [ -z "$GITHUB_USERNAME" ]; then
  read -rp "GitHub username của bạn: " GITHUB_USERNAME
fi

TAP_NAME="${GITHUB_USERNAME}/tap"
TAP_REPO="https://github.com/${GITHUB_USERNAME}/homebrew-tap"

echo ""
echo "=== Private Homebrew Tap Installer ==="
echo "Tap: $TAP_NAME"
echo "Repo: $TAP_REPO"
echo ""

# Kiểm tra Homebrew đã cài chưa
if ! command -v brew &>/dev/null; then
  echo "❌ Homebrew chưa được cài. Cài tại: https://brew.sh"
  exit 1
fi

echo "✅ Homebrew found: $(brew --version | head -1)"

# Kiểm tra macOS version
macos_version=$(sw_vers -productVersion)
macos_major=$(echo "$macos_version" | cut -d. -f1)

echo "✅ macOS: $macos_version"

if [ "$macos_major" -lt 12 ]; then
  echo "⚠️  Warning: macOS $macos_version chưa được test. Bottles được build cho 12.0+."
fi

# Add tap
echo ""
echo "📌 Adding tap: $TAP_NAME ..."

if brew tap "$TAP_NAME" "$TAP_REPO" 2>/dev/null; then
  echo "✅ Tap added successfully!"
else
  echo "⚠️  Tap đã tồn tại hoặc có lỗi, thử update..."
  brew tap --repair "$TAP_NAME" 2>/dev/null || true
fi

# Update
echo ""
echo "🔄 Updating Homebrew..."
brew update --quiet

echo ""
echo "══════════════════════════════════════"
echo "✅ Setup hoàn tất!"
echo "══════════════════════════════════════"
echo ""
echo "Cách dùng:"
echo ""
echo "  # Cài package từ private tap:"
echo "  brew install ${GITHUB_USERNAME}/tap/ffmpeg"
echo ""
echo "  # Hoặc cài tất cả packages trong list:"
echo "  brew install \$(brew tap-info --json ${GITHUB_USERNAME}/tap | jq -r '.[0].formula_names[]')"
echo ""
echo "  # Update tất cả:"
echo "  brew update && brew upgrade"
echo ""
echo "Nếu Homebrew không tìm thấy package trong core,"
echo "thêm prefix '${GITHUB_USERNAME}/tap/' để chỉ định rõ:"
echo "  brew install ${GITHUB_USERNAME}/tap/<package>"
