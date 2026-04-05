#!/usr/bin/env bash

set -euo pipefail

TAP_NAME="quyleanh/tap"

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

  # Check if package is already installed
  if brew list "$pkg" &>/dev/null; then
    echo ">> $pkg is currently installed. Forcing reinstall from $TAP_NAME/$pkg..."
    # Reinstall explicitely points to your tap's formula
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
