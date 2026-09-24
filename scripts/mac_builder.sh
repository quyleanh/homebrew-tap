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
#
# The revision belongs in that test. Homebrew's pkg_version is "23.1.1_1" for a
# revision bump, and comparing versions.stable alone made this script report "up to
# date" for llvm 23.1.1_1 while CI — which does add the revision — saw the difference,
# deferred llvm and abandoned every package behind it in the queue. Neither side would
# ever build it: a deadlock that left a whole week of runs doing nothing.
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

  # Gate: refuse to publish a keg that only works on this machine. `brew linkage` reports
  # both directions — a library we link but do not declare, and a declared dependency whose
  # path does not resolve — and either one is a SIGABRT on a clean runner. This gate would
  # have caught the llvm bottle (undeclared libffi, version-pinned zstd path) before it shipped.
  linkout="$(brew linkage "$pkg" 2>/dev/null || true)"
  if printf '%s\n' "$linkout" | grep -qE '^(Broken|Undeclared) dependencies'; then
    printf '%s\n' "$linkout" | sed -n '/^\(Broken\|Undeclared\) dependencies/,/^[A-Z]/p' | sed 's/^/    /' >>"$LOG"
    log "❌ $pkg: linkage is not clean — NOT publishing; manual review"
    continue
  fi
  log "linkage clean ✓"

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
