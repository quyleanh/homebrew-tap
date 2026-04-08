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

echo "=== Audit Finished ==="
