# homebrew-tap

Private Homebrew Tap with pre-built bottles for macOS Ventura (13) on Intel x86_64.

Solves the problem of Homebrew dropping full binary support for 2017 Intel Macs.

## Supported machine

| Machine | macOS | Chip |
|---------|-------|------|
| MacBook Pro 2017 | Ventura 13 | Intel Core i5/i7 |

## Initial setup

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/homebrew-tap/main/install.sh)"
```

Or manually:

```bash
brew tap YOUR_USERNAME/tap https://github.com/YOUR_USERNAME/homebrew-tap
```

## Usage

```bash
# Install a package
brew install YOUR_USERNAME/tap/ffmpeg

# Update all
brew update && brew upgrade

# List available packages
brew tap-info YOUR_USERNAME/tap
```

## Default packages

See and edit the list at [`packages.txt`](./packages.txt).

| Package | Description |
|---------|-------------|
| ffmpeg | Audio/video processing |
| aria2 | Download manager |
| bash | Latest bash shell |
| fzf | Fuzzy finder |
| go | Go runtime |
| hugo | Static site generator |
| jq | JSON processor |
| node | Node.js runtime |
| rclone | Cloud storage sync |
| tmux | Terminal multiplexer |
| tree | Directory tree |
| wget | File downloader |
| yt-dlp | Video downloader |
| argon2 | Password hashing |

## Adding or removing packages

1. Edit [`packages.txt`](./packages.txt)
2. Push to GitHub
3. GitHub Actions automatically builds new bottles
4. Run `brew update && brew upgrade` on your machine

## Manual build

Go to the **Actions** tab on GitHub → select **Build Bottles** → **Run workflow**.

Use the `force_build = true` option to rebuild all packages regardless of version.

## How it works

```
packages.txt  (you edit this)
      ↓
GitHub Actions (macos-15-intel, Intel x86_64)
builds each package with --build-bottle
      ↓
Bottles packed from Cellar and uploaded to Release "stable"
      ↓
Formula/ auto-updated with new SHA256 and URLs
      ↓
brew update && brew upgrade on your machine
→ downloads the bottle, no local compilation
```