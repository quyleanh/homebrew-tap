#!/bin/bash
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "=== Final Path Audit (macOS edition) ==="

# 1. Check for nested Cellar structures (ignoring empty ones for now)
echo ">> Checking for non-empty nested Cellar directories..."
for d in $(brew --cellar)/*/*; do
    [ -d "$d" ] || continue
    ver=$(basename "$d")
    if [ -d "$d/$ver" ]; then
        if [ "$(ls -A "$d/$ver" 2>/dev/null)" ]; then
            echo "   [!] $d/$ver is NOT EMPTY"
        else
            echo "   [i] $d/$ver is empty (can be removed)"
            rmdir "$d/$ver"
        fi
    fi
done

# 2. Check for broken symlinks in /usr/local/bin
echo ">> Checking for broken symlinks in /usr/local/bin..."
find /usr/local/bin -type l | while read link; do
    if [ ! -e "$link" ]; then
        echo "   [!] Broken link: $link -> $(readlink "$link")"
    fi
done

# 3. Check for broken opt links
echo ">> Checking for broken opt links in /usr/local/opt..."
find /usr/local/opt -type l | while read link; do
    if [ ! -e "$link" ]; then
        echo "   [!] Broken link: $link -> $(readlink "$link")"
    fi
done

# 4. Verify some key programs
echo ">> Verifying key programs..."
for cmd in tmux fzf jq aria2c yt-dlp; do
    if command -v $cmd &>/dev/null; then
        echo "   [OK] $cmd is found at $(which $cmd)"
    else
        echo "   [!] $cmd NOT FOUND"
    fi
done

# 5. Check all installed tap formulas for broken dynamic library (dyld) dependencies
echo ">> Checking for broken dynamic library (dyld) dependencies..."
BREW_PREFIX=$(brew --prefix)
TAP_NAME="quyleanh/tap"

# Find formulas installed from this tap
installed_formulas=$(brew list --full-name 2>/dev/null | grep "^${TAP_NAME}/" | sed "s|^${TAP_NAME}/||")

if [ -z "$installed_formulas" ]; then
    echo "   [i] No formulas installed from ${TAP_NAME}"
else
    broken_found=0
    temp_errors=$(mktemp)
    
    for pkg in $installed_formulas; do
        pkg_prefix="${BREW_PREFIX}/opt/${pkg}"
        if [ -d "$pkg_prefix" ]; then
            # Search for binaries and libraries in standard locations
            for dir in "$pkg_prefix/bin" "$pkg_prefix/lib"; do
                [ -d "$dir" ] || continue
                find "$dir" -type f \( -perm -111 -o -name "*.dylib" -o -name "*.so" \) 2>/dev/null | while read -r binary; do
                    if file "$binary" 2>/dev/null | grep -q "Mach-O"; then
                        otool -L "$binary" 2>/dev/null | grep -E '^[[:space:]]+' | awk '{print $1}' | while read -r lib; do
                            if [[ "$lib" == "${BREW_PREFIX}/opt/"* ]]; then
                                if [ ! -e "$lib" ]; then
                                    dep_pkg=$(echo "$lib" | sed "s|^${BREW_PREFIX}/opt/||" | cut -d'/' -f1)
                                    # Skip self-references to avoid build-time versioned path false positives
                                    if [ "$pkg" != "$dep_pkg" ]; then
                                        echo "${pkg}|${binary}|${lib}|${dep_pkg}" >> "$temp_errors"
                                    fi
                                fi
                            fi
                        done
                    fi
                done
            done
        fi
    done

    if [ -s "$temp_errors" ]; then
        echo "   [!] Found missing dynamic library references:"
        TAP_DIR=$(brew --repo "$TAP_NAME" 2>/dev/null || echo "")
        while IFS='|' read -r pkg binary lib dep_pkg; do
            echo "       - Formula: $pkg"
            echo "         Binary:  $binary"
            echo "         Missing: $lib"
            if [ -n "$TAP_DIR" ] && [ -f "$TAP_DIR/Formula/${dep_pkg}.rb" ]; then
                echo "         Fix:     brew install ${TAP_NAME}/${dep_pkg} && brew unlink ${dep_pkg} && brew link ${dep_pkg}"
            else
                echo "         Fix:     brew install ${dep_pkg} && brew unlink ${dep_pkg} && brew link ${dep_pkg}"
            fi
            echo ""
        done < "$temp_errors"
        broken_found=1
    fi
    rm -f "$temp_errors"

    if [ "$broken_found" -eq 0 ]; then
        echo "   [OK] All dynamic library dependencies are resolved."
    fi
fi

echo "=== Audit Finished ==="
