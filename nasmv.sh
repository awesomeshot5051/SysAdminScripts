#!/usr/bin/env bash
# nasmv: fast move (or copy) of files to the file server using rsync.
#
# Tuned for a gigabit LAN: no compression, no delta calculation, no temp files.
# By default files are MOVED (the source is deleted only after rsync confirms
# that file was transferred). Use -c to keep the originals.

set -u

DEFAULT_BASE="/mnt/share/projects"
DEFAULT_MOUNT="/mnt/share"

usage() {
    cat <<'EOF'
usage: nasmv [-c] [-n] [--base=PATH] FILE... DEST
       nasmv [-c] [-n] [--base=PATH] - DEST      read the file list from stdin, one per line

  FILE          files to transfer. A relative path is relative to where you run
                the command. Every FILE must exist, or nothing is transferred.
  DEST          destination folder on the file server (always the last argument).
                A relative path is placed under the base folder. An absolute path,
                ~ path or file:/// link is used as is. Created automatically if it
                does not exist.
  --base=PATH   base folder for relative destinations (also accepted as
                --base PATH). Default: /mnt/share/projects
  -c, --copy    copy instead of move (keep the originals)
  -n, --dry-run show what would be transferred, change nothing
  -h, --help    show this help

Everywhere a path is accepted (FILE, DEST, --base) you can use any of:
  a file:/// link          file:///home/me/Videos/My%20Clip.mov
  a full path              /home/me/Videos/clip.mov
  a relative path          Videos/clip.mov
  a tilde path             ~/Videos/clip.mov
Use -- before a file whose name starts with a dash.

Paths with spaces must be quoted. As a safety net, if the destination was typed
without quotes and starts with /, ~ or file://, nasmv joins the pieces back
together (and tells you) when that folder, or its parent, exists.

examples:
  nasmv ~/Videos/Mission16-17/*.mov "Channel/Videos/Game/Mission16-17/Raw"

  nasmv --base=/mnt/share ./*.mov "projects/Other Channel/Raw"

  Paste a list of file:/// links straight from your file manager:
  nasmv - "Channel/Videos/Game/Mission16-17/Raw" <<'LIST'
  file:///home/me/Videos/a.mov
  file:///home/me/Videos/b.mov
  LIST

environment overrides: NASMV_BASE (default base folder), NASMV_MOUNT (required mount point)
The --base option wins over NASMV_BASE.
EOF
    exit "${1:-1}"
}

# Normalize any supported path form: file:// URI (with %20 style escapes decoded)
# and a leading ~ or ~/ expanded to $HOME. Anything else is returned unchanged.
resolve_path() {
    local p="$1"
    if [[ "$p" == file://* ]]; then
        p="${p#file://}"
        # file://localhost/path is the same as file:///path
        [[ "$p" == localhost/* ]] && p="${p#localhost}"
        p="${p//\\/\\\\}"
        p="$(printf '%b' "${p//%/\\x}")"
    fi
    if [[ "$p" == "~" ]]; then
        p="$HOME"
    elif [[ "$p" == "~/"* ]]; then
        p="$HOME/${p#"~/"}"
    fi
    printf '%s' "$p"
}

# Like resolve_path, but a relative result is anchored to the current directory
# and trailing slashes are dropped.
resolve_abs() {
    local p
    p="$(resolve_path "$1")"
    [[ "$p" == /* ]] || p="$PWD/$p"
    while [[ "$p" != "/" && "$p" == */ ]]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

copy=0
dry=0
base_arg=""
positional=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--copy) copy=1 ;;
        -n|--dry-run) dry=1 ;;
        -cn|-nc) copy=1; dry=1 ;;
        -h|--help) usage 0 ;;
        --base=*) base_arg="${1#--base=}" ;;
        --base)
            shift
            if [[ $# -eq 0 ]]; then
                echo "nasmv: --base needs a path" >&2
                exit 1
            fi
            base_arg="$1"
            ;;
        --)
            shift
            positional+=("$@")
            break
            ;;
        -) positional+=("$1") ;;
        -*)
            echo "nasmv: unknown option '$1'" >&2
            usage 1
            ;;
        *) positional+=("$1") ;;
    esac
    shift
done

