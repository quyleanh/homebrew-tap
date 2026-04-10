#!/usr/bin/env bash
# cleanup_release.sh — Remove assets from GitHub Release that are no longer referenced by any Formula
set -euo pipefail

# Check for gh CLI
if ! command -v gh &> /dev/null; then
    echo "Error: gh CLI is not installed or not in PATH."
    exit 1
fi

echo "=== Homebrew Tap Release Cleanup ==="

# 1. Collect all filenames currently referenced by formulas
# Extract the filename part of the URL from all .rb files
echo "🔍 Scanning Formula/ directory for active assets..."
mapfile -t CURRENT_FILES < <(grep -h 'url "https://github.com' Formula/*.rb 2>/dev/null | sed 's/.*\/download\/stable\///; s/"//' | sort -u)

if [ ${#CURRENT_FILES[@]} -eq 0 ]; then
    echo "⚠️  No active formula assets found in Formula/. Skipping cleanup to be safe."
    exit 0
fi

# 2. Build a list of all valid assets (including the .json metadata files)
VALID_ASSETS=()
for f in "${CURRENT_FILES[@]}"; do
    VALID_ASSETS+=("$f")
    if [[ "$f" == *.tar.gz ]]; then
        # 1. Direct replacement (matches if names match exactly, e.g. pkg--1.2.3.bottle.1.json)
        VALID_ASSETS+=("${f%.tar.gz}.json")
        
        # 2. Base JSON name (Homebrew often omits revision in JSON filename even if in tarball)
        # Converts pkg--1.2.3.sequoia.bottle.1.tar.gz -> pkg--1.2.3.sequoia.bottle.json
        base_json=$(echo "$f" | sed -E 's/\.bottle(\.[0-9]+)?\.tar\.gz$/.bottle.json/')
        if [[ "$base_json" == *.json ]]; then
            VALID_ASSETS+=("$base_json")
        fi
    fi
done

echo "   Found ${#VALID_ASSETS[@]} active assets (bottles + metadata)."

# 3. Get all assets currently in the GitHub Release
echo "🔍 Fetching current assets list from 'stable' release..."
mapfile -t REMOTE_ASSETS < <(gh release view stable --json assets --jq '.assets[].name' 2>/dev/null || echo "")

if [ ${#REMOTE_ASSETS[@]} -eq 0 ]; then
    echo "ℹ️  No assets found in the release."
    exit 0
fi

# 4. Identify and delete orphaned assets
echo "✨ Comparing local formulas vs. remote assets..."
DELETED_COUNT=0
for asset in "${REMOTE_ASSETS[@]}"; do
    # Only manage our bottle files (.tar.gz and .json)
    if [[ "$asset" != *.tar.gz && "$asset" != *.json ]]; then
        continue
    fi
    
    found=false
    for valid in "${VALID_ASSETS[@]}"; do
        if [ "$asset" == "$valid" ]; then
            found=true
            break
        fi
    done
    
    if [ "$found" = false ]; then
        echo "🗑️  Deleting orphaned asset: $asset"
        gh release delete-asset stable "$asset" -y || echo "   ⚠️  Failed to delete $asset"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
done

echo ""
echo "✅ Cleanup complete. Removed $DELETED_COUNT orphaned assets."
echo "══════════════════════════════════════"
