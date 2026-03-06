#!/usr/bin/env bash
set -euo pipefail
export LC_NUMERIC=C

readonly VERSION="1.0.0"
readonly SUPPORTED_EXTENSIONS="jpg jpeg png webp avif"
readonly QUALITY_JPEG=85
readonly QUALITY_WEBP=82
readonly QUALITY_AVIF=60
readonly PNG_COMPRESSION_LEVEL=9
RESULTS_DIR_CLEANUP=""

# ── Utility Functions ─────────────────────────────────────────────────

detect_stat_format() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

readonly STAT_PLATFORM="$(detect_stat_format)"

get_file_size_bytes() {
    local file="$1"
    if [[ "$STAT_PLATFORM" == "macos" ]]; then
        stat -f%z "$file"
    else
        stat -c%s "$file"
    fi
}

human_readable_size() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        printf "%.2f GB" "$(echo "scale=2; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.2f MB" "$(echo "scale=2; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.2f KB" "$(echo "scale=2; $bytes / 1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

log_info()  { printf "\033[0;32m[INFO]\033[0m  %s\n" "$*" >&2; }
log_warn()  { printf "\033[0;33m[WARN]\033[0m  %s\n" "$*" >&2; }
log_error() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; }
log_verbose() { (( VERBOSE >= 1 )) && printf "\033[0;36m[VERB]\033[0m  %s\n" "$*" >&2 || true; }
log_debug()   { (( VERBOSE >= 3 )) && printf "\033[0;35m[DEBUG]\033[0m %s\n" "$*" >&2 || true; }

show_progress() {
    if [[ "$SHOW_PROGRESS" == true ]]; then
        local current="$1" total="$2" file="$3"
        local pct=0
        (( total > 0 )) && pct=$(( current * 100 / total ))
        local bar_width=30
        local filled=$(( pct * bar_width / 100 ))
        local empty=$(( bar_width - filled ))
        local bar
        bar="$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$empty" '' | tr ' ' '░')"
        printf "\r\033[K\033[0;33m[%d/%d]\033[0m %s %d%% %s" "$current" "$total" "$bar" "$pct" "$file" >&2
    fi
}

clear_progress() {
    if [[ "$SHOW_PROGRESS" == true ]]; then
        printf "\r\033[K" >&2
    fi
}

get_cpu_count() {
    if command -v nproc &>/dev/null; then
        nproc
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        sysctl -n hw.ncpu
    else
        echo 4
    fi
}

# ── Help & Version ────────────────────────────────────────────────────

show_help() {
    cat <<'EOF'
imgtool.sh - Batch Image Processor (ImageMagick 7)

USAGE:
    imgtool.sh [OPTIONS] <directory>

DESCRIPTION:
    Recursively processes images in the given directory using ImageMagick 7.
    Supports compression, resizing, dimension limits, and format conversion.
    At least one operation is required: --compress, --resize, --max-width/--max-height, or --convert.

OPTIONS:
    --compress            Enable compression using format-aware defaults
    --resize N%            Proportional resize (e.g., 50%)
    --max-width PIXELS     Maximum width ceiling (shrink only)
    --max-height PIXELS    Maximum height ceiling (shrink only)
    --convert FORMAT       Convert to format: webp, png, jpeg, avif
    --quality N            Override default quality (1-100)
    --keep-original        Keep original file alongside processed file
    --parallel [N]         Enable parallel processing (default: CPU count)
    --dry-run              Preview operations without processing
    --progress             Show progress bar during processing
    -v                     Verbose output (file details)
    -vvv                   Debug output (magick commands, dimensions)
    --help                 Show this help message
    --version              Show version

QUALITY DEFAULTS:
    JPEG = 85, WebP = 82, AVIF = 60, PNG = compression-level 9

EXAMPLES:
    imgtool.sh --compress ./images               # Compress in place
    imgtool.sh --resize 50% ./images             # Resize to 50%
    imgtool.sh --compress --quality 70 ./images  # Compress with custom quality
    imgtool.sh --convert webp --keep-original .   # Convert to WebP, keep originals
    imgtool.sh --max-width 800 --max-height 600 ./photos
    imgtool.sh --parallel 8 --quality 70 ./bulk
    imgtool.sh --progress -v ./images             # With progress bar and verbose
    imgtool.sh -vvv ./images                      # Debug mode (full details)

EOF
}

show_version() {
    echo "imgtool.sh version $VERSION"
}

# ── Argument Parsing ──────────────────────────────────────────────────

