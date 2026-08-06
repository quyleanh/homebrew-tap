# Build recipe used by the bottle workflow. update_formula.sh replaces this
# file with the release-bottle wrapper after a successful build.
class Ffmpeg < Formula
  desc "Play, record, convert, and stream select audio and video codecs"
  homepage "https://ffmpeg.org/"
  url "https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz"
  sha256 "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
  license "GPL-3.0-or-later"
  revision 2

  depends_on "pkgconf" => :build
  depends_on "nasm" => :build if Hardware::CPU.intel?

  depends_on "dav1d"
  depends_on "lame"
  depends_on "libvmaf"
  depends_on "libvpx"
  depends_on "openssl@3"
  depends_on "opus"
  depends_on "sdl2-compat"
  depends_on "svt-av1"
  depends_on "x264"
  depends_on "x265"

  uses_from_macos "bzip2"
  uses_from_macos "libxml2"

  def install
    # Homebrew's build environment on macOS 15 injects its own deployment
    # target. Override it explicitly so this bottle remains runnable on macOS
    # 13, which is the oldest supported Intel host for this tap.
    ENV["MACOSX_DEPLOYMENT_TARGET"] = "13.0"

    args = %W[
      --prefix=#{prefix}
      --enable-shared
      --enable-pthreads
      --enable-version3
      --cc=#{ENV.cc}
      --host-cflags=#{ENV.cflags}
      --host-ldflags=#{ENV.ldflags}
      --enable-ffplay
      --enable-gpl
      --enable-libsvtav1
      --enable-libopus
      --enable-libx264
      --enable-libmp3lame
      --enable-libdav1d
      --enable-libvmaf
      --enable-libvpx
      --enable-libx265
      --enable-openssl
      --disable-indev=avfoundation
      --disable-outdev=avfoundation
      --extra-cflags=-mmacosx-version-min=13.0
      --extra-ldflags=-mmacosx-version-min=13.0
    ]

    args += %w[--enable-videotoolbox --enable-audiotoolbox] if OS.mac?
    system "./configure", *args
    system "make", "install"
    system "make", "alltools"
    bin.install (buildpath/"tools").children.select { |f| f.file? && f.executable? }
    pkgshare.install buildpath/"tools/python"
  end

  test do
    system bin/"ffmpeg", "-hide_banner", "-f", "lavfi", "-i", "testsrc=rate=1:duration=1", "-f", "null", "-"
  end
end
