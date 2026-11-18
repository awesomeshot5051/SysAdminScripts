# SysAdminScripts

A collection of the sysadmin and media-workflow scripts I use daily in my home lab.

## A note on file extensions

The file extensions in this repo (`.py`, `.sh`) exist **only for the sake of the repo**, so GitHub
can syntax-highlight and classify each script. On my machines the scripts are installed with no
extension (for example `/usr/local/bin/tovinci`), and some scripts call each other by that
extensionless name (`ytdownload` calls `tovinci`).

**When you install them, I suggest removing the extension** for easier usage, so you can type
`tovinci` instead of `tovinci.py`:

```sh
sudo install -m 755 tovinci.py /usr/local/bin/tovinci
sudo install -m 755 ytdownload.sh /usr/local/bin/ytdownload
```

Or install them all at once:

```sh
for f in *.py *.sh; do sudo install -m 755 "$f" "/usr/local/bin/${f%.*}"; done
```

## Scripts

| Script | Type | Description |
|---|---|---|
| `catdir.py` | Python 3 | Concatenate, summarize, JSON-export, or rebuild a directory tree. Supports glob-based ignore patterns (`-i`) that prune whole directories. |
| `fastget.sh` | Bash | Multi-connection file downloader (default 16 threads, saves to `~/Downloads`). Options: `-t/--threads`, `-o/--output`. |
| `hostsync.py` | Python 3 | rsync wrapper for syncing between home lab hosts, with optional domain discovery (`-D`) and password logins. |
| `nasmv.sh` | Bash | Fast move (or copy with `-c`) of files to the file server over rsync, tuned for a gigabit LAN. Supports `-n` dry run. |
| `rawproject.sh` | Bash | Create, finish, and list raw-footage project folders on the file server, or on a local btrfs disk with snapper snapshots (`-ld`). |
| `screenson.sh` | Bash | Reset hardware brightness to 100% on displays 1-3 via `ddcutil`. Must be run as root. |
| `sshtest.sh` | Bash | Wait for a host to come up and accept SSH logins (header calls it `sshwait`), with adjustable verbosity (`-v` to `-vvvv`). |
| `tovinci.py` | Python 3 | Convert media into DaVinci Resolve (Linux) friendly formats: DNxHR, ProRes, H.264, WAV, or JPEG. Can combine clips, resume jobs, and dry-run size estimates. |
| `ytdownload.sh` | Bash | `yt-dlp` wrapper that outputs mp4, mp3, mov, or wav (mov and wav are converted with `tovinci`). |

## Requirements

- **Python scripts:** Python 3.8+
- `hostsync`, `nasmv`: `rsync` and `ssh` (`sshpass` only for password logins)
- `tovinci`: `ffmpeg`
- `ytdownload`: `yt-dlp` and `tovinci` installed
- `screenson`: `ddcutil`
- `rawproject`: `ssh`; local mode needs btrfs, snapper, and systemd
- `sshtest`: `sshpass` (optional, falls back to a TCP port check)

## Configuration (hard-coded paths removed)

Personal hostnames, usernames, IP addresses, and mount paths have been stripped from the scripts
and replaced with generic placeholders. Examples in help text now use made-up values
(`example.lan`, `192.0.2.x`, `/mnt/share`). Where a path or host is genuinely needed to run, it is
now a variable at the top of the script that you can override with an environment variable, so you
don't have to edit the script:

| Script | Variable | Default (placeholder) | Purpose |
|---|---|---|---|
| `rawproject.sh` | `RAWPROJECT_SERVER` | `fileserver.example` | File server hostname |
| `rawproject.sh` | `RAWPROJECT_USER` | `rawproject` | SSH user on the file server |
| `rawproject.sh` | `RAWPROJECT_KEY` | `~/.ssh/rawproject_ed25519` | SSH private key |
| `rawproject.sh` | `RAWPROJECT_ROOT` | `/mnt/share` | Local mount point of the share |
| `nasmv.sh` | `NASMV_BASE` | `/mnt/share/projects` | Base folder for relative destinations |
| `nasmv.sh` | `NASMV_MOUNT` | `/mnt/share` | Mount point that must be mounted |
| `tovinci.py` | `TOVINCI_FORBIDDEN_ROOT` | *(unset, check disabled)* | Optional directory resume data must never be stored under |

Set these in your shell profile, for example:

```sh
export RAWPROJECT_SERVER=files.mylab.lan
export RAWPROJECT_ROOT=/mnt/nas/storage
export NASMV_BASE=/mnt/nas/storage/projects
export NASMV_MOUNT=/mnt/nas/storage
```

`ytdownload.sh` now finds `tovinci` on your `PATH` instead of at a fixed location.

Run any script with `-h`/`--help` to see its usage.