parse_args() {
    COMPRESS=false
    RESIZE=""
    MAX_WIDTH=""
    MAX_HEIGHT=""
    CONVERT_FORMAT=""
    QUALITY_OVERRIDE=""
    KEEP_ORIGINAL=false
    PARALLEL=0
    DRY_RUN=false
    VERBOSE=0
    SHOW_PROGRESS=false
    TARGET_DIR=""
    PROCESS_SINGLE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --compress)
                COMPRESS=true; shift ;;
            --resize)
                [[ -z "${2:-}" ]] && { log_error "--resize requires a value (e.g., 50%)"; exit 1; }
                RESIZE="$2"; shift 2 ;;
            --max-width)
                [[ -z "${2:-}" ]] && { log_error "--max-width requires a value"; exit 1; }
                MAX_WIDTH="$2"; shift 2 ;;
            --max-height)
                [[ -z "${2:-}" ]] && { log_error "--max-height requires a value"; exit 1; }
                MAX_HEIGHT="$2"; shift 2 ;;
            --convert)
                [[ -z "${2:-}" ]] && { log_error "--convert requires a format (webp, png, jpeg, avif)"; exit 1; }
                CONVERT_FORMAT="$2"; shift 2 ;;
            --quality)
                [[ -z "${2:-}" ]] && { log_error "--quality requires a value (1-100)"; exit 1; }
                QUALITY_OVERRIDE="$2"; shift 2 ;;
            --keep-original)
                KEEP_ORIGINAL=true; shift ;;
            --parallel)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    PARALLEL="$2"; shift 2
                else
                    PARALLEL="$(get_cpu_count)"; shift
                fi
                ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --progress)
                SHOW_PROGRESS=true; shift ;;
            -vvv)
                VERBOSE=3; shift ;;
            -v)
                VERBOSE=1; shift ;;
            --help)
                show_help; exit 0 ;;
            --version)
                show_version; exit 0 ;;
            --_process-single)
                PROCESS_SINGLE="$2"; shift 2 ;;
            -*)
                log_error "Unknown option: $1"; echo "Run 'imgtool.sh --help' for usage."; exit 1 ;;
            *)
                TARGET_DIR="$1"; shift ;;
        esac
    done
}

# ── Validation ────────────────────────────────────────────────────────

validate() {
    if ! command -v magick &>/dev/null; then
        log_error "ImageMagick 7 (magick) is not installed or not in PATH."
        case "$(uname -s)" in
            Darwin)
                echo "Install on macOS: brew install imagemagick" >&2
                ;;
            Linux)
                echo "Install on Ubuntu/Debian: sudo apt install imagemagick" >&2
                echo "Install on Fedora: sudo dnf install ImageMagick" >&2
                echo "Install on Arch: sudo pacman -S imagemagick" >&2
                ;;
            *)
                echo "Install ImageMagick 7 and ensure the 'magick' command is in PATH." >&2
                ;;
        esac
        echo "Official downloads: https://imagemagick.org/script/download.php" >&2
        exit 1
    fi

    if ! command -v bc &>/dev/null; then
        log_error "Required dependency 'bc' is not installed or not in PATH."
        case "$(uname -s)" in
            Darwin)
                echo "Install on macOS: brew install bc" >&2
                ;;
            Linux)
                echo "Install on Ubuntu/Debian: sudo apt install bc" >&2
                echo "Install on Fedora: sudo dnf install bc" >&2
                echo "Install on Arch: sudo pacman -S bc" >&2
                ;;
            *)
                echo "Install 'bc' and ensure it is in PATH." >&2
                ;;
        esac
        exit 1
    fi

    if [[ -z "$TARGET_DIR" ]]; then
        log_error "No target directory specified."
        echo "Run 'imgtool.sh --help' for usage."
        exit 1
    fi

    if [[ "$COMPRESS" == false && -z "$RESIZE" && -z "$MAX_WIDTH" && -z "$MAX_HEIGHT" && -z "$CONVERT_FORMAT" ]]; then
        log_warn "No operation specified."
        show_help
        exit 0
    fi

    if [[ ! -d "$TARGET_DIR" ]]; then
        log_error "Directory not found: $TARGET_DIR"
        exit 1
    fi

    if [[ ! -r "$TARGET_DIR" ]]; then
        log_error "Directory not readable: $TARGET_DIR"
        exit 1
    fi

    if [[ -n "$CONVERT_FORMAT" ]]; then
        case "$CONVERT_FORMAT" in
            webp|png|jpeg|jpg|avif) ;;
            *) log_error "Unsupported conversion format: $CONVERT_FORMAT (use webp, png, jpeg, avif)"; exit 1 ;;
        esac
    fi

    if [[ -n "$QUALITY_OVERRIDE" ]]; then
        if ! [[ "$QUALITY_OVERRIDE" =~ ^[0-9]+$ ]] || (( QUALITY_OVERRIDE < 1 || QUALITY_OVERRIDE > 100 )); then
            log_error "--quality must be a number between 1 and 100"
            exit 1
        fi
        if [[ "$COMPRESS" == false && -z "$CONVERT_FORMAT" ]]; then
            log_error "--quality requires --compress or --convert"
            exit 1
        fi
    fi

    if [[ -n "$RESIZE" ]]; then
        if ! [[ "$RESIZE" =~ ^[0-9]+%$ ]]; then
            log_error "--resize must be in the form N% (e.g., 50%)"
            exit 1
        fi
    fi

    if [[ -n "$MAX_WIDTH" ]] && ! [[ "$MAX_WIDTH" =~ ^[0-9]+$ ]]; then
        log_error "--max-width must be a positive integer"
        exit 1
    fi

    if [[ -n "$MAX_HEIGHT" ]] && ! [[ "$MAX_HEIGHT" =~ ^[0-9]+$ ]]; then
        log_error "--max-height must be a positive integer"
        exit 1
    fi
}

