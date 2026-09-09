#!/usr/bin/env bash

set -euo pipefail

TAP_NAME="quyleanh/tap"

# Homebrew's relocation vocabulary: bottles can carry any of these placeholders
# (python bakes @@HOMEBREW_LIBRARY@@ into _sysconfigdata, which is what pip reads
# for PKG_CONFIG_LIBDIR), so expand all of them, not just PREFIX/CELLAR.
HP="$(brew --prefix)"
HC="$(brew --cellar)"
HL="$(brew --repository)/Library"   # no `brew --library` CLI flag; HOMEBREW_LIBRARY == <repository>/Library
HR="$(brew --repository)"
HP_PERL="$HP/opt/perl/bin/perl"
resolve_ph() {
  local s="$1"
  s="${s//@@HOMEBREW_PREFIX@@/$HP}"
  s="${s//@@HOMEBREW_CELLAR@@/$HC}"
  s="${s//@@HOMEBREW_LIBRARY@@/$HL}"
  s="${s//@@HOMEBREW_REPOSITORY@@/$HR}"
  s="${s//@@HOMEBREW_PERL@@/$HP_PERL}"
  printf '%s' "$s"
}

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
    echo "[skip] $pkg is already installed from $TAP_NAME — ensuring it is linked."
  else
    # Check if package is installed from elsewhere (e.g. homebrew-core)
    if brew list "$pkg" &>/dev/null; then
      echo ">> $pkg is installed from a different source. Reinstalling from $TAP_NAME/$pkg..."
      brew reinstall "$TAP_NAME/$pkg" || echo "[-] Warning: Failed to reinstall $pkg"
    else
      echo ">> $pkg is not installed locally. Installing $TAP_NAME/$pkg..."
      brew install "$TAP_NAME/$pkg" || echo "[-] Warning: Failed to install $pkg"
    fi
  fi

  echo ">> Linking $pkg..."
  brew unlink "$pkg" 2>/dev/null || true
  brew link --overwrite "$pkg" || echo "[-] Warning: Failed to link $pkg"

  # Relocate any unexpanded placeholders in installed binaries/dylibs/text files
  keg_dir="$(brew --cellar)/$pkg"
  if [ -d "$keg_dir" ]; then
    # 1. Mach-O binaries, dylibs, and Python .so bundles
    for f in $(find "$keg_dir" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) 2>/dev/null); do
      [ -L "$f" ] && continue
      loads=$(otool -L "$f" 2>/dev/null | grep "@@HOMEBREW" || true)
      dylib_id=$(otool -D "$f" 2>/dev/null | tail -n 1)
      rpath_match=$(otool -l "$f" 2>/dev/null | grep -A 2 "cmd LC_RPATH" | grep "@@HOMEBREW" || true)
      if [ -n "$loads" ] || [[ "$dylib_id" == *"@@HOMEBREW"* ]] || [ -n "$rpath_match" ]; then
        echo ">> Relocating Mach-O placeholders in $f..."
        chmod +w "$f" 2>/dev/null || true
        if [[ "$dylib_id" == *"@@HOMEBREW"* ]]; then
          new_id="$(resolve_ph "$dylib_id")"
          install_name_tool -id "$new_id" "$f" 2>/dev/null || true
        fi
        while read -r bad_path; do
          [ -z "$bad_path" ] && continue
          good_path="$(resolve_ph "$bad_path")"
          install_name_tool -change "$bad_path" "$good_path" "$f" 2>/dev/null || true
        done < <(otool -L "$f" 2>/dev/null | grep "@@HOMEBREW" | awk '{print $1}')
        if [ -n "$rpath_match" ]; then
          while read -r bad_rpath; do
            [ -z "$bad_rpath" ] && continue
            good_rpath="$(resolve_ph "$bad_rpath")"
            install_name_tool -rpath "$bad_rpath" "$good_rpath" "$f" 2>/dev/null || true
          done < <(otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/{flag=1; next} flag && /path /{if ($2 ~ /@@HOMEBREW/) print $2; flag=0}')
        fi
        # Re-sign with ad-hoc signature so macOS kernel won't SIGKILL it
        codesign -f -s - "$f" 2>/dev/null || true
      fi
    done

    # 2. Text files (shebangs, pc files, config scripts, python sources)
    { grep -rlIZ "@@HOMEBREW" "$keg_dir" 2>/dev/null || true; } | while IFS= read -r -d '' tf; do
      [ -L "$tf" ] && continue
      echo ">> Relocating text placeholders in $tf..."
      chmod +w "$tf" 2>/dev/null || true
      sed -i '' \
        -e "s|@@HOMEBREW_PREFIX@@|$HP|g" \
        -e "s|@@HOMEBREW_CELLAR@@|$HC|g" \
        -e "s|@@HOMEBREW_LIBRARY@@|$HL|g" \
        -e "s|@@HOMEBREW_REPOSITORY@@|$HR|g" \
        -e "s|@@HOMEBREW_PERL@@|$HP_PERL|g" \
        "$tf" 2>/dev/null || true
    done

    # 3. Bytecode caches embed the placeholder too and cannot be rewritten in
    #    place; a stale .pyc shadows the fixed source at import time, so drop it
    #    (only when the source is present) and let Python regenerate it.
    while IFS= read -r -d '' pyc; do
      [ -L "$pyc" ] && continue
      grep -q "@@HOMEBREW" "$pyc" 2>/dev/null || continue
      stem=$(basename "$pyc" | sed -E 's/(\.cpython-[^.]+)?\.pyc$//')
      if [ -f "$(dirname "$pyc")/../$stem.py" ] || [ -f "$(dirname "$pyc")/$stem.py" ]; then
        echo ">> Dropping stale bytecode cache $pyc"
        chmod +w "$pyc" 2>/dev/null || true
        rm -f "$pyc"
      fi
    done < <(find "$keg_dir" -type f -name "*.pyc" -print0 2>/dev/null)
  fi
done

echo ""
echo "=== Verifying system linkage ==="
unrelocated_found=0
for lib in $(find /usr/local/opt/*/lib -name "*.dylib" -type f 2>/dev/null); do
  if otool -L "$lib" 2>/dev/null | grep -q "@@HOMEBREW"; then
    echo "[-] Warning: Found unrelocated dylib: $lib"
    unrelocated_found=1
  fi
done

if [ "$unrelocated_found" -eq 0 ]; then
  echo "✅ All dynamic libraries are properly relocated."
else
  echo "⚠️ Some libraries still need relocation. Run a scan with install_name_tool."
fi

echo ""
echo "=== Batch replacement finished! ==="
echo "You can verify the packages installed from your tap using the command:"
echo "  brew list --full-name | grep '^$TAP_NAME/'"
