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
# Resolve formula definitions from the local homebrew/core clone instead of Homebrew's
# API copy. The API cache cannot be refreshed without updating Homebrew itself, and it
# lags: it still answered llvm 23.1.1_1 while the clone — and the CI runner — had
# 23.1.2, so this script reported "up to date" and built nothing at all. With this set,
# a plain git pull on the clone is enough to see upstream.
export HOMEBREW_NO_INSTALL_FROM_API=1

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

# Homebrew's vendored portable-ruby was built with HAVE_STDCKDINT_H=1, so
# ruby/internal/stdckdint.h does `#include <stdckdint.h>` — a C23 header this machine's
# macOS 13 SDK does not have. Without it every native gem extension fails to compile:
#
#   ruby/internal/stdckdint.h:48:11: error: 'stdckdint.h' file not found
#
# and `brew bottle` then dies inside `bundle install` (json, pulled in by rubocop),
# throwing away a twelve-hour build with "no bottle tarball/json produced". A Homebrew
# update re-pours portable-ruby and deletes this file, so put it back when it is gone.
# It only has to satisfy Ruby's own use: memory.h calls ckd_add/ckd_mul with the result
# lvalue's address, exactly like the __builtin_*_overflow form below.
PORTABLE_RUBY_SHIM="/usr/local/Homebrew/Library/Homebrew/vendor/portable-ruby/current/include/ruby-4.0.0/stdckdint.h"
ensure_portable_ruby_stdckdint_shim() {
  local dir
  dir="$(dirname "$PORTABLE_RUBY_SHIM")"
  [ -d "$dir" ] || return 0
  grep -q HOMEBREW_PORTABLE_RUBY_STDCKDINT_H "$PORTABLE_RUBY_SHIM" 2>/dev/null && return 0
  cat > "$PORTABLE_RUBY_SHIM" <<'SHIM'
/* Minimal C23 <stdckdint.h> for platforms whose SDK does not ship one.
 *
 * macOS 13's SDK (Apple clang 15) has no C23 stdckdint.h, but Homebrew's vendored
 * portable-ruby was built with HAVE_STDCKDINT_H=1, so ruby/internal/stdckdint.h
 * reaches for <stdckdint.h> unconditionally and native gem extensions fail to
 * compile. mac_builder.sh rewrites this file because a Homebrew update re-pours
 * portable-ruby and takes it away again.
 */
#ifndef HOMEBREW_PORTABLE_RUBY_STDCKDINT_H
#define HOMEBREW_PORTABLE_RUBY_STDCKDINT_H

#define __STDC_VERSION_STDCKDINT_H__ 202311L

#define ckd_add(x, y, z) ((bool)__builtin_add_overflow((y), (z), (x)))
#define ckd_sub(x, y, z) ((bool)__builtin_sub_overflow((y), (z), (x)))
#define ckd_mul(x, y, z) ((bool)__builtin_mul_overflow((y), (z), (x)))

#endif
SHIM
  log "ℹ️  restored the portable-ruby stdckdint.h shim (brew bottle needs it)"
}
ensure_portable_ruby_stdckdint_shim

# Cheap guards first: both are required for the publish half and neither is
# guaranteed under launchd's environment.
# Exercise json specifically: `brew --version` answers fine even when the vendored
# json gem is dead, and a dead gem makes the version check below return empty — which
# would skip every package in silence.
brew info --json=v2 hello 2>/dev/null | jq -e . >/dev/null 2>&1 \
  || { log "✗ brew info --json is broken (vendored-ruby json) — aborting"; exit 1; }
gh auth token >/dev/null 2>&1  || { log "✗ gh not authenticated — aborting"; exit 1; }

cd "$REPO" || { log "✗ repo missing"; exit 1; }
git pull --rebase -q origin main >>"$LOG" 2>&1 || log "⚠️ pull --rebase failed, continuing on local state"

