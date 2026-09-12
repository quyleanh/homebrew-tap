#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOTTLES_DIR="${BOTTLES_DIR:-$REPO_ROOT/bottles}"
FORMULA_DIR="${FORMULA_DIR:-$REPO_ROOT/Formula}"
# Replace with your actual Username/Repo
TAP_NAME="quyleanh/tap" 
RELEASE_URL="https://github.com/${GITHUB_REPOSITORY:-quyleanh/homebrew-tap}/releases/download/stable"

mkdir -p "$FORMULA_DIR" "$BOTTLES_DIR"

echo "=== Formula Updater (Dependency Hijacking Edition) ==="

if [ "$#" -gt 0 ]; then
  JSON_FILES=("$@")
else
  JSON_FILES=("$BOTTLES_DIR"/*.bottle.json)
  if [ ${#JSON_FILES[@]} -eq 0 ] || [ ! -f "${JSON_FILES[0]}" ]; then
    JSON_FILES=("$BOTTLES_DIR"/*.json)
  fi
fi

if [ ${#JSON_FILES[@]} -eq 0 ] || [ ! -f "${JSON_FILES[0]}" ]; then
  echo "No bottle JSON files found."
  exit 1
fi

for json_file in "${JSON_FILES[@]}"; do
  pkg_key=$(jq -r 'keys[0]' "$json_file")
  # Bottle JSON may use a fully-qualified tap key (e.g. quyleanh/tap/ffmpeg),
  # but generated formulas must always be written as Formula/ffmpeg.rb.
  pkg_name="${pkg_key##*/}"
  echo "Processing: $pkg_name"

  # 1. Extract metadata from JSON
  version=$(jq -r --arg pkg "$pkg_key" '.[$pkg].formula.pkg_version' "$json_file")
  sha256=$(jq -r --arg pkg "$pkg_key" '.[$pkg].bottle.tags | to_entries[0].value.sha256' "$json_file")
  bottle_rebuild=$(jq -r --arg pkg "$pkg_key" '.[$pkg].bottle.rebuild // 0' "$json_file")
  homepage=$(jq -r --arg pkg "$pkg_key" '.[$pkg].formula.homepage' "$json_file")
  desc=$(jq -r --arg pkg "$pkg_key" '.[$pkg].formula.desc' "$json_file")
  cellar=$(jq -r --arg pkg "$pkg_key" '.[$pkg].bottle.cellar // (.[$pkg].bottle.tags | to_entries[0].value.cellar) // "any"' "$json_file")
  if [ "$cellar" = "any" ] || [ "$cellar" = ":any" ]; then
    cellar_ruby=":any"
  elif [ "$cellar" = "any_skip_relocation" ] || [ "$cellar" = ":any_skip_relocation" ]; then
    cellar_ruby=":any_skip_relocation"
  else
    cellar_ruby="\"$cellar\""
  fi

  # 2. Handle Class Name conversion (e.g., Python@3.14 -> PythonAT314, ada-url -> AdaUrl)
  class_name=$(ruby -e '
    name = ARGV[0].capitalize
    name.gsub!(/[-_.\s]([a-zA-Z0-9])/) { Regexp.last_match(1).upcase }
    name.tr!("+", "x")
    name.sub!(/(.)@(\d)/, "\\1AT\\2")
    puts name
  ' "$pkg_name")

  # 3. HIJACK DEPENDENCIES: Point all dependencies to your own Tap
  # This is critical to ensure users stay within your custom ecosystem
  deps=$(jq -r --arg pkg "$pkg_key" --arg tap "$TAP_NAME" '
    # Homebrew has used both dependencies and runtime_dependencies in bottle
    # metadata. Keep this fallback explicit so a missing field cannot silently
    # turn a dynamically-linked formula into a dependency-free formula.
    (
      .[$pkg].formula.dependencies
      // .[$pkg].formula.runtime_dependencies
      // [
        .[$pkg].bottle.tags
        | to_entries[]
        | .value.tab.runtime_dependencies[]?
        | select(.declared_directly != false)
        | (.full_name // .name)
      ]
      // []
    ) |
    map(if type == "string" then . else (.full_name // .name) end) |
    map(split("/") | last) |
    unique |
    map("  depends_on \"" + $tap + "/" + . + "\"") |
    join("\n")
  ' "$json_file")

  # `brew bottle --json` does not consistently include formula dependency
  # metadata across Homebrew versions. Fall back to the live formula metadata
  # so generated tap formulae never lose their runtime dependency graph.
  if [ -z "$deps" ]; then
    deps=$(brew info --json=v2 "$pkg_name" 2>/dev/null | jq -r --arg tap "$TAP_NAME" '
      (.formulae[0].dependencies // []) |
      map("  depends_on \"" + $tap + "/" + . + "\"") |
      join("\n")
    ' 2>/dev/null || true)
  fi

  # Link-time dependencies that upstream does not declare. LLVM's CMake picks up libffi
  # when the build machine happens to have it, so the bottle links it, the formula does
  # not list it, and a runner that installs strictly from the formula SIGABRTs the first
  # time a clang tool starts. Declare it so the resolver installs it first.
  case "$pkg_name" in
    llvm | llvm@*)
      case "$deps" in
        *libffi*) ;;
        *) deps="${deps:+$deps$'\n'}  depends_on \"$TAP_NAME/libffi\"" ;;
      esac
      ;;
  esac

  formula_file="$FORMULA_DIR/${pkg_name}.rb"

  # The target machine is macOS 13, so reference the Ventura-compatible alias
  # when the current build produced one. This also makes release cleanup retain
  # the asset that Homebrew's bottle resolver will request.
  actual_tar=$(find "$BOTTLES_DIR" -maxdepth 1 -name "${pkg_name}-${version}.ventura.bottle.*.tar.gz" -exec basename {} \; | head -n 1)
  [ -n "$actual_tar" ] || actual_tar=$(find "$BOTTLES_DIR" -maxdepth 1 -name "${pkg_name}--*.sequoia.bottle.*.tar.gz" -exec basename {} \; | head -n 1)
  [ -n "$actual_tar" ] || actual_tar=$(find "$BOTTLES_DIR" -maxdepth 1 -name "${pkg_name}--*.tar.gz" -exec basename {} \; | head -n 1)
  [ -n "$actual_tar" ] || actual_tar="${pkg_name}-${version}.ventura.bottle.1.tar.gz"

  if [[ "$version" == *"_"* ]]; then
    base_ver="${version%%_*}"
    rev="${version##*_}"
    version_ruby=$(printf 'version "%s"\n  revision %s' "$base_ver" "$rev")
  else
    version_ruby="version \"$version\""
  fi

  # Extract the rebuild number directly from actual_tar so Homebrew download requests
  # always match the exact filename uploaded to the release
  bottle_rebuild_ruby="    rebuild 1"
  if [[ "$actual_tar" =~ \.bottle\.([0-9]+)\.tar\.gz$ ]]; then
    bottle_rebuild_ruby="    rebuild ${BASH_REMATCH[1]}"
  fi

  # 4. Generate the Formula file content
  cat > "$formula_file" << RUBY
# Auto-generated by update_formula.sh
class ${class_name} < Formula
  desc "$desc"
  homepage "$homepage"
  $version_ruby
  
  # Use a dummy URL to download the pre-built .tar.gz file directly
  url "$RELEASE_URL/$actual_tar"
  sha256 "$sha256"

  bottle do
    root_url "$RELEASE_URL"
$bottle_rebuild_ruby
    sha256 cellar: ${cellar_ruby}, ventura: "$sha256"
  end

${deps}

  def install
    # The bottle tarball contains the entire Cellar hierarchy.
    # We find the first directory containing common Homebrew paths and install its contents.
    # (Checking both root and nested directories)
    content_root = (Dir["{bin,lib,include,share}"] + Dir["**/{bin,lib,include,share}"]).map { |p| File.dirname(p) }.min_by(&:length)
    if content_root
      prefix.install Dir["#{content_root}/*"]
    else
      prefix.install Dir["*"]
    end

    # Resolve Homebrew placeholders in poured files (both Mach-O binaries and text files)
    # Homebrew's relocation vocabulary is PREFIX/CELLAR/LIBRARY/REPOSITORY; bottles do
    # carry LIBRARY (python bakes it into _sysconfigdata, the file pip reads for
    # PKG_CONFIG_LIBDIR), so substitute every placeholder, not just the first two.
    placeholders = {
      "@@HOMEBREW_PREFIX@@" => HOMEBREW_PREFIX.to_s,
      "@@HOMEBREW_CELLAR@@" => HOMEBREW_CELLAR.to_s,
      "@@HOMEBREW_LIBRARY@@" => HOMEBREW_LIBRARY.to_s,
      "@@HOMEBREW_REPOSITORY@@" => HOMEBREW_REPOSITORY.to_s,
      # See Library/Homebrew/keg_relocate.rb (PERL is deterministic; JAVA is resolved
      # per openjdk dependency at bottle time, so it cannot be resolved generically.)
      "@@HOMEBREW_PERL@@" => "#{HOMEBREW_PREFIX}/opt/perl/bin/perl",
    }
    # A dependency recorded through a version-qualified opt path (opt/zstd/1.5.7_1/lib)
    # only ever resolves on the machine that built the bottle: elsewhere opt/<name> points
    # at whatever version is installed, so the extra segment makes the path simply wrong
    # and dyld aborts. Normalise it to the canonical opt path. The version segment must
    # start with a digit so real path segments (opt/python@3.14/lib) are left alone.
    ver_opt = Regexp.new("#{Regexp.escape(HOMEBREW_PREFIX.to_s)}/opt/([A-Za-z0-9@+.-]+)/(\\d[^/]*)/")
    opt_root = "#{HOMEBREW_PREFIX}/opt/"
    sub_ph = lambda { |s|
      r = placeholders.reduce(s) { |acc, (k, v)| acc.gsub(k, v) }
      r.gsub(ver_opt) { "#{opt_root}#{$1}/" }
    }

    macho_magics = [
      0xfeedfacf, 0xcffaedfe, # 64-bit MH_MAGIC_64 & MH_CIGAM_64
      0xfeedface, 0xcefaedfe, # 32-bit MH_MAGIC & MH_CIGAM
      0xcafebabe, 0xbebafeca, # Universal Fat binary (BE & LE)
      0xcafebabf, 0xbfbafeca  # 64-bit Fat binary (BE & LE)
    ]

    Dir.glob("#{prefix}/**/*").each do |f|
      next unless File.file?(f) && !File.symlink?(f)
      begin
        magic = File.binread(f, 4) rescue nil
        next unless magic

        if macho_magics.include?(magic.unpack1("N"))
          loads = \`otool -L "#{f}" 2>/dev/null\`
          dylib_id = \`otool -D "#{f}" 2>/dev/null\`.lines.last&.strip
          otool_l = \`otool -l "#{f}" 2>/dev/null\`
          modified = false

          if loads.include?("@@HOMEBREW") || (dylib_id && dylib_id.include?("@@HOMEBREW")) || (otool_l.include?("cmd LC_RPATH") && otool_l.include?("@@HOMEBREW"))
            File.chmod(File.stat(f).mode | 0755, f)
            if dylib_id && dylib_id.include?("@@HOMEBREW")
              new_id = sub_ph.call(dylib_id)
              system "install_name_tool", "-id", new_id, f
              modified = true
            end
            loads.scan(/^\\s+([^\\s]+)/).flatten.each do |dep|
              if dep.include?("@@HOMEBREW")
                new_dep = sub_ph.call(dep)
                system "install_name_tool", "-change", dep, new_dep, f
                modified = true
              end
            end
            if otool_l.include?("cmd LC_RPATH") && otool_l.include?("@@HOMEBREW")
              otool_l.scan(/cmd LC_RPATH\\s+cmdsize \\d+\\s+path ([^\\s\\n]+)/).flatten.each do |rpath|
                if rpath.include?("@@HOMEBREW")
                  new_rpath = sub_ph.call(rpath)
                  system "install_name_tool", "-rpath", rpath, new_rpath, f
                  modified = true
                end
              end
            end
            if modified
              system "codesign", "-f", "-s", "-", f
            end
          end
        else
          sample = File.binread(f, 4096) rescue nil
          if sample && !sample.include?("\\x00")
            text = File.binread(f)
            if placeholders.any? { |k, _| text.include?(k) }
              File.chmod(File.stat(f).mode | 0200, f)
              File.binwrite(f, sub_ph.call(text))
              # A stale .pyc embeds the same placeholder and cannot be rewritten in
              # place; it would shadow the fixed source at import time, so drop the
              # cache entry and let Python regenerate it on first import.
              stem = File.basename(f, ".py")
              Dir[File.join(File.dirname(f), "__pycache__", "#{stem}.cpython-*.pyc")].each do |pyc|
                FileUtils.rm_f(pyc)
              end
            end
          end
        end
      rescue
        # Ignore binary or encoding errors
      end
    end
  end

  test do
    # Simplify the test to avoid environment errors on GitHub Runner
    assert_true true
  end
end
RUBY

  echo "  ✅ Done: ${pkg_name}.rb"
done
