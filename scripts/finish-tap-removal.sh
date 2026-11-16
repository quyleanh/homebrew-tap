#!/usr/bin/env bash
# finish-tap-removal — drop the retired quyleanh/tap from Homebrew.
#
# Run this only after the last two packages live somewhere else:
#
#   sudo /opt/local/bin/port -b install wget python314
#   sudo /opt/local/bin/port select --set python3 python314
#
# It verifies both before touching anything: if wget or python3 would stop working, it
# refuses instead of leaving you without them. Removing the kegs with
# --ignore-dependencies is safe only because nothing else is using them — the tap's
# library kegs were leftovers from the bottle farm.
set -uo pipefail

export HOMEBREW_NO_AUTO_UPDATE=1
BREW=/usr/local/bin/brew
PORT=/opt/local/bin/port

fail() { echo "✗ $*" >&2; exit 1; }

[ -x "$BREW" ] || fail "Homebrew not found at $BREW"
[ -x "$PORT" ] || fail "MacPorts not found at $PORT"
$PORT installed wget      2>/dev/null | grep -q 'wget @'       || fail "MacPorts wget not installed yet"
$PORT installed python314 2>/dev/null | grep -q 'python314 @' || fail "MacPorts python314 not installed yet"
[ -x /opt/local/bin/python3 ] || fail "python3 not selected — run: sudo $PORT select --set python3 python314"

wget_path=$(command -v wget 2>/dev/null || true)
case "$wget_path" in
  /opt/local/*) ;;
  *) fail "wget resolves to '${wget_path:-nothing}', not MacPorts — check PATH order" ;;
esac
py_path=$(command -v python3 2>/dev/null || true)
case "$py_path" in
  /opt/local/*) ;;
  *) fail "python3 resolves to '${py_path:-nothing}', not MacPorts — run port select" ;;
esac

echo "  ✓ wget    → $wget_path"
echo "  ✓ python3 → $py_path ($(python3 -V 2>&1))"
echo ""
echo "Removing the tap's kegs…"
# --force is needed because a keg with more than one installed version (xz 5.8.2 and
# 5.8.3 were both present) otherwise refuses to go.
# shellcheck disable=SC2046
$BREW uninstall --force --ignore-dependencies $($BREW list --full-name 2>/dev/null | grep '^quyleanh/tap/') || true
$BREW autoremove 2>/dev/null || true
$BREW untap quyleanh/tap 2>/dev/null || true

echo ""
echo "taps:      $($BREW tap 2>/dev/null | tr '\n' ' ')"
echo "formulae:  $($BREW list --formula 2>/dev/null | tr '\n' ' ')"
echo "casks:     $($BREW list --cask 2>/dev/null | wc -l | tr -d ' ')"
echo "cellar:    $(du -sh /usr/local/Cellar 2>/dev/null | cut -f1)"