# ── Core Processing ───────────────────────────────────────────────────

get_output_extension() {
    local input_file="$1"
    local input_ext="${input_file##*.}"
    input_ext="$(echo "$input_ext" | tr '[:upper:]' '[:lower:]')"

    if [[ -n "$CONVERT_FORMAT" ]]; then
        case "$CONVERT_FORMAT" in
            jpg) echo "jpeg" ;;
            *)   echo "$CONVERT_FORMAT" ;;
        esac
    else
        case "$input_ext" in
            jpg) echo "jpeg" ;;
            *)   echo "$input_ext" ;;
        esac
    fi
}

get_quality_for_format() {
    local fmt="$1"
    if [[ -n "$QUALITY_OVERRIDE" ]]; then
        echo "$QUALITY_OVERRIDE"
        return
    fi
    case "$fmt" in
        jpeg|jpg) echo "$QUALITY_JPEG" ;;
        webp)     echo "$QUALITY_WEBP" ;;
        avif)     echo "$QUALITY_AVIF" ;;
        png)      echo "" ;;
        *)        echo "$QUALITY_JPEG" ;;
    esac
}

get_output_file_extension() {
    local fmt="$1"
    case "$fmt" in
        jpeg) echo "jpg" ;;
        *)    echo "$fmt" ;;
    esac
}

