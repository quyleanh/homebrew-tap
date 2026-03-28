# homebrew-tap

Private Homebrew Tap với pre-built bottles cho macOS Monterey (12) và Ventura (13) trên Intel x86_64.

Giải quyết vấn đề Homebrew không còn hỗ trợ đầy đủ binary cho các máy Mac Intel đời 2017.

## Máy được hỗ trợ

| Máy | macOS | Chip |
|-----|-------|------|
| MacBook Air 2017 | Monterey 12 | Intel Core i5/i7 |
| MacBook Pro 2017 | Ventura 13 | Intel Core i5/i7 |

## Cài đặt lần đầu

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/homebrew-tap/main/install.sh)"
```

Hoặc thủ công:

```bash
brew tap YOUR_USERNAME/tap https://github.com/YOUR_USERNAME/homebrew-tap
```

## Cách dùng

```bash
# Cài một package
brew install YOUR_USERNAME/tap/ffmpeg

# Update tất cả
brew update && brew upgrade

# Xem danh sách package có sẵn
brew tap-info YOUR_USERNAME/tap
```

## Packages mặc định

Xem và chỉnh sửa danh sách tại [`packages.txt`](./packages.txt).

| Package | Mô tả |
|---------|-------|
| ffmpeg | Xử lý audio/video |
| git | Version control |
| python@3.13 | Python runtime |
| node | Node.js runtime |
| wget | Download files |
| curl | HTTP client |
| jq | JSON processor |
| htop | Process monitor |
| tree | Directory tree |
| ripgrep | Fast search (rg) |
| fd | Fast find |

## Cách thêm/bớt package

1. Chỉnh sửa [`packages.txt`](./packages.txt)
2. Push lên GitHub
3. GitHub Actions tự động build bottles mới
4. Chạy `brew update && brew upgrade` trên máy

## Build thủ công

Vào tab **Actions** trên GitHub → chọn **Build Bottles** → **Run workflow**.

## Cách hoạt động

```
packages.txt (bạn chỉnh)
      ↓
GitHub Actions (macos-13, Intel)
build với MACOSX_DEPLOYMENT_TARGET=12.0
      ↓
Upload bottles lên Release "stable"
      ↓
Tự động update Formula/ với SHA256 mới
      ↓
brew update && brew upgrade trên máy bạn
→ tải bottle về, không build gì cả
```
