# 🍺 homebrew-tap

> **Status (October 2026): this tap is retired.** The machine it served now uses official
> upstream binaries and MacPorts; see [Current setup](#-current-setup-october-2026-this-tap-is-retired).
> CI and the Mac builder are disabled and nothing in this repository needs maintaining.

A high-performance, private Homebrew Tap providing pre-built binary bottles for Intel-based Macs.

This repository solves the "end-of-life" problem for older Intel Macs (like the MacBook Pro 2017) by providing a continuous build pipeline that hosts binaries on GitHub Releases, bypassing the need for long local compilations.

---

## ✅ Current setup (October 2026): this tap is retired

The reason this tap existed — re-supplying Intel/Ventura bottles that Homebrew no longer
builds — is gone. The machine now uses, in order of preference:

1. **official upstream binaries** where the project publishes a macOS amd64 build,
2. **MacPorts**, which still ships `darwin_22` (macOS 13) x86_64 binary archives,
3. **Homebrew only for casks** (prebuilt app downloads — no compiling).

| Source | What comes from it |
|---|---|
| Official upstream binaries → `~/.local/bin` | node, deno, go, gh, jq, fzf, gitleaks, rclone, yt-dlp, docker, docker-compose, colima, limactl, nasm, git-filter-repo, hugo, rtk |
| MacPorts → `/opt/local/bin` (binary-only) | ffmpeg, bash, tmux, aria2, tree, argon2, potrace |
| Homebrew → `/usr/local` | casks only (`brew list --cask`); `wget` is the last formula left |

### Maintenance

```bash
prebuilt-install                                # update the official binaries (resolves newest releases)
sudo /opt/local/bin/port -b upgrade outdated    # update MacPorts — -b means never compile
brew upgrade --cask                             # update GUI apps
```

- `prebuilt-install` is `~/.local/bin/prebuilt-install`, generated from
  [`scripts/prebuilt-install.sh`](./scripts/prebuilt-install.sh). `prebuilt-install --check`
  resolves and prints the newest versions without downloading anything.
- **MacPorts needs `sudo`** for `install` / `upgrade` / `uninstall`, because `/opt/local`
  is root-owned by design. Read-only commands (`port info`, `port search`, `port list`) do
  not need it. There is no supported way to avoid this with the default prefix.
- **Do not run bare `brew upgrade`.** It would try to rebuild formulae that have no Ventura
  bottles. Use `brew upgrade --cask`, and leave the remaining formula alone.

### PATH

`~/.zshrc` ends with this, so the official binaries and MacPorts take precedence over
Homebrew's `/usr/local/bin` — which stays in `PATH` for casks:

```bash
export PATH="$HOME/.local/bin:/opt/local/bin:$PATH"
```

### What was given up, and why it is fine

`llvm`/`llvm@22` were dropped (unused — `CC`/`CXX` were empty), which retired the 12-hour
Mac builds with them. `node` is no longer packaged here: upstream node needs dependencies
that have no Intel/Ventura bottles, `python@3.15` cannot compile on macOS 13, and a CI job
cannot finish node inside its six-hour ceiling — the published bottle went ABI-stale. It is
now an official nodejs.org build under `~/.local`, which no Homebrew upgrade can break.

---

## 🚀 Quick Start

### 1. Automatic Installation
Run this command to automatically install Homebrew (if missing), tap this repository, and replace existing packages with versions from this tap:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/quyleanh/homebrew-tap/main/install.sh)"
```

### 2. Manual Setup
If you prefer to do it manually:

```bash
# Add the tap
brew tap quyleanh/tap

# Install a specific package from this tap
brew install quyleanh/tap/ffmpeg

