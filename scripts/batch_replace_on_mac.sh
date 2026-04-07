#!/usr/bin/env bash

set -euo pipefail

TAP_NAME="quyleanh/tap"

LOG_DIR="$HOME/Library/Logs/homebrew-tap-replace"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/replace_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Log file: $LOG_FILE"

echo "=== Homebrew Tap Batch Replacer ==="
echo "This script will reinstall/install all formula available in $TAP_NAME"
echo "so that your machine uses your newly built bottles."
echo ""

# Ensure the tap is added and up-to-date
echo ">> Updating Homebrew and ensuring tap $TAP_NAME is available..."
brew tap "$TAP_NAME"
brew update

TAP_DIR=$(brew --repo "$TAP_NAME")

if [[ ! -d "$TAP_DIR/Formula" ]]; then
  echo "Error: Formula directory not found in the tap ($TAP_DIR/Formula)"
  exit 1
fi

# Get all available formulas in the tap
FORMULAS=$(ls -1 "$TAP_DIR/Formula" | sed 's/\.rb$//')

if [[ -z "$FORMULAS" ]]; then
  echo "No formulas found in $TAP_NAME."
  exit 0
fi

echo "Found the following formulas in $TAP_NAME:"
for f in $FORMULAS; do
  echo "  - $f"
done
echo ""

read -p "Do you want to proceed with replacing/installing these packages? (y/N) " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Operation cancelled."
  exit 0
fi

for pkg in $FORMULAS; do
  echo ""
  echo "--------------------------------------------------------"
  echo ">> Processing $pkg..."
  echo "--------------------------------------------------------"

  # Check if the package is already installed from the custom tap
  if brew list --full-name 2>/dev/null | grep -q "^${TAP_NAME}/${pkg}$"; then
    echo "[skip] $pkg is already installed from $TAP_NAME — skipping."
    continue
  fi

  # Check if package is installed from elsewhere (e.g. homebrew-core)
  if brew list "$pkg" &>/dev/null; then
    echo ">> $pkg is installed from a different source. Reinstalling from $TAP_NAME/$pkg..."
    brew reinstall "$TAP_NAME/$pkg" || echo "[-] Warning: Failed to reinstall $pkg"
  else
    echo ">> $pkg is not installed locally. Installing $TAP_NAME/$pkg..."
    brew install "$TAP_NAME/$pkg" || echo "[-] Warning: Failed to install $pkg"
  fi
done

echo ""
echo "=== Batch replacement finished! ==="
echo "You can verify the packages installed from your tap using the command:"
echo "  brew list --full-name | grep '^$TAP_NAME/'"