process_file() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        log_warn "File not found, skipping: $input_file"
        return 1
    fi

    local input_ext="${input_file##*.}"
    input_ext="$(echo "$input_ext" | tr '[:upper:]' '[:lower:]')"

    local output_format
    output_format="$(get_output_extension "$input_file")"

    local output_file_ext
    output_file_ext="$(get_output_file_extension "$output_format")"

    local output_file
    local is_converting=false
    if [[ -n "$CONVERT_FORMAT" ]]; then
        local base="${input_file%.*}"
        output_file="${base}.${output_file_ext}"
        if [[ "$(echo "$input_ext" | tr '[:upper:]' '[:lower:]')" != "$output_file_ext" ]]; then
            is_converting=true
        fi
    else
        output_file="$input_file"
    fi

    local input_size
    input_size="$(get_file_size_bytes "$input_file")"

    log_verbose "Processing: $input_file (format=$output_format, size=$(human_readable_size "$input_size"))"
    if [[ "$is_converting" == true ]]; then
        log_verbose "Converting: $input_ext -> $output_file_ext"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        local hr_size
        hr_size="$(human_readable_size "$input_size")"
        if [[ "$is_converting" == true ]]; then
            log_info "[DRY-RUN] Would convert: $input_file -> $output_file ($hr_size)"
        else
            log_info "[DRY-RUN] Would process: $input_file ($hr_size)"
        fi
        echo "$input_size $input_size 0"
        return 0
    fi

    # Build magick arguments
    local -a magick_args=()
    if [[ "$COMPRESS" == true ]]; then
        magick_args+=("-strip")
    fi

    # Progressive/interlaced output helps JPEG delivery, but for PNG it often
    # increases file size substantially (Adam7). Keep it format-specific.
    if [[ "$COMPRESS" == true && "$output_format" == "jpeg" ]]; then
        magick_args+=("-interlace" "Plane")
    fi

    # Sampling factor for JPEG and WebP
    if [[ "$COMPRESS" == true && ( "$output_format" == "jpeg" || "$output_format" == "webp" ) ]]; then
        magick_args+=("-sampling-factor" "4:2:0")
    fi

    # Resize (proportional)
    if [[ -n "$RESIZE" ]]; then
        magick_args+=("-resize" "$RESIZE")
    fi

    # Max dimensions (shrink only with > flag)
    if [[ -n "$MAX_WIDTH" || -n "$MAX_HEIGHT" ]]; then
        local dim_w="${MAX_WIDTH:-}"
        local dim_h="${MAX_HEIGHT:-}"
        magick_args+=("-resize" "${dim_w}x${dim_h}>")
    fi

    # Quality settings
    local quality
    quality="$(get_quality_for_format "$output_format")"
    if [[ "$output_format" == "png" && ( "$COMPRESS" == true || -n "$CONVERT_FORMAT" ) ]]; then
        # PNG is lossless here. Keep deterministic max compression and avoid
        # mapping generic --quality values to settings that can bloat output.
        magick_args+=("-define" "png:compression-level=$PNG_COMPRESSION_LEVEL")
        magick_args+=("-define" "png:compression-filter=5")
        magick_args+=("-define" "png:compression-strategy=1")
        magick_args+=("-define" "png:exclude-chunks=date,time")
    elif [[ ( "$COMPRESS" == true || -n "$CONVERT_FORMAT" ) && -n "$quality" ]]; then
        magick_args+=("-quality" "$quality")
    elif [[ -n "$QUALITY_OVERRIDE" ]]; then
        magick_args+=("-quality" "$QUALITY_OVERRIDE")
    fi

    if (( ${#magick_args[@]} > 0 )); then
        log_debug "Magick args: ${magick_args[*]}"
    else
        log_debug "Magick args: <none>"
    fi
    if [[ -n "$RESIZE" ]]; then
        log_debug "Resize: $RESIZE"
    fi
    if [[ -n "$MAX_WIDTH" || -n "$MAX_HEIGHT" ]]; then
        log_debug "Max dimensions: ${MAX_WIDTH:-auto}x${MAX_HEIGHT:-auto}"
    fi
    log_debug "Quality: ${quality:-default} (format=$output_format)"

    # Create temp file in the same directory for atomic move
    local output_dir
    output_dir="$(dirname "$output_file")"
    local tmp_file
    tmp_file="$(mktemp "${output_dir}/.imgtool_tmp_XXXXXX")"

    local magick_output="${output_format}:${tmp_file}"
    log_debug "Command: magick \"$input_file\" ${magick_args[*]} \"$magick_output\""

    # Execute magick
    if (( VERBOSE >= 3 )); then
        if ! magick "$input_file" "${magick_args[@]}" "$magick_output"; then
            log_error "Failed to process: $input_file"
            rm -f "$tmp_file"
            return 1
        fi
    else
        if ! magick "$input_file" "${magick_args[@]}" "$magick_output" 2>/dev/null; then
            log_error "Failed to process: $input_file"
            rm -f "$tmp_file"
            return 1
        fi
    fi

    local output_size
    output_size="$(get_file_size_bytes "$tmp_file")"

    # If not converting and output is larger than input, keep original
    if [[ "$COMPRESS" == true && "$is_converting" == false && -z "$RESIZE" && -z "$MAX_WIDTH" && -z "$MAX_HEIGHT" ]]; then
        if (( output_size >= input_size )); then
            log_info "Skipped (output not smaller): $input_file ($(human_readable_size "$input_size"))"
            rm -f "$tmp_file"
            echo "$input_size $input_size 1"
            return 0
        fi
    fi

    local saved_bytes=$(( input_size - output_size ))
    local saved_pct=0
    if (( input_size > 0 )); then
        saved_pct=$(( saved_bytes * 100 / input_size ))
    fi

    if [[ "$KEEP_ORIGINAL" == true ]]; then
        mv -f "$tmp_file" "$output_file"
        log_info "Processed: $input_file -> $output_file ($(human_readable_size "$input_size") -> $(human_readable_size "$output_size"), ${saved_pct}% saved)"
    elif [[ "$is_converting" == true ]]; then
        mv -f "$tmp_file" "$output_file"
        rm -f "$input_file"
        log_info "Converted: $input_file -> $output_file ($(human_readable_size "$input_size") -> $(human_readable_size "$output_size"), ${saved_pct}% saved)"
    else
        mv -f "$tmp_file" "$output_file"
        log_info "Processed: $input_file ($(human_readable_size "$input_size") -> $(human_readable_size "$output_size"), ${saved_pct}% saved)"
    fi

    echo "$input_size $output_size 0"
    return 0
}

# ── Summary ───────────────────────────────────────────────────────────

print_summary() {
    local processed="$1"
    local skipped="$2"
    local failed="$3"
    local total_input="$4"
    local total_output="$5"
    local elapsed="$6"

    local saved=$(( total_input - total_output ))
    local saved_pct=0
    if (( total_input > 0 )); then
        saved_pct=$(( saved * 100 / total_input ))
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  imgtool.sh - Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  Processed : %d files\n" "$processed"
    printf "  Skipped   : %d files\n" "$skipped"
    printf "  Failed    : %d files\n" "$failed"
    echo "  ──────────────────────────────────────────────"
    printf "  Total before : %s\n" "$(human_readable_size "$total_input")"
    printf "  Total after  : %s\n" "$(human_readable_size "$total_output")"
    printf "  Space saved  : %s (%d%%)\n" "$(human_readable_size "$saved")" "$saved_pct"
    printf "  Elapsed time : %d seconds\n" "$elapsed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── File Discovery ────────────────────────────────────────────────────

build_find_args() {
    local dir="$1"
    local -a args=("$dir" "(")
    local first=true
    for ext in $SUPPORTED_EXTENSIONS; do
        if [[ "$first" == true ]]; then
            first=false
        else
            args+=("-o")
        fi
        args+=("-iname" "*.${ext}")
    done
    args+=(")" "-type" "f" "-print0")
    echo "${args[@]}"
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    parse_args "$@"

    # Handle single-file processing for parallel mode
    if [[ -n "$PROCESS_SINGLE" ]]; then
        process_file "$PROCESS_SINGLE"
        return $?
    fi

    validate

    local start_time
    start_time="$(date +%s)"

    log_info "Scanning: $TARGET_DIR"
    [[ "$DRY_RUN" == true ]] && log_info "Dry-run mode enabled"
    (( VERBOSE >= 1 )) && log_verbose "Verbose level: $VERBOSE"
    if (( VERBOSE >= 1 )) && [[ "$COMPRESS" == true ]]; then
        log_verbose "Compression: enabled"
    fi

    local processed=0
    local skipped=0
    local failed=0
    local total_input=0
    local total_output=0
    local file_count=0
    local total_files=0

    if (( PARALLEL > 1 )) && [[ "$SHOW_PROGRESS" == true ]]; then
        log_warn "--progress is only available in sequential mode; continuing without progress bar in parallel mode."
        SHOW_PROGRESS=false
    fi

    # Count files for progress
    if [[ "$SHOW_PROGRESS" == true ]]; then
        local count_cmd
        count_cmd=(find "$TARGET_DIR" "(")
        local first_c=true
        for ext in $SUPPORTED_EXTENSIONS; do
            if [[ "$first_c" == true ]]; then first_c=false; else count_cmd+=("-o"); fi
            count_cmd+=("-iname" "*.${ext}")
        done
        count_cmd+=(")" "-type" "f")
        total_files=$("${count_cmd[@]}" 2>/dev/null | wc -l | tr -d ' ')
        log_info "Found $total_files files to process"
    fi

    if (( PARALLEL > 1 )); then
        # Parallel mode: use xargs with self-invocation
        local results_dir
        results_dir="$(mktemp -d)"
        RESULTS_DIR_CLEANUP="$results_dir"
        trap '[[ -n "${RESULTS_DIR_CLEANUP:-}" ]] && rm -rf "$RESULTS_DIR_CLEANUP"' EXIT

        local script_path
        script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

        # Build the argument passthrough
        local -a passthrough_args=()
        [[ "$COMPRESS" == true ]]    && passthrough_args+=("--compress")
        [[ -n "$RESIZE" ]]           && passthrough_args+=("--resize" "$RESIZE")
        [[ -n "$MAX_WIDTH" ]]        && passthrough_args+=("--max-width" "$MAX_WIDTH")
        [[ -n "$MAX_HEIGHT" ]]       && passthrough_args+=("--max-height" "$MAX_HEIGHT")
        [[ -n "$CONVERT_FORMAT" ]]   && passthrough_args+=("--convert" "$CONVERT_FORMAT")
        [[ -n "$QUALITY_OVERRIDE" ]] && passthrough_args+=("--quality" "$QUALITY_OVERRIDE")
        [[ "$KEEP_ORIGINAL" == true ]] && passthrough_args+=("--keep-original")
        [[ "$DRY_RUN" == true ]]     && passthrough_args+=("--dry-run")
        (( VERBOSE >= 3 ))           && passthrough_args+=("-vvv")
        (( VERBOSE >= 1 && VERBOSE < 3 )) && passthrough_args+=("-v")
        # TARGET_DIR is required for parse_args but not used in single mode
        passthrough_args+=("$TARGET_DIR")

        # Find files and process in parallel
        local find_cmd
        find_cmd=(find "$TARGET_DIR" "(")
        local first=true
        for ext in $SUPPORTED_EXTENSIONS; do
            if [[ "$first" == true ]]; then
                first=false
            else
                find_cmd+=("-o")
            fi
            find_cmd+=("-iname" "*.${ext}")
        done
        find_cmd+=(")" "-type" "f" "-print0")

        # Process with xargs, capturing output
        "${find_cmd[@]}" 2>/dev/null | xargs -0 -P "$PARALLEL" -I{} bash -c '
            result=$("'"$script_path"'" '"$(printf '%q ' "${passthrough_args[@]}")"' --_process-single "$1" 2>&1)
            status=$?
            echo "$result" >> "'"$results_dir"'/result_$$.txt"
            echo "__IMGTOOL_STATUS__:$status" >> "'"$results_dir"'/result_$$.txt"
        ' _ {} || true

        # Aggregate results
        for result_file in "$results_dir"/result_*.txt; do
            [[ -f "$result_file" ]] || continue
            while IFS= read -r line; do
                # Lines with stats: "input_size output_size skipped_flag"
                if [[ "$line" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
                    read -r in_sz out_sz skip_flag <<< "$line"
                    total_input=$(( total_input + in_sz ))
                    if (( skip_flag == 1 )); then
                        skipped=$(( skipped + 1 ))
                        total_output=$(( total_output + in_sz ))
                    else
                        processed=$(( processed + 1 ))
                        total_output=$(( total_output + out_sz ))
                    fi
                elif [[ "$line" =~ ^__IMGTOOL_STATUS__:[0-9]+$ ]]; then
                    local status_code="${line#__IMGTOOL_STATUS__:}"
                    if (( status_code != 0 )); then
                        failed=$(( failed + 1 ))
                    fi
                else
                    # Print log lines
                    echo "$line" >&2
                fi
            done < "$result_file"
        done

    else
        # Sequential mode
        local find_cmd
        find_cmd=(find "$TARGET_DIR" "(")
        local first=true
        for ext in $SUPPORTED_EXTENSIONS; do
            if [[ "$first" == true ]]; then
                first=false
            else
                find_cmd+=("-o")
            fi
            find_cmd+=("-iname" "*.${ext}")
        done
        find_cmd+=(")" "-type" "f" "-print0")

        while IFS= read -r -d '' file; do
            file_count=$(( file_count + 1 ))
            show_progress "$file_count" "$total_files" "$(basename "$file")"
            local result
            if result="$(process_file "$file")"; then
                if [[ "$result" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
                    read -r in_sz out_sz skip_flag <<< "$result"
                    total_input=$(( total_input + in_sz ))
                    if (( skip_flag == 1 )); then
                        skipped=$(( skipped + 1 ))
                        total_output=$(( total_output + in_sz ))
                    else
                        processed=$(( processed + 1 ))
                        total_output=$(( total_output + out_sz ))
                    fi
                fi
            else
                failed=$(( failed + 1 ))
            fi
        done < <("${find_cmd[@]}" 2>/dev/null)
        clear_progress
    fi

    local end_time
    end_time="$(date +%s)"
    local elapsed=$(( end_time - start_time ))

    print_summary "$processed" "$skipped" "$failed" "$total_input" "$total_output" "$elapsed"

    if [[ "$COMPRESS" == true && "$processed" -eq 0 && "$skipped" -gt 0 && "$failed" -eq 0 && -z "$RESIZE" && -z "$MAX_WIDTH" && -z "$MAX_HEIGHT" && -z "$CONVERT_FORMAT" ]]; then
        log_warn "No file became smaller with current compression settings."
        log_warn "Try a lower quality value, e.g.: --compress --quality 70 <directory>"
    fi
}

main "$@"
