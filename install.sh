#!/usr/bin/env bash
# install.sh — Set up the private Homebrew Tap on your local machine.
# Run once to configure, then use brew as normal.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/quyleanh/homebrew-tap/main/install.sh | bash
#   or: bash install.sh quyleanh

set -euo pipefail

GITHUB_USERNAME="${1:-quyleanh}"

echo ""
echo "=== Private Homebrew Tap Installer ==="
echo "Tap: ${GITHUB_USERNAME}/tap"
echo ""

TAP_NAME="${GITHUB_USERNAME}/tap"
TAP_REPO="https://github.com/${GITHUB_USERNAME}/homebrew-tap"

# Check Homebrew is installed
if ! command -v brew &>/dev/null; then
  echo "❌ Homebrew is not installed. Get it at: https://brew.sh"
  exit 1
fi

echo "✅ Homebrew found: $(brew --version | head -1)"

# Check macOS version
macos_version=$(sw_vers -productVersion)
macos_major=$(echo "$macos_version" | cut -d. -f1)

echo "✅ macOS: $macos_version"

if [ "$macos_major" -lt 12 ]; then
  echo "⚠️  Warning: macOS $macos_version has not been tested. Bottles are built for 12.0+."
fi

# Add tap
echo ""
echo "📌 Adding tap: $TAP_NAME ..."

if brew tap "$TAP_NAME" "$TAP_REPO" 2>/dev/null; then
  echo "✅ Tap added successfully!"
else
  echo "⚠️  Tap already exists or encountered an error, attempting repair..."
  brew tap --repair "$TAP_NAME" 2>/dev/null || true
fi

# Update
echo ""
echo "🔄 Updating Homebrew..."
brew update --quiet

# Automatic replacement
echo ""
echo "📦 Running batch replacement to ensure you use $TAP_NAME packages..."
TAP_DIR=$(brew --repo "$TAP_NAME")
if [ -f "$TAP_DIR/scripts/batch_replace_on_mac.sh" ]; then
  /usr/bin/env bash "$TAP_DIR/scripts/batch_replace_on_mac.sh"
else
  echo "⚠️  Could not find batch_replace_on_mac.sh in $TAP_DIR/scripts/"
fi

echo ""
echo "══════════════════════════════════════"
echo "✅ Setup complete!"
echo "══════════════════════════════════════"
echo ""
echo "Usage:"
echo ""
echo "  # Install a package from the private tap:"
echo "  brew install ${GITHUB_USERNAME}/tap/ffmpeg"
echo ""
echo "  # Or install all packages in the list:"
echo "  brew install \$(brew tap-info --json ${GITHUB_USERNAME}/tap | jq -r '.[0].formula_names[]')"
echo ""
echo "  # Update all:"
echo "  brew update && brew upgrade"
echo ""
echo "If Homebrew cannot find a package in core,"
echo "prefix with '${GITHUB_USERNAME}/tap/' to be explicit:"
echo "  brew install ${GITHUB_USERNAME}/tap/<package>"