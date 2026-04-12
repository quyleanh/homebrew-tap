# 🍺 homebrew-tap

A high-performance, private Homebrew Tap providing pre-built binary bottles for Intel-based Macs.

This repository solves the "end-of-life" problem for older Intel Macs (like the MacBook Pro 2017) by providing a continuous build pipeline that hosts binaries on GitHub Releases, bypassing the need for long local compilations.

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
| **OS Support** | macOS 12 (Monterey) through macOS 15 (Sequoia) |
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
| `scripts/cleanup_release.sh` | Automatically removes old/unused bottles from the GitHub Release to keep it lean. |
| `scripts/batch_replace_on_mac.sh` | Locally migrates all your existing packages to use this tap. |

---

## 🔍 Troubleshooting

**Q: Why is Homebrew still trying to build from source?**
A: Ensure you have tapped the repo correctly. Try running `brew untap quyleanh/tap && brew tap quyleanh/tap`. Also, check that the package is listed in [`Formula/`](./Formula/).

**Q: SHA256 Checksum Mismatch?**
A: This happens if a build was interrupted or an asset was manually changed. The automated pipeline usually fixes this on the next run, but you can also trigger a **Manual Build** with `force_build: true` in the GitHub Actions tab.

---

## ⚖️ License
MIT. Created and maintained for personal use on 2017-era Intel Macs.