# Force replace all installed packages with our versions
./scripts/batch_replace_on_mac.sh
```

---

## 💻 Supported Environment

| Component | Specification |
|-----------|---------------|
| **Hardware** | Intel-based Macs (e.g., MacBook Pro/Air 2017) |
| **OS Support** | macOS 13 (Ventura) through macOS 15 (Sequoia) |
| **Architecture** | x86_64 (Intel) |

---

## 🛠️ How It Works

This tap uses a custom **"Dependency Hijacking"** architecture to ensure your system stays within the private ecosystem:

1.  **Build Pipeline**: GitHub Actions runs on a `macos-15-intel` runner.
2.  **Bottle Generation**: Packages are built using `brew install --build-bottle`.
3.  **Binary Hosting**: The resulting `.tar.gz` bottles are uploaded to the `stable` Release.
4.  **Formula Modification**: The `scripts/update_formula.sh` script rewrites formulae to:
    *   Point the `url` directly to the GitHub Release asset.
    *   Rewrite all dependencies to point to `quyleanh/tap/dependency` instead of the default `homebrew/core`.
5.  **Clean Installation**: When you `brew install`, it downloads the pre-built binary and extracts it directly into your Cellar—no local compiling required.

### Where builds run

| Builder | Trigger | Builds |
|---------|---------|--------|
| GitHub Actions, `macos-15-intel` (`.github/workflows/build.yml`) | push to `packages.txt` / `scripts/`, manual dispatch, weekly (Mon 04:13 UTC) | everything that fits in one 6-hour job |
| This Mac, `scripts/mac_builder.sh` (launchd, daily 20:00 JST) | calendar, with a missed run fired at the next wake | the `llvm` family, which cannot fit in a CI job |

The Mac builder publishes exactly the way CI does (build → `brew bottle` → generate
formula → upload → commit) and then dispatches a CI run so the packages depending on
llvm get rebuilt.

Two files under `.github/` are pipeline state, written by the build bots—do not edit them
by hand:

| File | Purpose |
|------|---------|
| `bottle-deps.tsv` | the dependency versions each published bottle was linked against. A dependency moving is a rebuild signal even when the dependent's own version has not changed (this is what caught ffmpeg linked against a stale `x265`). |
| `build-times.tsv` | measured build durations. Used to decide whether a package still fits in the remaining job window; raised automatically after a build, a cap-kill or a cancellation. |

---

## 📝 Managing Packages

### Adding New Packages
1.  Open [`packages.txt`](./packages.txt).
2.  Add the name of the Homebrew formula you want.
3.  Commit and push to GitHub.
4.  The **GitHub Action** will automatically trigger, resolve all dependencies, and build everything in the correct topological order.

### Maintenance Scripts
| Script | Purpose |
|--------|---------|
| `scripts/build.sh` | The main build engine. Handles dependency graphs and builds bottles. |
| `scripts/update_formula.sh` | Post-build script that generates the `.rb` formula files. |
| `scripts/mac_builder.sh` | Builds the `llvm` family on this Mac and dispatches CI when it publishes. |
| `scripts/cleanup_release.sh` | Automatically removes old/unused bottles from the GitHub Release to keep it lean. |
| `scripts/batch_replace_on_mac.sh` | Locally migrates all your existing packages to use this tap. |
| `scripts/check_homebrew.sh` | Audits an installed machine: broken links, missing dylibs, unrelocated placeholders. |

---

## 🔍 Troubleshooting

**Q: Why is Homebrew still trying to build from source?**
A: Ensure you have tapped the repo correctly. Try running `brew untap quyleanh/tap && brew tap quyleanh/tap`. Also, check that the package is listed in [`Formula/`](./Formula/).

**Q: SHA256 Checksum Mismatch?**
A: This happens if a build was interrupted or an asset was manually changed. The automated pipeline usually fixes this on the next run, but you can also trigger a **Manual Build** with `force_build: true` in the GitHub Actions tab.

**Q: A build log says a package was "Skipped for the time budget"?**
A: Its measured build time no longer fits the 5-hour window (the biggest ones—`node`, `deno`—routinely do not). Run the workflow manually with `only_package=<package>` to give that one package the whole job, or let the Mac builder take it if it is in the `llvm` family.

**Q: Where is `node`? It used to be in this tap.**
A: It was removed on purpose. Upstream node 26.12 needs `python@3.15`, `icu4c@79`, `rust` and more, none of which homebrew-core ships Intel/Ventura bottles for; `python@3.15` does not build on macOS 13 at all (it needs a newer clang with tail-call support), and node itself does not finish inside CI's six-hour ceiling. The last bottle that shipped went ABI-stale — it still asked for `libsimdjson.33` and `libsimdutf.36` after those libraries moved — so it installed a `node` that could not start. Use a self-contained node instead: the official nodejs.org tarball or `nvm`. Nothing this tap ships depends on node, and a self-contained node cannot be broken by a Homebrew upgrade.

---

## ⚖️ License
MIT. Created and maintained for personal use on 2017-era Intel Macs.