# "Needs a build" = upstream moved ahead of what the tap's formula pins. That is the
# same test CI applies; the tap's formula only advances at publish time.
#
# The revision belongs in that test. Homebrew's pkg_version is "23.1.1_1" for a
# revision bump, and comparing versions.stable alone made this script report "up to
# date" for llvm 23.1.1_1 while CI — which does add the revision — saw the difference,
# deferred llvm and abandoned every package behind it in the queue. Neither side would
# ever build it: a deadlock that left a whole week of runs doing nothing.
# The version comparison below reads that clone and nothing else refreshes it — the
# auto-update that normally would is off on purpose (see the top of this script).
refresh_core_clone() {
  local core_clone
  core_clone="$(brew --repo homebrew/core 2>/dev/null)"
  if [ -z "$core_clone" ] || [ ! -d "$core_clone/.git" ]; then
    log "⚠️ no homebrew/core clone found; version checks read the API, which lags"
    return 0
  fi
  if git -C "$core_clone" pull --ff-only -q >>"$LOG" 2>&1; then
    log "ℹ️  homebrew/core at $(git -C "$core_clone" rev-parse --short HEAD)"
  else
    log "⚠️ could not refresh homebrew/core; version checks may be stale"
  fi
}
refresh_core_clone

todo=()
for pkg in "${PACKAGES[@]}"; do
  info=$(brew info --json=v2 "homebrew/core/$pkg" 2>/dev/null)
  upstream=$(printf '%s' "$info" | jq -r '.formulae[0].versions.stable // empty')
  upstream_revision=$(printf '%s' "$info" | jq -r '.formulae[0].revision // 0')
  [ "${upstream_revision:-0}" -gt 0 ] && upstream="${upstream}_${upstream_revision}"
  pinned=$(grep -m1 -E '^\s*version ' "Formula/${pkg}.rb" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
  pinned_revision=$(grep -m1 -E '^\s*revision ' "Formula/${pkg}.rb" 2>/dev/null | awk '{print $2}')
  [ -n "$pinned_revision" ] && pinned="${pinned}_${pinned_revision}"
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

# `brew install --build-bottle` refuses to start when a dependency it would install has
# no bottle for this platform (Homebrew's UnbottledError):
#
#   Error: llvm: The following formula cannot be installed from bottle and must be
#   built from source.
#     expat
#
# homebrew-core no longer ships Intel/Ventura bottles, so a plain dependency bump —
# expat 2.8.4 to 2.8.5 was the one that stopped llvm dead — blocks the build before it
# begins. Rebuild whatever brew names from source and try once more, taking the names
# from the error itself: a first version asked `brew outdated` instead, and in the
# launchd environment that reported nothing at all while the build failed on expat.
build_bottle() {
  local pkg="$1" attempt out unbottled dep
  out="$(mktemp)"
  for attempt in 1 2; do
    : >"$out"
    caffeinate -is brew install --build-bottle "homebrew/core/$pkg" 2>&1 | tee -a "$LOG" >"$out"
    if ! grep -q "cannot be installed from bottle and must be" "$out"; then
      rm -f "$out"
      return 0
    fi
    if [ "$attempt" = "2" ]; then
      log "✗ $pkg: still unbottled after rebuilding its dependencies"
      rm -f "$out"
      return 0
    fi
    unbottled=$(awk '
      /cannot be installed from bottle and must be/ { grab = 1; next }
      grab && /^  [^ ]/                             { sub(/^ +/, ""); print; next }
      grab && !/^built from source/                 { grab = 0 }
    ' "$out")
    if [ -z "$unbottled" ]; then
      log "✗ $pkg: could not read the unbottled dependencies out of brew's error"
      rm -f "$out"
      return 0
    fi
    for dep in $unbottled; do
      log "dependency $dep has no bottle for this platform — rebuilding it from source"
      caffeinate -is brew upgrade --build-from-source "$dep" >>"$LOG" 2>&1 ||
        log "⚠️ could not rebuild $dep from source; the retry will probably fail"
    done
  done
}

published=0
for entry in "${todo[@]}"; do
  pkg="${entry%%:*}"; version="${entry##*:}"

  log "building $pkg $version (hours; caffeinated)…"
  build_bottle "$pkg"
  # Check the Cellar directly: `brew list --versions` resolves to the tap's
  # pour-wrapper, not the keg we built, so it reports the wrong thing here.
  keg="$(ls -dt "/usr/local/Cellar/${pkg}/"*/ 2>/dev/null | head -1)"
  [ "$(basename "${keg%/}")" = "$version" ] || { log "✗ $pkg: keg not at $version — not publishing"; continue; }

  mkdir -p bottles && ( cd bottles && brew bottle --json --root-url "$ROOT_URL" "homebrew/core/$pkg" >>"$LOG" 2>&1 )

  # brew writes "<name>--<version>.<tag>.bottle[.<rebuild>].tar.gz", so a versioned
  # formula lands as "llvm@22--22.1.8.ventura.bottle.1.tar.gz". Discover what was
  # actually written instead of guessing: this used to expect "llvm-22-...", a name
  # brew never produces, so llvm@22 silently never published. The tap's own form is
  # the single-dash one the generated wrapper's url points at, so rename to it —
  # exactly what CI does in build.sh.
  raw_tarball="$(ls -t bottles/"${pkg}--${version}."*.tar.gz 2>/dev/null | head -1)"
  raw_json="$(ls -t bottles/"${pkg}--${version}."*.json 2>/dev/null | head -1)"
  if [ -z "$raw_tarball" ] || [ -z "$raw_json" ]; then
    log "✗ $pkg: no bottle tarball/json produced — leaving for manual review"
    continue
  fi
  tarball="bottles/$(basename "$raw_tarball" | sed 's/--/-/')"
  json="bottles/$(basename "$raw_json" | sed 's/--/-/')"
  [ "$raw_tarball" = "$tarball" ] || mv "$raw_tarball" "$tarball"
  [ "$raw_json" = "$json" ] || mv "$raw_json" "$json"
  log "bottle ready: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"

  BOTTLES_DIR="$PWD/bottles" ./scripts/update_formula.sh "$json" >>"$LOG" 2>&1 || log "⚠️ update_formula.sh exited non-zero"
  if grep -q "HOMEBREW_LIBRARY" "Formula/${pkg}.rb"; then
    log "formula placeholder pass guard passed ✓"
  else
    log "❌ Formula/${pkg}.rb lacks the placeholder pass — NOT publishing; manual review"
    continue
  fi

  # Linkage is advisory here, exactly as build.sh made it in CI, and for the same two
  # reasons. llvm records zstd through a version-qualified opt path from this machine
  # (`opt/zstd/1.5.7_1/lib`), which brew calls a broken dependency but the generated
  # wrapper's relocation pass rewrites to `opt/zstd/` at pour time; and "undeclared"
  # fires because brew reads homebrew/core/llvm's declarations rather than the tap
  # wrapper's, which declares libffi (the generator adds it explicitly). Failing on
  # either is what stopped this llvm bottle from publishing, twelve hours after it was
  # built. The CI run dispatched below is what actually exercises the poured keg:
  # restore_tap_formula runs verify_package, which execs the binaries.
  linkout="$(brew linkage "$pkg" 2>/dev/null || true)"
  if printf '%s\n' "$linkout" | grep -qE '^(Broken|Undeclared) dependencies'; then
    printf '%s\n' "$linkout" | sed -n '/^\(Broken\|Undeclared\) dependencies/,/^[A-Z]/p' | sed 's/^/    /' >>"$LOG"
    log "⚠️  $pkg: linkage is not clean — publishing anyway (advisory, as in CI)"
  else
    log "linkage clean ✓"
  fi

  # Asset first, formula second: a pushed formula must never point at an asset that is
  # not on the release yet — CI's checksum check would fail it, and the version check here
  # would no longer see a difference, so nothing would ever retry it.
  if gh release upload stable "$tarball" "$json" --repo "$TAP" --clobber >>"$LOG" 2>&1; then
    log "✅ uploaded ($(basename "$tarball") + json)"
  else
    log "✗ upload failed — leaving the formula uncommitted so the next run retries"
    continue
  fi

  git add "Formula/${pkg}.rb" && git commit -q -m "chore(bottles): update ${pkg} (${version}) [skip ci]" >>"$LOG" 2>&1 && log "formula committed"
  git pull --rebase -q origin main >>"$LOG" 2>&1
  git push -q origin main >>"$LOG" 2>&1 && log "✅ pushed" || log "⚠️ push failed (formula committed locally; next run will push it)"
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
