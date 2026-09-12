#!/usr/bin/env bash
#
# mac_builder.sh — this machine is the standing builder for the llvm family.
#
# CI cannot host an llvm build: the runner ceiling is 6h and llvm measured ~5h50m
# just to *reach* the publish step, so it loses. Everything else CI handles fine.
# So the split is: CI builds what fits, this machine builds the llvm family, then
# dispatches a CI run so everything downstream can pour and build.
#
# The steps here are exactly the pipeline's publish path, run locally:
#   build from source (upstream formula, not the tap's pour-wrapper) -> brew bottle
#   -> update_formula.sh -> gh release upload -> commit -> push -> dispatch CI.
# It has to be the *upstream* formula: the tap's own llvm.rb is a pour-wrapper whose
# url is the already-published tarball, so building through it would just re-download.
#
# Install (once):
#   cp scripts/com.quyleanh.homebrew-tap.mac-builder.plist ~/Library/LaunchAgents/
#   launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.quyleanh.homebrew-tap.mac-builder.plist
# Run by hand:
#   scripts/mac_builder.sh            # build anything whose upstream moved ahead
#   scripts/mac_builder.sh --check    # say what it would do, build nothing
#   scripts/mac_builder.sh llvm       # force this package
set -uo pipefail
export TZ=Asia/Tokyo
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
# A mid-run auto-update once broke Homebrew's vendored json gem on this machine; the
# shim at vendor/portable-ruby/current/include/ruby-4.0.0/stdckdint.h fixes it, but a
# re-pour of portable-ruby would take the shim away, so auto-update stays off here.
export HOMEBREW_NO_AUTO_UPDATE=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP="quyleanh/homebrew-tap"
ROOT_URL="https://github.com/${TAP}/releases/download/stable"
PACKAGES=(llvm llvm@22)
LOG="${MAC_BUILDER_LOG:-$HOME/Library/Logs/homebrew-tap-mac-builder.log}"
LOCK="${MAC_BUILDER_LOCK:-$HOME/Library/Logs/homebrew-tap-mac-builder.lock}"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" | tee -a "$LOG"; }

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
[ $# -gt 0 ] && PACKAGES=("$@")

# One at a time — a build here runs for hours and two of them would thrash.
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  log "another mac_builder run is alive (pid $(cat "$LOCK")) — nothing to do"; exit 0
fi
echo $$ > "$LOCK"; trap 'rm -f "$LOCK"' EXIT

# A nine-hour build on battery is a dead machine. launchd runs missed calendar jobs
# on the next wake, so skipping here costs nothing.
if [ "$CHECK_ONLY" = "0" ] && ! pmset -g batt 2>/dev/null | grep -qi "AC Power"; then
  log "not on AC power — skipping; will run at next wake"; exit 0
fi

# Cheap guards first: both are required for the publish half and neither is
# guaranteed under launchd's environment.
# Exercise json specifically: `brew --version` answers fine even when the vendored
# json gem is dead, and a dead gem makes the version check below return empty — which
# would skip every package in silence. If this fires, the stdckdint shim under
# vendor/portable-ruby is gone (a portable-ruby re-pour takes it with it).
brew info --json=v2 hello 2>/dev/null | jq -e . >/dev/null 2>&1 \
  || { log "✗ brew info --json is broken (vendored-ruby json / stdckdint shim) — aborting"; exit 1; }
gh auth token >/dev/null 2>&1  || { log "✗ gh not authenticated — aborting"; exit 1; }

cd "$REPO" || { log "✗ repo missing"; exit 1; }
git pull --rebase -q origin main >>"$LOG" 2>&1 || log "⚠️ pull --rebase failed, continuing on local state"

# "Needs a build" = upstream moved ahead of what the tap's formula pins. That is the
# same test CI applies; the tap's formula only advances at publish time.
todo=()
for pkg in "${PACKAGES[@]}"; do
  upstream=$(brew info --json=v2 "homebrew/core/$pkg" 2>/dev/null | jq -r '.formulae[0].versions.stable // empty')
  pinned=$(grep -m1 -E '^\s*version ' "Formula/${pkg}.rb" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
  [ -z "$upstream" ] && { log "⚠️ cannot read upstream version for $pkg — skipping"; continue; }
  if [ "$upstream" = "$pinned" ]; then
    log "✓ $pkg: up to date (${pinned:-none} == upstream)"
  else
    log "🔨 $pkg: tap pins ${pinned:-none}, upstream has $upstream → needs a local build"
    todo+=("$pkg:$upstream")
  fi
done

if [ "${#todo[@]}" -eq 0 ]; then log "nothing to build"; exit 0; fi
[ "$CHECK_ONLY" = "1" ] && { log "(check only) would build: ${todo[*]}"; exit 0; }

export GITHUB_REPOSITORY="$TAP"
export GH_TOKEN="$(gh auth token)"

published=0
for entry in "${todo[@]}"; do
  pkg="${entry%%:*}"; version="${entry##*:}"
  slug="${pkg/@/-}"                      # bottle asset names use a dash: llvm-22-22.10.0

  log "building $pkg $version (hours; caffeinated)…"
  # brew bottle re-packages the installed keg; it must be the keg we just built, which
  # is why brew install runs first even though it looks redundant.
  # shellcheck disable=SC2086
  caffeinate -is brew install --build-bottle "homebrew/core/$pkg" >>"$LOG" 2>&1
  # Check the Cellar directly: `brew list --versions` resolves to the tap's
  # pour-wrapper, not the keg we built, so it reports the wrong thing here.
  keg="$(ls -dt "/usr/local/Cellar/${pkg}/"*/ 2>/dev/null | head -1)"
  [ "$(basename "${keg%/}")" = "$version" ] || { log "✗ $pkg: keg not at $version — not publishing"; continue; }

  mkdir -p bottles && ( cd bottles && brew bottle --json --root-url "$ROOT_URL" "homebrew/core/$pkg" >>"$LOG" 2>&1 )
  tarball="bottles/${slug}-${version}.ventura.bottle.1.tar.gz"
  json="bottles/${slug}-${version}.ventura.bottle.json"
  [ -f "$tarball" ] || { log "✗ $pkg: no bottle tarball produced — leaving for manual review"; continue; }
  log "bottle ready: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"

  BOTTLES_DIR="$PWD/bottles" ./scripts/update_formula.sh "$json" >>"$LOG" 2>&1 || log "⚠️ update_formula.sh exited non-zero"
  if grep -q "HOMEBREW_LIBRARY" "Formula/${pkg}.rb"; then
    log "formula placeholder pass guard passed ✓"
  else
    log "❌ Formula/${pkg}.rb lacks the placeholder pass — NOT publishing; manual review"
    continue
  fi

  git add "Formula/${pkg}.rb" && git commit -q -m "chore(bottles): update ${pkg} (${version}) [skip ci]" >>"$LOG" 2>&1 && log "formula committed"
  gh release upload stable "$tarball" "$json" --repo "$TAP" --clobber >>"$LOG" 2>&1 \
    && log "✅ uploaded ($(basename "$tarball") + json)" || log "⚠️ upload failed — formula not pushed"
  git pull --rebase -q origin main >>"$LOG" 2>&1
  git push -q origin main >>"$LOG" 2>&1 && log "✅ pushed" || log "⚠️ push failed"
  published=1
done

# The whole point of doing the long builds here: CI can finish the chain the moment the
# bottle exists instead of waking up weekly to defer it. Formula/** pushes deliberately
# do not trigger CI, so say so explicitly.
if [ "$published" = "1" ]; then
  log "dispatching CI so dependents can build…"
  gh workflow run build.yml --repo "$TAP" >>"$LOG" 2>&1 && log "✅ dispatched" || log "⚠️ dispatch failed"
fi

log "done"
