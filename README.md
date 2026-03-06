# imgtool.sh

Batch image processor for the command line. A single, self-contained Bash script that uses [ImageMagick 7](https://imagemagick.org/) to recursively compress, resize, and convert images.

## Features

- **Recursive processing** - Finds and processes images in all subdirectories
- **Smart compression** - Format-aware quality defaults (JPEG 85, WebP 82, AVIF 60, PNG level 9)
- **Resize** - Proportional scaling (`--resize 50%`) or max dimension capping (`--max-width`, `--max-height`)
- **Format conversion** - Convert between JPEG, PNG, WebP, and AVIF
- **Parallel processing** - Process multiple files simultaneously with `--parallel`
- **Safe operations** - Atomic writes via temp files, skips replacement if output is larger than input
- **Dry-run mode** - Preview what would happen without modifying files
- **Cross-platform** - Works on macOS and Linux

## Requirements

- Bash 4+
- [ImageMagick 7](https://imagemagick.org/script/download.php) (`magick` command)

### Installing ImageMagick

```bash
# macOS
brew install imagemagick

# Ubuntu / Debian
sudo apt install imagemagick

# Fedora
sudo dnf install ImageMagick

# Arch
sudo pacman -S imagemagick
```

## Quick Start (Remote Usage)

Run directly from the repository without installing — ideal for one-off tasks:

```bash
# Compress all images in ./images
bash <(curl -sL https://fabioassuncao.com/gh/imgtool/imgtool.sh) ./images

# Resize to 50%
bash <(curl -sL https://fabioassuncao.com/gh/imgtool/imgtool.sh) --resize 50% ./images

# Convert to WebP keeping originals
bash <(curl -sL https://fabioassuncao.com/gh/imgtool/imgtool.sh) --convert webp --keep-original ./photos
```

Using `wget`:

```bash
bash <(wget -qO- https://fabioassuncao.com/gh/imgtool/imgtool.sh) ./images
```

> **Note:** Remote execution requires `curl` or `wget` and an internet connection. ImageMagick 7 must be installed locally. The `--parallel` flag is not supported in remote mode since self-invocation requires a local script file.

## Installation (Local Usage)

For regular use, download the script locally:

```bash
# Download and make executable
curl -sL https://fabioassuncao.com/gh/imgtool/imgtool.sh -o imgtool.sh
chmod +x imgtool.sh

# Optional: move to a directory in your PATH for global access
sudo mv imgtool.sh /usr/local/bin/imgtool
```

Or clone the repository:

```bash
git clone https://github.com/fabioassuncao/imgtool.git
cd imgtool
chmod +x imgtool.sh
```

After installing locally, you can run it from anywhere:

```bash
imgtool ./images
```

## Usage

```
imgtool.sh [OPTIONS] <directory>
```

### Options

| Option | Description |
|---|---|
| `--resize N%` | Proportional resize (e.g., `50%`) |
| `--max-width PIXELS` | Maximum width ceiling (shrink only) |
| `--max-height PIXELS` | Maximum height ceiling (shrink only) |
| `--convert FORMAT` | Convert to: `webp`, `png`, `jpeg`, `avif` |
| `--quality N` | Override default quality (1-100) |
| `--keep-original` | Keep original file alongside processed file |
| `--parallel [N]` | Parallel processing (default: CPU count) |
| `--dry-run` | Preview operations without processing |
| `--help` | Show help message |
| `--version` | Show version |

### Examples

**Compress all images in a directory (in place):**

```bash
./imgtool.sh ./images
```

**Resize to 50%:**

```bash
./imgtool.sh --resize 50% ./images
```

**Convert to WebP, keeping originals:**

```bash
./imgtool.sh --convert webp --keep-original ./images
```

**Limit dimensions to 800x600:**

```bash
./imgtool.sh --max-width 800 --max-height 600 ./photos
```

**Parallel processing with custom quality:**

```bash
./imgtool.sh --parallel 8 --quality 70 ./bulk
```

**Preview without changes:**

```bash
./imgtool.sh --dry-run ./images
```

## Supported Formats

| Format | Default Quality | Notes |
|---|---|---|
| JPEG/JPG | 85 | Progressive, 4:2:0 chroma subsampling |
| WebP | 82 | Progressive, 4:2:0 chroma subsampling |
| AVIF | 60 | Progressive encoding |
| PNG | Compression level 9 | Lossless compression optimization |

## How It Works

1. Recursively finds all supported image files (`jpg`, `jpeg`, `png`, `webp`, `avif`)
2. For each file, builds an optimized `magick` command with:
   - `-strip` to remove metadata (EXIF, ICC profiles, etc.)
   - `-interlace Plane` for progressive encoding
   - `-sampling-factor 4:2:0` for JPEG/WebP
   - Format-appropriate quality settings
3. Writes output to a temp file in the same directory (ensures atomic move on same filesystem)
4. Compares output size to input — if compress-only and output is larger, keeps original
5. Replaces original (or writes alongside it with `--keep-original`)

### Resize Behavior

When `--resize` is combined with `--max-width`/`--max-height`, the resize is applied first, then the max dimensions act as a ceiling (shrink only, using ImageMagick's `>` flag). This ensures images never exceed the specified limits.

### Parallel Mode

Uses `xargs -P` with self-invocation. The script calls itself with a hidden `--_process-single` flag for each file, allowing safe concurrent processing without shared state.

## Output

After processing, a summary is displayed:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  imgtool.sh - Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Processed : 42 files
  Skipped   : 3 files
  Failed    : 0 files
  ──────────────────────────────────────────────
  Total before : 128.50 MB
  Total after  : 41.23 MB
  Space saved  : 87.27 MB (67%)
  Elapsed time : 12 seconds
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## License

MIT