# Inputs first, destination last (like cp, mv and rsync).
[[ ${#positional[@]} -ge 2 ]] || usage 1
args=("${positional[@]}")
nargs=${#args[@]}
dest_arg="${args[nargs-1]}"
inputs=("${args[@]:0:nargs-1}")

# Every input must exist (the lone "-" means: read the list from stdin).
missing=()
if [[ ! ( ${#inputs[@]} -eq 1 && "${inputs[0]}" == "-" ) ]]; then
    for a in "${inputs[@]}"; do
        [[ -e "$(resolve_path "$a")" ]] || missing+=("$a")
    done
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    # Most likely cause: a destination with spaces that was typed without quotes,
    # so the shell split it into several words. Try to put it back together.
    k=0
    while (( k < nargs )) && [[ -e "$(resolve_path "${args[k]}")" ]]; do
        k=$((k + 1))
    done

    recovered=0
    if (( k >= 1 && nargs - k >= 2 )); then
        first="${args[k]}"
        if [[ "$first" == /* || "$first" == "~"* || "$first" == file://* ]]; then
            joined="$first"
            for ((i = k + 1; i < nargs; i++)); do
                joined+=" ${args[i]}"
            done
            jp="$(resolve_path "$joined")"
            if [[ -d "$jp" || -d "$(dirname -- "$jp")" ]]; then
                inputs=("${args[@]:0:k}")
                dest_arg="$joined"
                recovered=1
                echo "nasmv: note: the destination looks like it was typed without quotes. Using: $joined" >&2
                echo "nasmv: note: quote paths that contain spaces." >&2
            fi
        fi
    fi

    if (( ! recovered )); then
        for m in "${missing[@]}"; do
            echo "nasmv: not found: '$m'" >&2
        done
        echo "nasmv: nothing was transferred. Check the file names. Paths with spaces must be quoted," >&2
        echo "nasmv: and the destination goes last: nasmv FILE... DEST" >&2
        exit 1
    fi
fi

# A destination that is an existing file means the arguments are in the wrong order.
if [[ -f "$(resolve_path "$dest_arg")" ]]; then
    echo "nasmv: the destination '$dest_arg' is an existing file." >&2
    echo "nasmv: the destination folder goes last: nasmv FILE... DEST" >&2
    exit 1
fi

set -- ${inputs[@]+"${inputs[@]}"}

# Base folder: --base wins, then NASMV_BASE, then the built-in default.
if [[ -n "$base_arg" ]]; then
    BASE="$(resolve_abs "$base_arg")"
else
    BASE="$(resolve_abs "${NASMV_BASE:-$DEFAULT_BASE}")"
fi
MOUNT="$(resolve_abs "${NASMV_MOUNT:-$DEFAULT_MOUNT}")"

# Destination: absolute, ~ and file:/// forms are used as is, relative goes under the base.
dest="$(resolve_path "$dest_arg")"
[[ "$dest" == /* ]] || dest="$BASE/$dest"
while [[ "$dest" != "/" && "$dest" == */ ]]; do
    dest="${dest%/}"
done

# Refuse to run if the share is not actually mounted. This stops mkdir -p from
# silently creating the folders on a local drive when the NAS is unmounted.
if [[ "$dest" == "$MOUNT"/* || "$dest" == "$MOUNT" ]]; then
    if ! mountpoint -q "$MOUNT"; then
        echo "nasmv: '$MOUNT' is not mounted. Mount the file server first." >&2
        exit 1
    fi
fi

files=()

add_file() {
    local f
    f="$(resolve_path "$1")"
    [[ -z "$f" ]] && return
    if [[ -d "$f" ]]; then
        echo "nasmv: skipping directory '$f' (files only)" >&2
    elif [[ -f "$f" ]]; then
        files+=("$f")
    else
        echo "nasmv: skipping '$f' (not found)" >&2
    fi
}

if [[ $# -eq 1 && "$1" == "-" ]]; then
    while IFS= read -r line; do
        add_file "$line"
    done
else
    for arg in "$@"; do
        add_file "$arg"
    done
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "nasmv: no valid files to transfer." >&2
    exit 1
fi

total_bytes="$(stat -c %s -- "${files[@]}" | awk '{s += $1} END {print s + 0}')"
if command -v numfmt >/dev/null 2>&1; then
    total_human="$(numfmt --to=iec --suffix=B "$total_bytes")"
else
    total_human="${total_bytes} bytes"
fi

if (( copy )); then verb="Copying"; else verb="Moving"; fi
(( dry )) && verb="Dry run: would transfer"
echo "$verb ${#files[@]} file(s), $total_human, to:"
echo "  $dest"

# -r recurse, -t keep timestamps, -h readable sizes.
# --whole-file skips delta calculation, --inplace skips the temp file + rename.
# No compression: video is already compressed, so it would only cost CPU.
args=(-rth --whole-file --inplace --info=name1,progress2)
(( copy )) || args+=(--remove-source-files)
(( dry )) && args+=(-n)

(( dry )) || mkdir -p -- "$dest" || {
    echo "nasmv: could not create '$dest'" >&2
    exit 1
}

if rsync "${args[@]}" -- "${files[@]}" "$dest/"; then
    if (( dry )); then
        echo "Dry run finished. Nothing was changed."
    elif (( copy )); then
        echo "Done! Copied ${#files[@]} file(s). Originals kept."
    else
        echo "Done! Moved ${#files[@]} file(s). Originals removed after transfer."
    fi
else
    status=$?
    echo "nasmv: rsync failed (exit code $status). Source files that did not finish were left in place." >&2
    echo "Re-run the same command to retry." >&2
    exit "$status"
fi
