#!/usr/bin/env python3
"""tovinci: convert media into DaVinci Resolve (Linux) friendly formats.

Videos become DNxHR (HQ for 8-bit sources, HQX for high bit-depth sources) in a
.mov with uncompressed PCM audio, audio-only files become WAV, and images become
high-quality JPEG. With -t, videos can instead become a much smaller H.264/AAC
.mp4 (mp4, mp4-small) or ProRes in a .mov (prores, prores-422, prores-lt,
prores-proxy). Several clips can be combined into one output in a single
pass (-c), audio tracks can be mixed (-ca) or written as separate WAVs (-sa),
and long jobs can be resumed after an interruption (-r). A dry run (-n) estimates
the output size without writing any output files, and -o sends the results to a
directory of your choice.

VP9 (-t vp9, -t vp9-hq) produces a far smaller long-GOP .mkv (VP9 CRF video, ALAC
audio) than DNxHR. Which type a plain "tovinci clip.mov" produces is set by the
DEFAULT_VIDEO_TYPE constant below, or per shell by the TOVINCI_DEFAULT_TYPE
environment variable (dnxhr, vp9, vp9-hq, mp4, mp4-small, prores, prores-422, ...).

Changelog:
  3.0.0  Added -t vp9 / vp9-hq (libvpx-vp9 CRF in .mkv, ALAC audio, row-mt on, tile
         columns maxed for the resolution, encoder threads set explicitly) and -t dnxhr.
         The default video type is now configurable (DEFAULT_VIDEO_TYPE or the
         TOVINCI_DEFAULT_TYPE environment variable); it stays DNxHR until changed.
         With -r -c, -j N now encodes N clips at the same time, splitting the CPU
         threads between them (one VP9 encode cannot keep 32 threads busy).
         Added --cpu-used N (0-5) to trade VP9 quality/size for encoding speed
         (default 2; higher is faster, a little bigger or softer at the same CRF).
         Added the job queue: --queue-add lines up conversions (current folder, relative
         or full paths), --queue-run works through them one at a time and waits 15
         seconds after each so the output is fully written; also --queue-list,
         --queue-clear, --queue-remove, --queue-gap and --queue-stop-on-error. -j works
         with it (jobs of one folder run side by side, other folders wait their turn).
  2.5.0  Added -o/--output-dir: write every output file into a chosen directory
         (created if missing). Batch runs refuse to start if two inputs would collide
         on the same output name. The dry run checks free space at that location.
  2.4.0  Added -n/--dry-run: estimates the final output size (per clip and total) by
         encoding a few short samples, without creating any output files.
  2.3.0  Restored the -t video types: mp4, mp4-small, prores, prores-hq, prores-422,
         prores-lt, prores-proxy (they had been lost from the Python rewrite).
  2.2.0  Added --version / -V.
  2.1.0  Clips are combined in natural order (1, 2, ... 10); added --keep-order.
  2.0.0  Rewritten in Python (was a bash script, 1.x); added -r/--resumable
         with --restart, --keep-work and --work-dir; ffmpeg always runs with -nostdin.
"""

from __future__ import annotations

import argparse
import atexit
import fcntl
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

VERSION = "3.0.0"
RUN_MARKER = "=== RUN START"
AUTO_THREAD_BYTES = 10 * 1024 * 1024 * 1024  # 10GB auto-threading threshold
FORBIDDEN_CACHE_ROOT = "/mnt/Data"  # resume data must never live on the secondary drive
RULE = "-" * 56
QUEUE_GAP_DEFAULT = 15  # seconds to wait after each queued job before starting the next

DRY_RUN_WINDOWS = 3        # number of sample windows taken per clip
DRY_RUN_SECONDS = 4.0      # length of each sample window in seconds

MP4_CRF = "18"        # visually near-lossless
MP4_CRF_SMALL = "23"  # noticeably smaller, still good quality
MP4_AUDIO_BITRATE = "192k"

VP9_CRF = "20"        # -t vp9
VP9_CRF_HQ = "18"     # -t vp9-hq
VP9_CPU_USED = "2"    # 0 = best/slowest ... 5 = fastest; 2 is a good balance
VP9_TILE_COLUMNS = "6"  # log2; libvpx lowers it to what the resolution allows (1080p: 2, 4K: 3)

# What a video becomes when -t is not given. Change it here, or per shell with
# TOVINCI_DEFAULT_TYPE=vp9 (dnxhr, vp9, vp9-hq, mp4, mp4-small, prores, prores-422, ...).
DEFAULT_VIDEO_TYPE = os.environ.get("TOVINCI_DEFAULT_TYPE", "dnxhr").strip().lower()
# ProRes profile name -> (prores_ks profile number, display label)
PRORES_PROFILES = {
    "proxy": ("0", "ProRes 422 Proxy"),
    "lt": ("1", "ProRes 422 LT"),
    "422": ("2", "ProRes 422"),
    "hq": ("3", "ProRes 422 HQ"),
}
TYPE_CHOICES = ("wav, wav-16, wav-24, wav-32, dnxhr, mp4, mp4-small, vp9, vp9-hq, "
                "prores, prores-hq, prores-422, prores-lt, prores-proxy")

VIDEO_EXTS = {"mov", "mp4", "mkv", "avi", "webm", "m4v", "mpg", "mpeg", "ts", "mts",
              "m2ts", "wmv", "flv", "mxf", "ogv", "3gp"}
AUDIO_EXTS = {"mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "wma", "aif", "aiff"}
IMAGE_EXTS = {"jpg", "jpeg", "png", "bmp", "gif", "tif", "tiff", "webp", "heic", "heif",
              "exr", "dpx", "psd", "tga", "jp2"}
MEDIA_EXTS = VIDEO_EXTS | AUDIO_EXTS | IMAGE_EXTS

EXAMPLES = """\
examples:
  tovinci clip.mov
  tovinci -v *.png                 step log + brief ffmpeg progress
  tovinci -vv *.png                full raw ffmpeg output, streamed live
  tovinci -t wav song.mp3          force audio-only, ignore embedded art/video
  tovinci -t wav-16 song.flac      force audio-only AND 16-bit PCM
  tovinci -t mp4 clip.mov          small H.264/AAC .mp4 instead of DNxHR
  tovinci -t mp4-small clip.mov    even smaller .mp4 (lower quality)
  tovinci -t prores clip.mov       ProRes 422 HQ in a .mov
  tovinci -t prores-lt clip.mov    smaller ProRes (422 LT)
  tovinci -t vp9 clip.mov          VP9 (CRF 20) + ALAC in .mkv, far smaller than DNxHR
  tovinci -t vp9-hq clip.mov       VP9 (CRF 18): higher quality, bigger
  tovinci -t vp9 --cpu-used 4 c.mov  VP9 encoded faster (0 best/slowest ... 5 fastest)
  tovinci --queue-add -r -sa -t vp9-hq a.mov ../Other/b.mov   line up jobs (any path)
  tovinci --queue-add -j 2 -r -sa *.mov   queue every .mov here, two at a time
  tovinci --queue-run              run the queued jobs, one folder at a time, 15 s gap per slot
  tovinci --queue-list             show the queue
  tovinci -t dnxhr clip.mov        DNxHR, even if the default type was changed to vp9
  tovinci --bits 16 clip.mov       normal conversion, but force 16-bit PCM audio
  tovinci --threaded huge.mov      force multi-threaded encoding regardless of size
  tovinci -j 4 *.mov               process up to 4 files concurrently
  tovinci --use-gpu=true clip.mov  decode on GPU (NVDEC/VAAPI/QSV) if available
  tovinci -ca clip.mov             mix all audio tracks into one stereo track
  tovinci -sa clip.mov             video-only .mov plus one WAV per audio track
  tovinci -c Name a.mov b.mov      combine, then convert -> Name.mov
  tovinci -c Name -t mp4 a.mov b.mov          combine, then convert -> Name.mp4 (name goes right after -c)
  tovinci -c a.mov b.mov           combine, then convert -> a_combined.mov
  tovinci -c --keep-order Name b.mov a.mov    combine in exactly the order given
  tovinci -c Name --no-convert a.mov b.mov    combine only, no conversion
  tovinci -r -c -sa Name a.mov b.mov          resumable combine (re-run the same command to resume)
  tovinci -r -c -sa -j 3 -t vp9 Name *.mov    resumable combine, 3 clips encoded at the same time
  tovinci -n -c Name a.mov b.mov              dry run: estimate the combined size, write nothing
  tovinci -n -t mp4 *.mov                     dry run: estimate each file's size as mp4
  tovinci -o /path/to/out *.mov               write every converted file into /path/to/out
  tovinci -c Name -o /path/to/out a.mov b.mov combine -> /path/to/out/Name.mov

types (-t):
  wav, wav-16, wav-24, wav-32     audio-only WAV (the number forces the PCM bit depth)
  mp4                             H.264 (CRF 18) + AAC 192k in .mp4, much smaller than DNxHR
  mp4-small                       H.264 (CRF 23) + AAC 192k in .mp4, smaller still
  prores, prores-hq               ProRes 422 HQ in .mov with PCM audio
  prores-422                      ProRes 422
  prores-lt                       ProRes 422 LT
  prores-proxy                    ProRes 422 Proxy
  dnxhr                           DNxHR (HQ, or HQX for high bit-depth sources) in .mov with PCM audio
  vp9                             VP9 (CRF 20, row-mt) + ALAC in .mkv, far smaller than DNxHR
  vp9-hq                          VP9 (CRF 18, row-mt) + ALAC in .mkv
  With no -t, the type is DEFAULT_VIDEO_TYPE (edit it near the top of this file) or the
  TOVINCI_DEFAULT_TYPE environment variable, e.g. TOVINCI_DEFAULT_TYPE=vp9 tovinci clip.mov
  Images still become JPEG and audio-only files still become WAV with the video types.
  Note: the free DaVinci Resolve on Linux may not decode H.264/AAC mp4 files, and VP9 or ALAC
  support there is not guaranteed. Test a short clip in Resolve before converting a big batch.

PCM audio bit depth defaults to each source track's depth (lossy sources such as AAC become 16-bit).
mp4 types use AAC audio and vp9 types use ALAC audio, so --bits does not apply to them.

clip order (-c):
  Clips are combined in natural order (1, 2, ... 9, 10), not plain text order (1, 10, 2, ...),
  so a shell glob like "Clip "*".mov" comes out right. If a different order was received, a note
  says so. Use --keep-order to combine in exactly the order given.

resume (-r):
  Combine mode encodes one clip at a time into a work directory, then joins the finished
  clips with a fast stream copy. If the run is interrupted, re-running the identical
  command skips every clip that already finished. Batch mode skips files that already
  finished. A clip that was mid-encode when interrupted is redone from its start.
  The work directory defaults to ~/.cache/tovinci and may never be under /mnt/Data.
  Peak disk use is roughly twice the final output (the parts plus the joined file).
  With -j N, N clips are encoded at the same time and the CPU threads are split between them.

dry run (-n):
  Nothing is written to the output location. For each clip, a few short sample windows are
  encoded with the exact settings a real run would use (into a temporary folder inside the
  work directory, deleted afterward), the size per second is measured, and that is scaled to
  the clip's full duration. DNxHR is close to constant bitrate, so its estimate is tight;
  mp4 and ProRes vary with content, so treat those as a ballpark. Combine with -c to see the
  size of the combined file, and with -t to compare formats. Free disk space is reported too.

vp9 threading (-t vp9, -t vp9-hq):
  libvpx only spreads one encode over many threads when row-mt is on, so it always is, with
  the tile columns maxed for the resolution and -threads set to the CPU thread count divided
  by -j. That keeps far more cores busy than the libvpx defaults, but a single 1080p encode
  still cannot use every thread of a 32-thread CPU. To fill it, encode several clips at once:
  -r -c -j 3 (3 clips at a time, about 10 threads each), or -j 3 on a batch of separate files.
  Encoding is slow (CRF mode, cpu-used 2): expect well under realtime, so use -r on long jobs.
  --cpu-used N (0 to 5) trades speed for compression: each step up is roughly 1.5 to 2 times
  faster and gives a slightly bigger or softer file at the same CRF. The default is 2.

job queue (--queue-add, --queue-run):
  Lines up conversions and runs them one after another, so no bash loop is needed.
    tovinci --queue-add -t vp9-hq -sa clip1.mov ../Other/clip2.mov /full/path/clip3.mov
    tovinci --queue-run
  --queue-add takes the normal options and inputs. Inputs may be in the current folder, a
  relative path or a full path. Every input file becomes its own job, or all of them become
  one job with -c. A job runs as if you had cd'd into the folder of its input (the first one
  with -c), so the outputs land next to the source unless -o is given. Relative -o and
  --work-dir paths are made absolute when the job is added.
  --queue-run works through the jobs in the order they were added. When a job ends, its slot
  waits 15 seconds (--queue-gap SECONDS) so the output is completely written, then the next
  job starts. Jobs added while it runs are picked up. A failed job is marked and the queue
  carries on, unless --queue-stop-on-error is given. Ctrl-C stops the queue; the jobs that
  were running go back to waiting, and with -r in their options they resume where they left
  off on the next --queue-run.
  -j goes with --queue-add and is stored per job. For separate files, -j 2 lets two of those
  jobs run at the same time (each gets half of the CPU threads). With -c -r, it is the number
  of clips encoded at once within that one combine job, exactly as without the queue.
  Only one folder is worked on at a time: jobs in the same folder may run side by side up to
  their -j, but a job in another folder waits until every job in the current folder has
  finished (plus the gap). That also holds for a plain tovinci run you started yourself in
  another folder: the queue does not touch a second folder until that run is over.
  --queue-list shows the jobs, --queue-clear removes finished ones, --queue-remove ID removes
  one. The queue lives in ~/.local/state/tovinci (or $XDG_STATE_HOME/tovinci), never under
  /mnt/Data. Only one runner works on the queue at a time.

output location (-o):
  -o DIR puts every output file (the converted video, JPEG or WAV, split audio WAVs, and the
  combined file) in DIR, which is created if it does not exist. Without -o, outputs go in the
  current directory as before. The in-progress .partial files used by -r live in DIR as well,
  so the final rename is instant. Resume data and dry-run samples stay in the work directory
  (default ~/.cache/tovinci), not in DIR. In a batch, two inputs that would produce the same
  output name (same file name in different folders) are refused, so nothing is overwritten.
"""


class ToolError(Exception):
    """A user-facing error: printed without a traceback."""


@dataclass
class Options:
    verbose: int = 0
    target_type: str = ""
    quality: str = ""
    bits: str | None = None
    cpu_used: int | None = None  # VP9 -cpu-used override; None means VP9_CPU_USED
    threaded: bool = False
    jobs: int = 1
    gpu_requested: bool = False
    combine: bool = False
    combine_name: str = ""
    no_convert: bool = False
    combine_audio: bool = False
    split_audio: bool = False
    resumable: bool = False
    keep_order: bool = False
    restart: bool = False
    keep_work: bool = False
    work_dir: Path | None = None
    dry_run: bool = False
    output_dir: Path | None = None
    default_target: str = "dnxhr"  # video type used when -t is not given (DEFAULT_VIDEO_TYPE)
    default_quality: str = ""
    queue_action: str = ""           # add, run, list, clear, remove, or "" for a normal run
    queue_remove_id: int | None = None
    queue_gap: int | None = None
    queue_stop: bool = False
    option_argv: list = field(default_factory=list)  # the options as typed, for --queue-add


@dataclass
class Gpu:
    backend: str = ""
    device: str = ""


@dataclass
class Plan:
    pre: list
    inp: list
    outputs: list  # list of (output_args, output_path); the first is the main output


# ---------------------------------------------------------------- logging ---

class Logger:
    _lock = threading.Lock()

    def __init__(self, path: Path, verbose: int, prefix: str = ""):
        self.path = path
        self.verbose = verbose
        self.prefix = prefix

    def child(self, prefix: str) -> "Logger":
        return Logger(self.path, self.verbose, prefix)

    def _emit(self, msg: str, to_terminal: bool) -> None:
        line = f"{self.prefix}{msg}"
        with Logger._lock:
            try:
                with open(self.path, "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
            except OSError:
                pass
            if to_terminal:
                print(line, flush=True)

    def log(self, msg: str) -> None:
        self._emit(msg, self.verbose >= 1)

    def notify(self, msg: str) -> None:
        self._emit(msg, True)

    def append_raw(self, lines: list) -> None:
        with Logger._lock:
            try:
                with open(self.path, "a", encoding="utf-8") as fh:
                    for ln in lines:
                        fh.write(ln + "\n")
            except OSError:
                pass


def setup_log_path() -> Path:
    primary = Path(os.environ.get("HOME") or "/tmp") / "tovinci.log"
    try:
        primary.touch()
        return primary
    except OSError:
        fallback = Path("/tmp/tovinci.log")
        print(f"Warning: could not write to '{primary}', logging to '{fallback}' instead.",
              file=sys.stderr)
        try:
            fallback.touch()
        except OSError:
            pass
        return fallback


def rotate_log(path: Path) -> None:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    if sum(1 for ln in text.splitlines() if ln.startswith(RUN_MARKER)) >= 3:
        try:
            path.unlink()
            path.touch()
        except OSError:
            pass


def tail_log(path: Path, n: int = 10) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(lines[-n:])


# ---------------------------------------------------------- small helpers ---

def ext_of(name: str) -> str:
    return os.path.splitext(name)[1].lstrip(".").lower()


def has_media_ext(arg: str) -> bool:
    return "." in arg and ext_of(arg) in MEDIA_EXTS


def is_image_ext(arg: str) -> bool:
    return ext_of(arg) in IMAGE_EXTS


def has_glob_chars(arg: str) -> bool:
    return any(c in arg for c in "*?[")


def looks_like_name(arg: str) -> bool:
    """True if the argument after -c is the optional output name, not an input."""
    if arg.startswith("-"):
        return False
    if os.path.isfile(arg):
        return False
    if has_glob_chars(arg):
        return False
    if has_media_ext(arg):
        return False
    return True


def get_file_size(path: str) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def temp_name(path: str) -> str:
    root, ext = os.path.splitext(path)
    return f"{root}.partial{ext}"


def natural_key(path: str) -> tuple:
    """Sort key that orders numbers by value (clip 2 before clip 10)."""
    parts = re.split(r"(\d+)", path)
    return ([int(p) if i % 2 else p.casefold() for i, p in enumerate(parts)], path)


def order_for_combine(files: list, opts: Options, logger: "Logger") -> list:
    """Natural-sort the clips unless --keep-order was given. Shell globs sort as
    plain text (1, 10, 2, ...), which would put clip 10 right after clip 1."""
    if opts.keep_order:
        return files
    ordered = sorted(files, key=natural_key)
    if ordered != files:
        logger.notify("Note: clips were reordered into natural order (1, 2, ... 10) instead of the order "
                      "received. Use --keep-order to combine in exactly the order given.")
    return ordered


def discard(paths: list) -> None:
    for p in paths:
        try:
            os.remove(p)
        except OSError:
            pass


def quote_for_concat(path: str) -> str:
    return path.replace("'", "'\\''")


def eff_target(opts: Options) -> str:
    """Video type in effect: the -t type, or the default type when -t was not given."""
    return opts.target_type or opts.default_target


def eff_quality(opts: Options) -> str:
    """Quality variant (small, hq, a ProRes profile...) that goes with eff_target()."""
    return opts.quality if opts.target_type else opts.default_quality


def video_ext(opts: Options) -> str:
    """Container extension for converted video output."""
    target = eff_target(opts)
    if target == "vp9":
        return "mkv"
    return "mp4" if target == "mp4" else "mov"


def human_size(num: float) -> str:
    """Bytes as a short human-readable string (binary units)."""
    value = float(num)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(value) < 1024 or unit == "TiB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.2f} {unit}"
        value /= 1024
    return f"{value:.2f} TiB"


def human_duration(seconds: float) -> str:
    total = int(round(seconds))
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h:d}:{m:02d}:{s:02d}"


# ------------------------------------------------------- output location ---

def out_stem(name: str, opts: Options) -> str:
    """Place an output stem (no extension) inside the output directory, if one was given."""
    if opts.output_dir is None:
        return name
    return str(opts.output_dir / name)


def default_stem(input_file: str, opts: Options) -> str:
    """Default output stem for a single converted file: <name>_davinci in the output location."""
    return out_stem(f"{os.path.splitext(os.path.basename(input_file))[0]}_davinci", opts)


def existing_parent(path: Path) -> Path:
    """Nearest parent of path that exists (used for free-space checks on a directory
    that has not been created yet)."""
    p = path.absolute()
    while not p.exists() and p != p.parent:
        p = p.parent
    return p


def prepare_output_dir(opts: Options) -> None:
    """Create the output directory if needed and make sure it can be written to."""
    d = opts.output_dir
    if d is None:
        return
    if d.exists() and not d.is_dir():
        raise ToolError(f"--output-dir '{d}' exists but is not a directory.")
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ToolError(f"could not create output directory '{d}': {exc}")
    if not os.access(d, os.W_OK):
        raise ToolError(f"output directory '{d}' is not writable.")


def check_output_collisions(files: list, opts: Options) -> None:
    """With a shared output directory, two inputs with the same file name from different
    folders would overwrite each other. Refuse before encoding anything."""
    if opts.output_dir is None:
        return
    seen: dict = {}
    for f in files:
        key = (os.path.splitext(os.path.basename(f))[0], "image" if is_image_ext(f) else "av")
        if key in seen and os.path.abspath(seen[key]) != os.path.abspath(f):
            raise ToolError(f"'{seen[key]}' and '{f}' would both write to the same output name in "
                            f"'{opts.output_dir}'. Convert them separately or rename one.")
        seen.setdefault(key, f)


# ----------------------------------------------------------------- probing ---

def ffprobe(*args: str) -> str:
    try:
        res = subprocess.run(["ffprobe", "-v", "error", *args],
                             capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        raise ToolError("ffprobe was not found in PATH.")
    return res.stdout.strip() if res.returncode == 0 else ""


def probe_value(path: str, stream: str, entries: str) -> str:
    return ffprobe("-select_streams", stream, "-show_entries", f"stream={entries}",
                   "-of", "default=nk=1:nw=1", path)


def probe_duration(path: str) -> float:
    """Container duration in seconds, or 0.0 if it cannot be read."""
    out = ffprobe("-show_entries", "format=duration", "-of", "default=nk=1:nw=1", path)
    try:
        return max(float(out), 0.0)
    except ValueError:
        return 0.0


def count_audio(path: str) -> int:
    out = ffprobe("-select_streams", "a", "-show_entries", "stream=index",
                  "-of", "csv=p=0", path)
    return len([ln for ln in out.splitlines() if ln.strip()])


def stream_signature(path: str) -> str:
    video = ffprobe("-select_streams", "v:0", "-show_entries",
                    "stream=codec_name,width,height,pix_fmt,r_frame_rate", "-of", "csv=p=0", path)
    audio = ffprobe("-select_streams", "a", "-show_entries",
                    "stream=codec_name,sample_rate,channels", "-of", "csv=p=0", path)
    return video + "\n" + audio


def pcm_codec_for_track(path: str, idx: int, bits_override: str | None) -> str:
    """PCM codec for audio track idx: forced depth wins, else match the source.

    Lossy sources (AAC, MP3, Opus, Vorbis...) decode to float and map to 16-bit.
    """
    if bits_override:
        return f"pcm_s{bits_override}le"

    info = {}
    out = ffprobe("-select_streams", f"a:{idx}", "-show_entries",
                  "stream=codec_name,sample_fmt,bits_per_raw_sample",
                  "-of", "default=noprint_wrappers=1", path)
    for line in out.splitlines():
        if "=" in line:
            key, val = line.split("=", 1)
            info[key] = val
    codec = info.get("codec_name", "")
    fmt = info.get("sample_fmt", "")
    raw = info.get("bits_per_raw_sample", "")

    if raw.isdigit() and int(raw) > 0:
        raw_bits = int(raw)
        bits = 16 if raw_bits <= 16 else 24 if raw_bits <= 24 else 32
    elif fmt in ("u8", "u8p", "s16", "s16p"):
        bits = 16
    elif fmt in ("s32", "s32p"):
        bits = 32
    elif fmt in ("flt", "fltp", "dbl", "dblp"):
        bits = 32 if codec.startswith("pcm_f") else 16
    else:
        bits = 16
    return f"pcm_s{bits}le"


# ------------------------------------------------------------- audio args ---

def set_audio_codec_args(kind: str, path: str, audio_count: int, opts: Options, log) -> list:
    """Codec args matching the source depth per track (or the forced depth).

    mp4 video output uses AAC instead, since PCM does not belong in an mp4, and vp9
    video output uses lossless ALAC.
    """
    if kind == "video" and eff_target(opts) == "mp4":
        args = ["-c:a", "aac", "-b:a", MP4_AUDIO_BITRATE]
        log(f"mp4 output uses AAC audio at {MP4_AUDIO_BITRATE}: {' '.join(args)}")
        return args

    if kind == "video" and eff_target(opts) == "vp9":
        args = ["-c:a", "alac"]
        if opts.bits:
            log(f"vp9 output uses ALAC audio, so --bits {opts.bits} is ignored: {' '.join(args)}")
        else:
            log(f"vp9 output uses lossless ALAC audio: {' '.join(args)}")
        return args

    if kind == "video" and audio_count > 1 and not opts.combine_audio:
        args = []
        for i in range(audio_count):
            args += [f"-c:a:{i}", pcm_codec_for_track(path, i, opts.bits)]
    else:
        args = ["-c:a", pcm_codec_for_track(path, 0, opts.bits)]

    if opts.bits:
        log(f"Audio bit depth forced to {opts.bits}-bit: {' '.join(args)}")
    else:
        log(f"Audio bit depth matched to source: {' '.join(args)}")
    return args


def build_audio_args(kind: str, path: str, audio_count: int, opts: Options, log) -> list:
    """Audio stream selection. Default keeps tracks separate, -ca mixes them."""
    if audio_count > 1:
        if opts.combine_audio:
            filt = "".join(f"[0:a:{i}]" for i in range(audio_count))
            # normalize=0 keeps each track at its original level.
            filt += f"amix=inputs={audio_count}:duration=longest:normalize=0[aout]"
            log(f"Combine-audio enabled. Mixing {audio_count} audio tracks into one stereo track.")
            return ["-filter_complex", filt, "-map", "[aout]", "-ac", "2"]
        if kind == "video":
            log(f"{audio_count} audio tracks detected. Keeping them as separate tracks (use -ca to mix them into one).")
            return ["-map", "0:a"]
        print(f"Warning: '{path}' has {audio_count} audio tracks but WAV output holds only one. "
              "Using the first track (use -ca to mix them all, or -sa to write one WAV per track).",
              file=sys.stderr)
        log(f"Audio-only output holds a single stream. Using the first of {audio_count} audio tracks.")
        return ["-map", "0:a:0"]

    args = ["-map", "0:a:0"]
    if opts.combine_audio:
        channels = ffprobe("-select_streams", "a:0", "-show_entries", "stream=channels",
                           "-of", "default=nk=1:nw=1", path)
        if channels.isdigit() and int(channels) > 2:
            log(f"Combine-audio enabled. Downmixing {channels} channels to stereo.")
            args += ["-ac", "2"]
        else:
            log(f"Combine-audio enabled, but there is only one audio track with {channels} channel(s). Nothing to mix.")
    return args


def build_split_outputs(start: int, stem: str, path: str, audio_count: int,
                        opts: Options, log) -> list:
    """One extra WAV output per audio track, named <stem>_a1.wav, <stem>_a2.wav, ..."""
    outputs = []
    for i in range(start, audio_count):
        wav = f"{stem}_a{i + 1}.wav"
        codec = pcm_codec_for_track(path, i, opts.bits)
        log(f"Split track {i + 1} -> '{wav}' ({codec})")
        outputs.append((["-map", f"0:a:{i}", "-c:a", codec], wav))
    return outputs


# ------------------------------------------------------------------- GPU ---

def detect_gpu() -> Gpu | None:
    """Pick a usable GPU decode backend. ffmpeg has no GPU DNxHR encoder, so this
    only speeds up decoding the source; the encode stays on the CPU."""
    try:
        res = subprocess.run(["ffmpeg", "-hide_banner", "-hwaccels"], capture_output=True,
                             text=True, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return None
    available = {ln.strip() for ln in res.stdout.splitlines()[1:]}
    render_node = "/dev/dri/renderD128"
    if "cuda" in available and shutil.which("nvidia-smi"):
        return Gpu("cuda")
    if "vaapi" in available and os.path.exists(render_node):
        return Gpu("vaapi", render_node)
    if "qsv" in available and os.path.exists(render_node):
        return Gpu("qsv")
    return None


# -------------------------------------------------------------- planning ---

def build_plan(input_file: str, stem: str | None, opts: Options, gpu: Gpu | None, log,
               concat_list: str | None = None, size_override: int | None = None) -> Plan:
    """Probe input_file and work out the ffmpeg arguments and output files."""
    log(f"Analyzing '{input_file}'...")

    if stem is None:
        stem = default_stem(input_file, opts)

    pre: list = []
    if concat_list:
        log(f"Combined input: stream settings are probed from '{input_file}', clips are read via concat list.")
        inp = ["-f", "concat", "-safe", "0", "-i", concat_list]
    else:
        inp = ["-i", input_file]

    is_image = ext_of(input_file) in IMAGE_EXTS
    file_size = size_override if size_override is not None else get_file_size(input_file)
    use_threads = opts.threaded or file_size >= AUTO_THREAD_BYTES
    thread_count = os.cpu_count() or 1
    audio_count = 0 if is_image else count_audio(input_file)

    if is_image:
        log("Image file detected. Automagically configuring for DaVinci Resolve image compatibility...")
        log("Converting to high-quality JPEG...")
        # Single-frame encode: threading does not help here.
        return Plan(pre, inp, [(["-pix_fmt", "yuvj420p", "-q:v", "2", "-update", "1"], f"{stem}.jpg")])

    if opts.target_type == "wav":
        # Explicit audio-only: ignore any video stream (e.g. cover art in an mp3).
        if probe_value(input_file, "a:0", "codec_type") != "audio":
            raise ToolError(f"-t wav specified but no audio stream found in '{input_file}'.")
        log("Forced audio-only mode (-t wav). Automagically configuring for DaVinci Resolve Linux audio compatibility...")
        return Plan(pre, inp, audio_only_outputs(input_file, stem, audio_count, opts, log, drop_video=True))

    has_video = probe_value(input_file, "v:0", "codec_type")
    has_audio = probe_value(input_file, "a:0", "codec_type")

    if not has_video and has_audio == "audio":
        if opts.target_type in ("mp4", "prores", "vp9"):
            log(f"No video stream in '{input_file}', so the -t {opts.target_type} video type does not apply. Writing WAV instead.")
        log("Sole audio file detected. Automagically configuring for DaVinci Resolve Linux audio compatibility...")
        return Plan(pre, inp, audio_only_outputs(input_file, stem, audio_count, opts, log, drop_video=False))

    pix_fmt = probe_value(input_file, "v:0", "pix_fmt")
    log(f"Detected source pixel format: {pix_fmt}")

    target = eff_target(opts)
    quality = eff_quality(opts)
    high_depth = "10" in pix_fmt or "12" in pix_fmt or "le" in pix_fmt

    if target == "mp4":
        crf = MP4_CRF_SMALL if quality == "small" else MP4_CRF
        log(f"Transcoding to H.264 (CRF {crf}) in an mp4 container...")
        args = ["-map", "0:v:0", "-c:v", "libx264", "-preset", "medium", "-crf", crf,
                "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    elif target == "prores":
        number, label = PRORES_PROFILES[quality or "hq"]
        log(f"Transcoding to {label} (10-bit 4:2:2) in a mov container...")
        args = ["-map", "0:v:0", "-c:v", "prores_ks", "-profile:v", number, "-vendor", "apl0",
                "-pix_fmt", "yuv422p10le"]
    elif target == "vp9":
        crf = VP9_CRF_HQ if quality == "hq" else VP9_CRF
        vp9_pix = "yuv420p10le" if high_depth else "yuv420p"
        cpu_used = str(opts.cpu_used) if opts.cpu_used is not None else VP9_CPU_USED
        log(f"Transcoding to VP9 (CRF {crf}, cpu-used {cpu_used}, {vp9_pix}) in an mkv container...")
        # -b:v 0 makes -crf a pure constant-quality mode. Without -row-mt 1 libvpx only
        # parallelizes across tile columns, so a 1080p encode would crawl on a few threads.
        args = ["-map", "0:v:0", "-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0",
                "-row-mt", "1", "-tile-columns", VP9_TILE_COLUMNS, "-cpu-used", cpu_used,
                "-pix_fmt", vp9_pix]
    elif high_depth:
        log("High bit-depth detected. Transcoding to 10-bit DNxHR HQX...")
        args = ["-map", "0:v:0", "-c:v", "dnxhd", "-profile:v", "dnxhr_hqx", "-pix_fmt", "yuv422p10le"]
    else:
        log("Standard bit-depth detected. Transcoding to 8-bit DNxHR HQ...")
        args = ["-map", "0:v:0", "-c:v", "dnxhd", "-profile:v", "dnxhr_hq", "-pix_fmt", "yuv422p"]

    if target == "vp9":
        # Always set explicitly (not only for --threaded or big inputs) and share the CPU
        # between concurrent encodes (-j), so the encoders do not fight over the same threads.
        jobs = 1 if opts.dry_run else max(1, opts.jobs)
        vp9_threads = max(1, thread_count // jobs)
        log(f"VP9 row-mt enabled with {vp9_threads} encoder threads ({thread_count} CPU threads, {jobs} job(s)).")
        args += ["-threads", str(vp9_threads)]
    elif use_threads:
        if opts.threaded:
            log(f"Threaded mode forced (--threaded). Using {thread_count} encoder threads.")
        else:
            log(f"File size ({file_size} bytes) exceeds 10GB threshold. Automagically enabling {thread_count} encoder threads...")
        args += ["-threads", str(thread_count)]

    if gpu is not None:
        log(f"Using GPU-accelerated ({gpu.backend}) decode for the source file. Encode + threading above still run on CPU.")
        if gpu.backend == "cuda":
            pre = ["-hwaccel", "cuda"]
        elif gpu.backend == "vaapi":
            pre = ["-vaapi_device", gpu.device, "-hwaccel", "vaapi"]
        elif gpu.backend == "qsv":
            pre = ["-hwaccel", "qsv"]

    extras: list = []
    if has_audio == "audio":
        if opts.split_audio and audio_count > 1:
            log(f"Split-audio enabled. Video-only .{video_ext(opts)} plus one WAV per audio track ({audio_count} tracks).")
            args.append("-an")
            extras = build_split_outputs(0, stem, input_file, audio_count, opts, log)
        else:
            if target == "mp4":
                log("Audio stream detected. Encoding it as AAC.")
            elif target == "vp9":
                log("Audio stream detected. Encoding it as ALAC (lossless).")
            else:
                log("Audio stream detected. Retaining uncompressed audio.")
            sel = build_audio_args("video", input_file, audio_count, opts, log)
            codec = set_audio_codec_args("video", input_file, audio_count, opts, log)
            args += sel + codec
    else:
        log("No audio stream detected. Stripping audio track.")
        args.append("-an")

    return Plan(pre, inp, [(args, f"{stem}.{video_ext(opts)}")] + extras)


def audio_only_outputs(input_file: str, stem: str, audio_count: int, opts: Options, log,
                       drop_video: bool) -> list:
    """Outputs for audio-only conversion. -vn drops attached pictures that the WAV muxer rejects."""
    vn = ["-vn"] if drop_video else []
    codec = set_audio_codec_args("audio", input_file, audio_count, opts, log)
    if opts.split_audio and audio_count > 1:
        log(f"Split-audio enabled. Writing each of the {audio_count} audio tracks as its own WAV.")
        main = (vn + ["-map", "0:a:0"] + codec, f"{stem}_a1.wav")
        return [main] + build_split_outputs(1, stem, input_file, audio_count, opts, log)
    sel = build_audio_args("audio", input_file, audio_count, opts, log)
    return [(vn + sel + codec, f"{stem}.wav")]


# ------------------------------------------------------------- execution ---

def run_ffmpeg(args: list, opts: Options, logger: Logger) -> int:
    """Run ffmpeg honoring -v/-vv. -nostdin stops stray keypresses from reaching ffmpeg."""
    base = ["ffmpeg", "-y", "-nostdin"]
    if opts.verbose >= 2:
        pass  # full live output
    elif opts.verbose == 1:
        # -stats is explicit because ffmpeg hides live progress when output is piped.
        base += ["-hide_banner", "-loglevel", "error", "-stats"]
    else:
        base += ["-loglevel", "error"]
    cmd = base + args

    try:
        if opts.verbose == 0:
            with open(logger.path, "a", encoding="utf-8") as fh:
                return subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=fh,
                                      stderr=subprocess.STDOUT).returncode

        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, bufsize=0)
    except FileNotFoundError:
        raise ToolError("ffmpeg was not found in PATH.")

    fd = proc.stdout.fileno()
    buf = ""
    try:
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            text = chunk.decode("utf-8", "replace")
            sys.stdout.write(text)
            sys.stdout.flush()
            buf += text
            *lines, buf = buf.split("\n")
            # Progress updates use \r; the log keeps only the last one per line.
            logger.append_raw([ln.rsplit("\r", 1)[-1] for ln in lines])
        if buf:
            logger.append_raw([buf.rsplit("\r", 1)[-1]])
        return proc.wait()
    except BaseException:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        raise


def encode(plan: Plan, opts: Options, logger: Logger, label: str, use_temp: bool) -> int:
    """Run one ffmpeg pass for a plan. With use_temp, outputs are written as
    <name>.partial<ext> and only renamed once ffmpeg succeeds, so an interrupted
    run never leaves something that looks finished."""
    finals = [p for _, p in plan.outputs]
    targets = [temp_name(p) for p in finals] if use_temp else finals

    def assemble(pre: list) -> list:
        args = list(pre) + list(plan.inp)
        for (oargs, _), target in zip(plan.outputs, targets):
            args += list(oargs) + [target]
        return args

    logger.log("Running FFmpeg command...")
    logger.log(shlex.join(["ffmpeg"] + assemble(plan.pre)))
    logger.log(RULE)

    try:
        status = run_ffmpeg(assemble(plan.pre), opts, logger)
        if status != 0 and plan.pre:
            # GPU decode failed (unsupported codec, driver issue...). Retry once on CPU.
            logger.log(f"GPU-accelerated decode failed (exit code {status}) for '{label}'. Retrying with CPU decode...")
            status = run_ffmpeg(assemble([]), opts, logger)
    except BaseException:
        if use_temp:
            discard(targets)
        raise

    if status != 0:
        if use_temp:
            discard(targets)
        print(f"Error: ffmpeg failed (exit code {status}) while processing '{label}'.", file=sys.stderr)
        if opts.verbose < 2:
            print("Last few lines of ffmpeg output:", file=sys.stderr)
            print(tail_log(logger.path), file=sys.stderr)
        print(f"Full details: {logger.path}", file=sys.stderr)
        return status

    logger.log(RULE)
    if use_temp:
        for tmp, final in zip(targets, finals):
            os.replace(tmp, final)
    return 0


def announce_outputs(plan: Plan, logger: Logger) -> None:
    logger.notify(f"Done! Highly compatible file created: '{plan.outputs[0][1]}'")
    for _, path in plan.outputs[1:]:
        logger.notify(f"Done! Separate audio track created: '{path}'")


# ----------------------------------------------------------- resume state ---

def job_key(inputs: list, stem: str, opts: Options) -> str:
    items = []
    for f in inputs:
        st = os.stat(f)
        items.append([os.path.abspath(f), st.st_size, st.st_mtime_ns])
    key_opts = {"bits": opts.bits, "ca": opts.combine_audio, "sa": opts.split_audio,
                "t": eff_target(opts), "q": eff_quality(opts), "nc": opts.no_convert}
    if eff_target(opts) == "vp9" and opts.cpu_used is not None:
        key_opts["cpu"] = opts.cpu_used  # different speed setting, different parts
    payload = json.dumps({
        "inputs": items,
        "stem": os.path.abspath(stem),
        "opts": key_opts,
        "v": 1,
    }, sort_keys=True)
    return hashlib.sha1(payload.encode()).hexdigest()[:16]


def state_root(opts: Options) -> Path:
    """Directory for resume data. Never allowed under /mnt/Data."""
    if opts.work_dir is not None:
        root = opts.work_dir.expanduser()
    else:
        base = os.environ.get("XDG_CACHE_HOME")
        root = (Path(base) if base else Path.home() / ".cache") / "tovinci"
    real = os.path.realpath(root)
    if real == FORBIDDEN_CACHE_ROOT or real.startswith(FORBIDDEN_CACHE_ROOT + os.sep):
        raise ToolError(f"resume data must not live under {FORBIDDEN_CACHE_ROOT} (got '{root}'). "
                        "Use --work-dir to pick a location on the primary drive.")
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ToolError(f"could not create work directory '{root}': {exc}")
    return root


def note_work_dir(root: Path, logger: Logger) -> None:
    try:
        free = shutil.disk_usage(root).free / (1024 ** 3)
        logger.notify(f"Resume data: {root} ({free:.0f} GiB free). Peak use is about twice the final output.")
    except OSError:
        logger.notify(f"Resume data: {root}")


# --------------------------------------------------------------- dry run ---

def encode_sample(plan: Plan, pos: float | None, length: float | None, opts: Options,
                  logger: Logger, tmp: str, tag: str) -> int | None:
    """Encode one short window of a clip with the plan's exact settings and return the
    total bytes written across all of the plan's outputs (None on failure). The sample
    files go into tmp and are deleted right away."""
    targets = []
    for j, (_, final) in enumerate(plan.outputs):
        targets.append(os.path.join(tmp, f"{tag}_{j}{os.path.splitext(final)[1]}"))

    def assemble(pre: list) -> list:
        args = list(pre)
        if pos is not None:
            args += ["-ss", f"{pos:.3f}"]
        args += list(plan.inp)
        for (oargs, _), target in zip(plan.outputs, targets):
            if length is not None:
                args += ["-t", f"{length:.3f}"]
            args += list(oargs) + [target]
        return args

    logger.log(shlex.join(["ffmpeg"] + assemble(plan.pre)))
    try:
        status = run_ffmpeg(assemble(plan.pre), opts, logger)
        if status != 0 and plan.pre:
            logger.log(f"GPU-accelerated decode failed (exit code {status}) during sampling. Retrying with CPU decode...")
            status = run_ffmpeg(assemble([]), opts, logger)
    except BaseException:
        discard(targets)
        raise

    size = sum(get_file_size(t) for t in targets) if status == 0 else None
    discard(targets)
    return size


def sample_positions(duration: float) -> list | None:
    """Start times for the sample windows, or None if the clip is short enough to
    just encode in full (which makes its estimate exact)."""
    if duration <= DRY_RUN_WINDOWS * DRY_RUN_SECONDS * 2:
        return None
    span = duration - DRY_RUN_SECONDS
    if DRY_RUN_WINDOWS == 1:
        return [span / 2]
    return [span * i / (DRY_RUN_WINDOWS - 1) for i in range(DRY_RUN_WINDOWS)]


def estimate_clip(clip: str, opts: Options, gpu: Gpu | None, logger: Logger, tmp: str,
                  tag: str, size_override: int | None) -> dict:
    """Estimate the output size for one clip. Returns a dict with keys: bytes (or None),
    duration, exact (bool) and note (str)."""
    plan = build_plan(clip, "sample", opts, gpu, logger.log, size_override=size_override)

    if is_image_ext(clip):
        size = encode_sample(plan, None, None, opts, logger, tmp, tag)
        return {"bytes": size, "duration": 0.0, "exact": True,
                "note": "" if size is not None else "image conversion failed"}

    duration = probe_duration(clip)
    if duration <= 0:
        return {"bytes": None, "duration": 0.0, "exact": False,
                "note": "could not read the duration"}

    positions = sample_positions(duration)
    if positions is None:
        size = encode_sample(plan, None, None, opts, logger, tmp, tag)
        return {"bytes": size, "duration": duration, "exact": True,
                "note": "" if size is not None else "sample encode failed"}

    total_bytes = 0
    total_secs = 0.0
    for n, pos in enumerate(positions):
        size = encode_sample(plan, pos, DRY_RUN_SECONDS, opts, logger, tmp, f"{tag}_{n}")
        if size is None:
            return {"bytes": None, "duration": duration, "exact": False,
                    "note": "sample encode failed"}
        total_bytes += size
        total_secs += DRY_RUN_SECONDS
    return {"bytes": total_bytes / total_secs * duration, "duration": duration,
            "exact": False, "note": ""}


def run_dry_run(files: list, opts: Options, gpu: Gpu | None, logger: Logger, combine: bool) -> int:
    """Estimate output sizes without writing any output files."""
    count = len(files)
    total_in = sum(get_file_size(f) for f in files)

    if combine:
        for f in files:
            if is_image_ext(f):
                print(f"Error: -c/--combine only supports video/audio files, but '{f}' is an image.", file=sys.stderr)
                return 1
        ref_sig = stream_signature(files[0])
        for f in files[1:]:
            if stream_signature(f) != ref_sig:
                print(f"Warning: '{f}' does not match the stream layout of '{files[0]}'. A real combine "
                      "would fail on this.", file=sys.stderr)

    if combine and opts.no_convert:
        logger.notify("Dry run (nothing is written): --no-convert is a stream copy, so the combined file "
                      "will be about the size of the inputs.")
        report_dry_run([(f, {"bytes": get_file_size(f), "duration": probe_duration(f),
                             "exact": True, "note": ""}) for f in files], total_in, opts, combine)
        return 0

    logger.notify(f"Dry run (nothing is written): sampling {count} file(s), "
                  f"{DRY_RUN_WINDOWS} x {DRY_RUN_SECONDS:.0f}s per clip...")

    results: list = []
    root = state_root(opts)  # sample files stay on the primary drive, never under /mnt/Data
    size_override = total_in if combine else None
    with tempfile.TemporaryDirectory(prefix="dryrun-", dir=str(root)) as tmp:
        for idx, clip in enumerate(files):
            logger.notify(f"[{idx + 1}/{count}] Sampling '{clip}'...")
            try:
                res = estimate_clip(clip, opts, gpu, logger, tmp, f"c{idx:04d}", size_override)
            except ToolError as exc:
                print(f"Error: {exc}", file=sys.stderr)
                res = {"bytes": None, "duration": 0.0, "exact": False, "note": str(exc)}
            results.append((clip, res))

    report_dry_run(results, total_in, opts, combine)
    return 1 if any(r["bytes"] is None for _, r in results) else 0


def report_dry_run(results: list, total_in: int, opts: Options, combine: bool) -> None:
    print()
    print("Dry run estimate (no output files were created)")
    print(RULE)
    est_total = 0.0
    dur_total = 0.0
    unknown = 0
    all_exact = True
    for clip, res in results:
        name = os.path.basename(clip)
        if res["bytes"] is None:
            unknown += 1
            print(f"  {name}: unknown ({res['note']})")
            continue
        est_total += res["bytes"]
        dur_total += res["duration"]
        all_exact = all_exact and res["exact"]
        dur = human_duration(res["duration"]) if res["duration"] else "image"
        tag = "exact" if res["exact"] else "est."
        print(f"  {name}: {dur}  {human_size(res['bytes'])} ({tag})")
    print(RULE)

    if combine:
        print(f"Combined output: about {human_size(est_total)} "
              f"over {human_duration(dur_total)}")
    else:
        print(f"All outputs together: about {human_size(est_total)}")
    if total_in:
        ratio = est_total / total_in
        print(f"Inputs total: {human_size(total_in)} (output is about {ratio:.1f}x the input size)")
    if unknown:
        print(f"Note: {unknown} file(s) could not be estimated and are not included in the total.")
    if not all_exact:
        print("Estimates come from short samples; DNxHR is close to constant bitrate, while mp4, "
              "ProRes and VP9 vary with content.")

    try:
        target = opts.output_dir if opts.output_dir is not None else Path.cwd()
        free = shutil.disk_usage(existing_parent(target)).free
        where = f"'{opts.output_dir}'" if opts.output_dir is not None else "the current directory"
        print(f"Free space at {where}: {human_size(free)}")
        needed = est_total * 2 if (combine and opts.resumable and not opts.no_convert) else est_total
        if opts.resumable and combine and not opts.no_convert:
            print(f"With -r, peak disk use is about twice the output: roughly {human_size(needed)}.")
        if needed > free:
            print("Warning: this is more than the free space available there.")
    except OSError:
        pass


# ------------------------------------------------------------ single file ---

def process_file(path: str, opts: Options, gpu: Gpu | None, logger: Logger) -> int:
    """Convert one file. With -r, a file that already finished is skipped."""
    try:
        plan = build_plan(path, None, opts, gpu, logger.log)
    except ToolError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    if not opts.resumable:
        status = encode(plan, opts, logger, path, use_temp=False)
        if status == 0:
            announce_outputs(plan, logger)
        return status

    state = state_root(opts) / f"file-{job_key([path], plan.outputs[0][1], opts)}"
    done = state / "done.json"
    if opts.restart and state.exists():
        shutil.rmtree(state, ignore_errors=True)
    if done.exists() and all(os.path.exists(p) for _, p in plan.outputs):
        logger.notify(f"Already converted, skipping: '{path}' (use --restart to redo it)")
        return 0

    status = encode(plan, opts, logger, path, use_temp=True)
    if status == 0:
        state.mkdir(parents=True, exist_ok=True)
        done.write_text(json.dumps([p for _, p in plan.outputs]))
        announce_outputs(plan, logger)
    return status


# ---------------------------------------------------------------- combine ---

def abs_path(p: str) -> str:
    return os.path.join(os.path.realpath(os.path.dirname(p) or "."), os.path.basename(p))


def write_concat_list(list_path: Path, paths: list) -> None:
    with open(list_path, "w", encoding="utf-8") as fh:
        for p in paths:
            fh.write(f"file '{quote_for_concat(abs_path(p))}'\n")


def run_combine(files: list, opts: Options, gpu: Gpu | None, logger: Logger) -> int:
    first = files[0]
    first_name = os.path.basename(first)
    first_ext = ext_of(first_name)

    for f in files:
        if is_image_ext(f):
            print(f"Error: -c/--combine only supports video/audio files, but '{f}' is an image.", file=sys.stderr)
            return 1

    stem = out_stem(opts.combine_name or f"{os.path.splitext(first_name)[0]}_combined", opts)

    if opts.no_convert:
        out = f"{stem}.{first_ext}"
        candidates = [out]
    else:
        out = f"{stem}.{video_ext(opts)}"
        candidates = [f"{stem}.mov", f"{stem}.mp4", f"{stem}.mkv", f"{stem}.wav"] + [f"{stem}_a{n}.wav" for n in range(1, 5)]

    # Never overwrite one of the inputs.
    for cand in candidates:
        for f in files:
            if os.path.exists(cand) and os.path.samefile(cand, f):
                print(f"Error: the combined output '{cand}' would overwrite input file '{f}'. Pick a different name.",
                      file=sys.stderr)
                return 1

    # Concatenation needs matching codec, resolution, frame rate and audio layout.
    ref_sig = stream_signature(first)
    for f in files:
        if stream_signature(f) != ref_sig:
            print(f"Error: '{f}' does not match the stream layout of '{first}' (codec, resolution, pixel format, "
                  "frame rate, audio parameters, or number of audio tracks differ).", file=sys.stderr)
            print("All clips must share the same settings to be combined without re-encoding each one first.",
                  file=sys.stderr)
            return 1

    total_size = sum(get_file_size(f) for f in files)

    logger.log(f"Combining {len(files)} files into '{out}' (in this order):")
    for f in files:
        logger.log(f"  - {f}")

    if opts.no_convert:
        return combine_copy_only(files, out, opts, logger)

    if opts.resumable:
        return combine_resumable(files, stem, total_size, opts, gpu, logger)

    logger.log("Combining and converting to the target format in a single pass.")
    with tempfile.TemporaryDirectory(prefix="tovinci-") as tmp:
        list_file = Path(tmp) / "concat.txt"
        write_concat_list(list_file, files)
        try:
            plan = build_plan(first, stem, opts, gpu, logger.log, str(list_file), total_size)
        except ToolError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1
        status = encode(plan, opts, logger, first, use_temp=False)
    if status == 0:
        announce_outputs(plan, logger)
    return status


def combine_copy_only(files: list, out: str, opts: Options, logger: Logger) -> int:
    if opts.resumable:
        logger.log("--resumable has no effect with --no-convert (a stream copy is quick and not re-encoded).")
    logger.log("--no-convert set. Combining with stream copy only, no DaVinci conversion. All audio tracks are kept as-is.")
    with tempfile.TemporaryDirectory(prefix="tovinci-") as tmp:
        list_file = Path(tmp) / "concat.txt"
        write_concat_list(list_file, files)
        plan = Plan([], ["-f", "concat", "-safe", "0", "-i", str(list_file)],
                    [(["-map", "0:v?", "-map", "0:a?", "-c", "copy"], out)])
        status = encode(plan, opts, logger, "combine", use_temp=False)
    if status == 0:
        logger.notify(f"Done! Combined file created: '{out}'")
    return status


def combine_resumable(files: list, stem: str, total_size: int, opts: Options,
                      gpu: Gpu | None, logger: Logger) -> int:
    """Encode each clip to its own part in the work directory, then join the parts
    with a stream copy. A finished part is never encoded again."""
    root = state_root(opts)
    state = root / f"combine-{job_key(files, stem, opts)}"
    if opts.restart and state.exists():
        shutil.rmtree(state, ignore_errors=True)
    state.mkdir(parents=True, exist_ok=True)
    note_work_dir(root, logger)

    count = len(files)
    parts: list = [None] * count  # parts[k] = output paths of clip k, in plan order
    pending: list = []            # clips that still need encoding: (idx, clip, plan, marker, outs)
    failed = threading.Event()

    def encode_clip(item: tuple) -> int | None:
        """Encode one clip into its part files. None means it was skipped because an earlier
        clip already failed."""
        idx, clip, plan, marker, outs = item
        if failed.is_set():
            return None
        lg = logger.child(f"[{idx + 1}/{count}] ") if opts.jobs > 1 else logger
        logger.notify(f"[{idx + 1}/{count}] Encoding '{clip}'...")
        status = encode(plan, opts, lg, clip, use_temp=True)
        if status != 0:
            failed.set()
            return status
        marker.write_text(json.dumps(outs))
        return 0

    try:
        for idx, clip in enumerate(files):
            part_stem = str(state / f"part_{idx:04d}")
            marker = state / f"part_{idx:04d}.done.json"
            plan = build_plan(clip, part_stem, opts, gpu, logger.log, size_override=total_size)
            outs = [p for _, p in plan.outputs]
            parts[idx] = outs

            if marker.exists() and all(os.path.exists(p) for p in outs):
                logger.notify(f"[{idx + 1}/{count}] Already encoded, skipping: '{clip}'")
                continue
            pending.append((idx, clip, plan, marker, outs))

        if opts.jobs > 1 and len(pending) > 1:
            # Independent clips encode at the same time; each one gets its share of the CPU
            # threads (see build_plan). An interruption or failure stops clips not yet started.
            with ThreadPoolExecutor(max_workers=min(opts.jobs, len(pending))) as pool:
                try:
                    results = list(pool.map(encode_clip, pending))
                except BaseException:
                    failed.set()
                    raise
        else:
            results = []
            for item in pending:
                status = encode_clip(item)
                results.append(status)
                if status:
                    break

        bad = [r for r in results if r]
        if bad:
            print("Re-run the same command to resume; clips that already finished are kept.", file=sys.stderr)
            return bad[0]

        # Same output names as a normal combine, worked out without logging.
        final_plan = build_plan(files[0], stem, opts, gpu, lambda _m: None, size_override=total_size)
        finals = [p for _, p in final_plan.outputs]

        logger.notify("All clips encoded. Joining parts (stream copy)...")
        for j, final in enumerate(finals):
            list_file = state / f"concat_{j}.txt"
            write_concat_list(list_file, [part[j] for part in parts])
            join = Plan([], ["-f", "concat", "-safe", "0", "-i", str(list_file)],
                        [(["-map", "0", "-c", "copy"], final)])
            status = encode(join, opts, logger, final, use_temp=True)
            if status != 0:
                print("The encoded parts were kept. Re-run the same command to retry the join.", file=sys.stderr)
                return status
    except ToolError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    announce_outputs(final_plan, logger)
    if opts.keep_work:
        logger.notify(f"Work files kept in '{state}'.")
    else:
        shutil.rmtree(state, ignore_errors=True)
    return 0


# -------------------------------------------------------------------- CLI ---

class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        sys.exit(1)


def parse_bool(value: str) -> bool:
    low = value.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    raise argparse.ArgumentTypeError(f"must be true or false (got '{value}')")


def build_parser() -> Parser:
    p = Parser(prog="tovinci", allow_abbrev=False,
               formatter_class=argparse.RawDescriptionHelpFormatter,
               description="Convert media into DaVinci Resolve (Linux) friendly formats.",
               epilog=EXAMPLES)
    p.add_argument("-V", "--version", action="version", version=f"%(prog)s {VERSION}",
                   help="show the version and exit")
    p.add_argument("-v", dest="verbose", action="count", default=0,
                   help="-v: step log and brief ffmpeg progress; -vv: full live ffmpeg output")
    p.add_argument("-t", dest="target_type", default="", metavar="TYPE",
                   help=f"force an output type: {TYPE_CHOICES}")
    p.add_argument("--bits", default=None, metavar="N", help="force PCM audio bit depth: 16, 24 or 32")
    p.add_argument("--cpu-used", type=int, default=None, metavar="N", choices=range(0, 6),
                   help=f"VP9 only: speed/quality trade-off from 0 (best, slowest) to 5 (fastest); "
                        f"default {VP9_CPU_USED}")
    p.add_argument("--threaded", action="store_true", help="force multi-threaded encoding regardless of size")
    p.add_argument("-j", "--jobs", type=int, default=1, metavar="N",
                   help="process up to N files concurrently (with -r -c: encode N clips at once)")
    p.add_argument("--use-gpu", type=parse_bool, default=False, metavar="true|false",
                   help="decode on GPU if a backend is available (use as -use-gpu=true)")
    p.add_argument("-ca", "--combine-audio", action="store_true", help="mix all audio tracks into one stereo track")
    p.add_argument("-sa", "--split-audio", action="store_true",
                   help="video-only output plus one WAV per audio track")
    p.add_argument("-c", "--combine", action="store_true",
                   help="combine all inputs into one video first (use as: -c [NAME])")
    p.add_argument("--combine-name", default="", help=argparse.SUPPRESS)
    p.add_argument("--no-convert", action="store_true", help="with -c: only combine, skip DaVinci conversion")
    p.add_argument("--keep-order", action="store_true",
                   help="with -c: combine in exactly the order given (default: natural order, 1, 2, ... 10)")
    p.add_argument("-r", "--resumable", action="store_true",
                   help="make the run resumable: re-run the same command after an interruption")
    p.add_argument("--restart", action="store_true", help="with -r: discard saved progress and start over")
    p.add_argument("--keep-work", action="store_true", help="with -r: keep work files after a successful run")
    p.add_argument("--work-dir", type=Path, default=None, metavar="DIR",
                   help="with -r: where resume data lives (default ~/.cache/tovinci, never under /mnt/Data)")
    p.add_argument("-n", "--dry-run", action="store_true",
                   help="estimate the output size (per file, or combined with -c) from short samples "
                        "without writing any output files")
    p.add_argument("-o", "--output-dir", type=Path, default=None, metavar="DIR",
                   help="write all output files into DIR (created if missing); default is the current directory")
    p.add_argument("--queue-add", action="store_true",
                   help="add the given inputs and options to the job queue instead of converting now")
    p.add_argument("--queue-run", action="store_true",
                   help=f"run the queued jobs one after another, waiting {QUEUE_GAP_DEFAULT} seconds between them")
    p.add_argument("--queue-list", action="store_true", help="show the queued jobs")
    p.add_argument("--queue-clear", action="store_true", help="remove finished (done or failed) jobs from the queue")
    p.add_argument("--queue-remove", type=int, default=None, metavar="ID", help="remove one job from the queue")
    p.add_argument("--queue-gap", type=int, default=None, metavar="SECONDS",
                   help=f"with --queue-run: seconds to wait after each job (default {QUEUE_GAP_DEFAULT})")
    p.add_argument("--queue-stop-on-error", action="store_true",
                   help="with --queue-run: stop at the first failed job instead of carrying on")
    p.add_argument("inputs", nargs="*", metavar="file_or_pattern")
    return p


def preprocess_argv(argv: list) -> list:
    """Rewrite the options argparse cannot express: -c [NAME] and -use-gpu=VALUE."""
    out: list = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            out.extend(argv[i:])
            break
        if arg in ("-c", "--combine"):
            out.append("--combine")
            if i + 1 < len(argv) and looks_like_name(argv[i + 1]):
                out.append(f"--combine-name={argv[i + 1]}")
                i += 1
        elif arg.startswith("--combine="):
            out += ["--combine", f"--combine-name={arg.split('=', 1)[1]}"]
        elif arg.startswith("-use-gpu="):
            out.append("--use-gpu=" + arg.split("=", 1)[1])
        else:
            out.append(arg)
        i += 1
    return out


def default_video_type(parser: Parser) -> tuple:
    """(target, quality) for DEFAULT_VIDEO_TYPE, the video type used when -t is not given."""
    name = DEFAULT_VIDEO_TYPE
    if name in ("dnxhr", "mp4", "vp9"):
        return name, ""
    if name == "mp4-small":
        return "mp4", "small"
    if name == "vp9-hq":
        return "vp9", "hq"
    if name == "prores":
        return "prores", "hq"
    if name.startswith("prores-") and name.split("-", 1)[1] in PRORES_PROFILES:
        return "prores", name.split("-", 1)[1]
    parser.error(f"unsupported default video type '{name}' (DEFAULT_VIDEO_TYPE / TOVINCI_DEFAULT_TYPE). "
                 "Use one of: dnxhr, mp4, mp4-small, vp9, vp9-hq, prores, prores-hq, prores-422, "
                 "prores-lt, prores-proxy.")


def parse_args(argv: list) -> tuple:
    parser = build_parser()
    if not argv:
        parser.print_help()
        sys.exit(1)
    ns = parser.parse_intermixed_args(preprocess_argv(argv))

    target = ns.target_type.lower()
    quality = ""
    bits = ns.bits
    if target:
        if target == "wav":
            pass
        elif target in ("wav-16", "wav-24", "wav-32"):
            bits = target.split("-", 1)[1]
            target = "wav"
        elif target == "mp4":
            pass
        elif target == "mp4-small":
            target = "mp4"
            quality = "small"
        elif target == "prores":
            quality = "hq"
        elif target.startswith("prores-") and target.split("-", 1)[1] in PRORES_PROFILES:
            quality = target.split("-", 1)[1]
            target = "prores"
        elif target == "dnxhr":
            pass
        elif target == "vp9":
            pass
        elif target == "vp9-hq":
            target = "vp9"
            quality = "hq"
        else:
            parser.error(f"unsupported -t type '{ns.target_type}' (supported: {TYPE_CHOICES}).")
    if bits is not None and str(bits) not in ("16", "24", "32"):
        parser.error(f"bit depth must be 16, 24 or 32 (got '{bits}').")
    if target in ("mp4", "vp9") and bits is not None:
        codec_name = "AAC" if target == "mp4" else "ALAC"
        parser.error(f"--bits only applies to PCM audio, but {target} output uses {codec_name} audio.")
    if ns.jobs < 1:
        parser.error(f"-j/--jobs must be a positive integer (got '{ns.jobs}').")
    if ns.no_convert and not ns.combine:
        parser.error("--no-convert can only be used together with -c/--combine.")
    if ns.no_convert and target in ("mp4", "prores", "vp9", "dnxhr"):
        parser.error(f"-t {ns.target_type} cannot be used with --no-convert (the video would need to be re-encoded).")
    if ns.no_convert and ns.combine_audio:
        parser.error("-ca/--combine-audio cannot be used with --no-convert (mixing audio requires re-encoding it).")
    if ns.no_convert and ns.split_audio:
        parser.error("-sa/--split-audio cannot be used with --no-convert (splitting audio requires re-encoding it).")
    if ns.combine_audio and ns.split_audio:
        parser.error("-ca/--combine-audio and -sa/--split-audio contradict each other "
                     "(mix into one vs. one file per track).")
    if ns.no_convert and bits is not None:
        parser.error("a forced bit depth cannot be used with --no-convert (audio is stream-copied untouched).")
    if ns.keep_order and not ns.combine:
        parser.error("--keep-order can only be used together with -c/--combine.")
    if (ns.restart or ns.keep_work or ns.work_dir) and not ns.resumable:
        parser.error("--restart, --keep-work and --work-dir require -r/--resumable.")
    queue_choices = [name for name, on in (("add", ns.queue_add), ("run", ns.queue_run),
                                           ("list", ns.queue_list), ("clear", ns.queue_clear),
                                           ("remove", ns.queue_remove is not None)) if on]
    if len(queue_choices) > 1:
        parser.error("use only one of --queue-add, --queue-run, --queue-list, --queue-clear, --queue-remove.")
    queue_action = queue_choices[0] if queue_choices else ""
    if queue_action not in ("", "add") and ns.inputs:
        parser.error(f"--queue-{queue_action} does not take input files.")
    if (ns.queue_gap is not None or ns.queue_stop_on_error) and queue_action != "run":
        parser.error("--queue-gap and --queue-stop-on-error only apply together with --queue-run.")
    if queue_action not in ("", "add") and ns.jobs != 1:
        parser.error("-j is stored per job: give it with --queue-add (tovinci --queue-add -j 2 ...), "
                     f"not with --queue-{queue_action}.")
    if ns.queue_gap is not None and ns.queue_gap < 0:
        parser.error(f"--queue-gap cannot be negative (got '{ns.queue_gap}').")
    if not ns.inputs and queue_action in ("", "add"):
        parser.print_usage(sys.stderr)
        sys.exit(1)

    combine_name = ns.combine_name
    if combine_name and has_media_ext(combine_name):
        combine_name = os.path.splitext(combine_name)[0]

    output_dir = ns.output_dir.expanduser() if ns.output_dir is not None else None
    default_target, default_quality = default_video_type(parser)
    if ns.cpu_used is not None and (target or default_target) != "vp9":
        parser.error("--cpu-used only applies to VP9 output (-t vp9, -t vp9-hq, or a vp9 default type).")

    opts = Options(verbose=ns.verbose, target_type=target, quality=quality,
                   bits=str(bits) if bits is not None else None,
                   threaded=ns.threaded, jobs=ns.jobs, gpu_requested=ns.use_gpu, combine=ns.combine,
                   combine_name=combine_name, no_convert=ns.no_convert, combine_audio=ns.combine_audio,
                   split_audio=ns.split_audio, resumable=ns.resumable, keep_order=ns.keep_order,
                   restart=ns.restart,
                   keep_work=ns.keep_work, work_dir=ns.work_dir, dry_run=ns.dry_run,
                   output_dir=output_dir, default_target=default_target,
                   default_quality=default_quality, cpu_used=ns.cpu_used,
                   queue_action=queue_action, queue_remove_id=ns.queue_remove,
                   queue_gap=ns.queue_gap, queue_stop=ns.queue_stop_on_error,
                   option_argv=option_args(parser, ns) if queue_action == "add" else [])
    return opts, ns.inputs


def resolve_files(patterns: list) -> list:
    files: list = []
    for arg in patterns:
        if os.path.isfile(arg):
            files.append(arg)
        elif has_glob_chars(arg):
            matches = sorted(glob.glob(arg))
            if matches:
                files.extend(m for m in matches if os.path.isfile(m))
            else:
                print(f"Warning: pattern '{arg}' matched no files - skipping.", file=sys.stderr)
        else:
            print(f"Warning: file '{arg}' not found - skipping.", file=sys.stderr)
    return files


# ------------------------------------------------------------------ queue ---

def option_args(parser: Parser, ns: argparse.Namespace) -> list:
    """The options of this run as command-line tokens (inputs and queue options left out),
    so a queued job can later be run exactly as it was typed."""
    out: list = []
    for act in parser._actions:
        if not act.option_strings or act.dest in ("help", "version") or act.dest.startswith("queue_"):
            continue
        value = getattr(ns, act.dest, None)
        if value is None or value == act.default:
            continue
        longs = [o for o in act.option_strings if o.startswith("--")]
        name = longs[0] if longs else act.option_strings[0]
        if isinstance(act, argparse._CountAction):
            out += [act.option_strings[0]] * int(value)
        elif isinstance(act, argparse._StoreTrueAction):
            out.append(name)
        else:
            if act.dest in ("output_dir", "work_dir"):
                value = os.path.abspath(os.path.expanduser(str(value)))
            text = ("true" if value else "false") if isinstance(value, bool) else str(value)
            out += [f"{name}={text}"] if longs else [name, text]
    return out


def queue_root() -> Path:
    """Directory holding the queue. Never allowed under /mnt/Data."""
    base = os.environ.get("XDG_STATE_HOME")
    root = (Path(base) if base else Path.home() / ".local" / "state") / "tovinci"
    real = os.path.realpath(root)
    if real == FORBIDDEN_CACHE_ROOT or real.startswith(FORBIDDEN_CACHE_ROOT + os.sep):
        raise ToolError(f"the queue must not live under {FORBIDDEN_CACHE_ROOT} (got '{root}'). "
                        "Set XDG_STATE_HOME to a location on the primary drive.")
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ToolError(f"could not create the queue directory '{root}': {exc}")
    return root


@contextmanager
def queue_locked():
    """Exclusive lock around reading and changing the queue file. Yields the file's path."""
    root = queue_root()
    with open(root / "queue.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield root / "queue.json"
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def queue_load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        data = {}
    except (OSError, ValueError) as exc:
        raise ToolError(f"the queue file '{path}' could not be read: {exc}")
    data.setdefault("next_id", 1)
    data.setdefault("jobs", [])
    return data


def queue_save(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def now_stamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def queue_job_text(job: dict) -> str:
    return f"tovinci {shlex.join(job['argv'])}"


def queue_add(opts: Options, patterns: list) -> int:
    files = resolve_files(patterns)
    if not files:
        print("Error: no valid input files found.", file=sys.stderr)
        return 1
    if opts.combine and len(files) < 2:
        print(f"Error: -c/--combine needs at least 2 valid input files (found {len(files)}).", file=sys.stderr)
        return 1
    files = [os.path.abspath(f) for f in files]
    groups = [files] if opts.combine else [[f] for f in files]

    with queue_locked() as qpath:
        data = queue_load(qpath)
        for group in groups:
            # lanes: how many encodes this job runs at once; cap: how many lanes may be busy in
            # its folder when it starts. A combine encodes -j clips itself; separate files
            # are separate jobs that may overlap up to -j.
            lanes = opts.jobs if (opts.combine and opts.resumable and not opts.no_convert) else 1
            cap = lanes if opts.combine else opts.jobs
            job = {"id": data["next_id"], "status": "pending", "added": now_stamp(),
                   "cwd": os.path.dirname(group[0]), "lanes": lanes, "cap": cap,
                   "argv": list(opts.option_argv) + group}
            data["next_id"] += 1
            data["jobs"].append(job)
            what = f"{len(group)} files combined" if opts.combine else os.path.basename(group[0])
            more = f", up to {cap} at a time" if cap > 1 else ""
            print(f"Queued job {job['id']}: {what}  (runs in {job['cwd']}{more})")
        queue_save(qpath, data)
        waiting = sum(1 for j in data["jobs"] if j["status"] in ("pending", "running"))
    print(f"{waiting} job(s) waiting. Start them with: tovinci --queue-run")
    return 0


def queue_list() -> int:
    with queue_locked() as qpath:
        data = queue_load(qpath)
    if not data["jobs"]:
        print("The queue is empty.")
        return 0
    for job in data["jobs"]:
        print(f"{job['id']:>4}  {job['status']:<8}  {queue_job_text(job)}")
        print(f"      in {job['cwd']}")
    return 0


def queue_clear() -> int:
    with queue_locked() as qpath:
        data = queue_load(qpath)
        keep = [j for j in data["jobs"] if j["status"] in ("pending", "running")]
        removed = len(data["jobs"]) - len(keep)
        data["jobs"] = keep
        queue_save(qpath, data)
    print(f"Removed {removed} finished job(s); {len(keep)} still waiting.")
    return 0


def queue_runner_active() -> bool:
    """True if another process currently holds the runner lock."""
    with open(queue_root() / "queue.run.lock", "a+") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        fcntl.flock(fh, fcntl.LOCK_UN)
    return False


def queue_remove(job_id: int) -> int:
    active = queue_runner_active()
    with queue_locked() as qpath:
        data = queue_load(qpath)
        match = [j for j in data["jobs"] if j["id"] == job_id]
        if not match:
            print(f"Error: there is no job {job_id} in the queue (see --queue-list).", file=sys.stderr)
            return 1
        if match[0]["status"] == "running" and active:
            print(f"Error: job {job_id} is running right now. Stop the runner first (Ctrl-C).", file=sys.stderr)
            return 1
        data["jobs"] = [j for j in data["jobs"] if j["id"] != job_id]
        queue_save(qpath, data)
    print(f"Removed job {job_id}.")
    return 0


def queue_update(job_id: int, **changes) -> None:
    with queue_locked() as qpath:
        data = queue_load(qpath)
        for job in data["jobs"]:
            if job["id"] == job_id:
                job.update(changes)
        queue_save(qpath, data)


def pid_alive(pid: int) -> bool:
    """True if pid is a running tovinci (a recycled pid belonging to another program is not)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        return b"tovinci" in Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return True


def active_root() -> Path:
    root = queue_root() / "active"
    root.mkdir(parents=True, exist_ok=True)
    return root


def register_active(directory: str) -> None:
    """Note that this run is working in a folder, so a queue runner can keep out of other
    folders until it ends. Failing to do so must never stop a conversion."""
    try:
        path = active_root() / f"{os.getpid()}.json"
        path.write_text(json.dumps({"pid": os.getpid(), "dir": directory, "started": now_stamp(),
                                    "runner": int(os.environ.get("TOVINCI_QUEUE_RUNNER") or 0)}),
                        encoding="utf-8")
    except (OSError, ToolError, ValueError):
        return
    atexit.register(lambda: path.unlink(missing_ok=True))


def other_active_dirs(runner_pid: int) -> set:
    """Folders in use by tovinci runs that were not started by this queue runner."""
    dirs: set = set()
    try:
        root = active_root()
    except (OSError, ToolError):
        return dirs
    for entry in root.glob("*.json"):
        try:
            info = json.loads(entry.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        pid = info.get("pid")
        if not isinstance(pid, int) or not pid_alive(pid):
            entry.unlink(missing_ok=True)
            continue
        if pid == os.getpid() or info.get("runner") == runner_pid:
            continue
        dirs.add(info.get("dir", ""))
    return dirs


def admission_block(job: dict, running: list, runner_pid: int) -> str | None:
    """None if the job may start now. Otherwise why not: a message when another folder is
    busy, or an empty string when it is only waiting for a free slot."""
    busy = {r["job"]["cwd"] for r in running} | other_active_dirs(runner_pid)
    if busy and busy != {job["cwd"]}:
        other = sorted(busy - {job["cwd"]})[0]
        return f"waiting for '{other}' to finish before starting jobs in '{job['cwd']}'"
    used = sum(r["lanes"] for r in running)
    if running and used + job.get("lanes", 1) > job.get("cap", 1):
        return ""
    return None


def clock() -> str:
    return time.strftime("%H:%M:%S")


def queue_run(opts: Options) -> int:
    root = queue_root()
    gap = QUEUE_GAP_DEFAULT if opts.queue_gap is None else opts.queue_gap
    script = os.path.realpath(__file__)
    runner_pid = os.getpid()
    env = dict(os.environ, TOVINCI_QUEUE_RUNNER=str(runner_pid))

    run_lock = open(root / "queue.run.lock", "a+")
    try:
        fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Another 'tovinci --queue-run' is already working through the queue.", file=sys.stderr)
        run_lock.close()
        return 1

    # A terminal Ctrl-C reaches the jobs as well, but kill and a closing terminal (SIGTERM,
    # SIGHUP) only reach the runner, so those are turned into the same orderly stop.
    term = {"hit": False}

    def on_term(signum, frame):
        term["hit"] = True
        raise KeyboardInterrupt

    old_handlers = [(sig, signal.signal(sig, on_term)) for sig in (signal.SIGTERM, signal.SIGHUP)]

    # With the runner lock held, a job still marked running is left over from a run that
    # was killed, so it is simply picked up again.
    with queue_locked() as qpath:
        data = queue_load(qpath)
        for job in data["jobs"]:
            if job["status"] == "running":
                job["status"] = "pending"
        queue_save(qpath, data)

    running: list = []  # {"job", "proc", "lanes", "rc", "release_at", "fake_rc"}
    announced: set = set()
    ran = done = failed = 0
    stopping = False
    try:
        while True:
            now = time.monotonic()
            for r in running:
                if r["rc"] is not None:
                    continue
                rc = r["proc"].poll() if r["proc"] else r["fake_rc"]
                if rc is None:
                    continue
                r["rc"] = rc
                r["release_at"] = now + gap
                jid = r["job"]["id"]
                if rc == 0:
                    done += 1
                    queue_update(jid, status="done", exit=0, finished=now_stamp())
                    print(f"{clock()} Job {jid} finished. Its slot is free again in {gap} seconds "
                          "(so the output is fully written).", flush=True)
                else:
                    failed += 1
                    queue_update(jid, status="failed", exit=rc, finished=now_stamp())
                    print(f"{clock()} Job {jid} failed (exit code {rc}).", file=sys.stderr, flush=True)
                    if opts.queue_stop and not stopping:
                        stopping = True
                        print("Stopping because of --queue-stop-on-error. Jobs already running finish; "
                              "the rest stay queued.", file=sys.stderr, flush=True)
            # A finished job keeps its slot, and its folder, busy until the gap has passed.
            running = [r for r in running if r["rc"] is None or now < r["release_at"]]

            pending = []
            if not stopping:
                with queue_locked() as qpath:
                    pending = [j for j in queue_load(qpath)["jobs"] if j["status"] == "pending"]
            if not pending and not running:
                break

            if pending:
                job = pending[0]
                reason = admission_block(job, running, runner_pid)
                if reason is None:
                    ran += 1
                    queue_update(job["id"], status="running", started=now_stamp())
                    print(f"\n=== {clock()} Starting queue job {job['id']} ({len(pending) - 1} more waiting) ===")
                    print(f"{queue_job_text(job)}\n(in {job['cwd']})", flush=True)
                    entry = {"job": job, "proc": None, "lanes": job.get("lanes", 1), "rc": None,
                             "release_at": None, "fake_rc": None}
                    if os.path.isdir(job["cwd"]):
                        entry["proc"] = subprocess.Popen([sys.executable, script] + list(job["argv"]),
                                                         cwd=job["cwd"], env=env)
                    else:
                        print(f"Error: the folder '{job['cwd']}' no longer exists.", file=sys.stderr)
                        entry["fake_rc"] = 1
                    running.append(entry)
                elif reason and (job["id"], reason) not in announced:
                    announced.add((job["id"], reason))
                    print(f"{clock()} Job {job['id']} is {reason}.", flush=True)

            time.sleep(0.5)
    except KeyboardInterrupt:
        live = [r for r in running if r["rc"] is None and r["proc"]]
        if term["hit"]:
            for r in live:
                r["proc"].send_signal(signal.SIGINT)  # ask the jobs to stop cleanly too
        deadline = time.monotonic() + 60
        for r in live:
            try:
                r["proc"].wait(timeout=max(1.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                r["proc"].kill()
                r["proc"].wait()
        for r in running:
            if r["rc"] is None:
                queue_update(r["job"]["id"], status="pending")
        print("\nQueue stopped. Interrupted jobs are waiting again; run --queue-run to continue.",
              file=sys.stderr)
        return 130
    finally:
        for sig, handler in old_handlers:
            signal.signal(sig, handler)
        run_lock.close()

    if ran == 0:
        print("The queue is empty. Add jobs with --queue-add.")
        return 0
    print(f"\nQueue finished: {done} done, {failed} failed.")
    return 1 if failed else 0


def handle_queue(opts: Options, patterns: list) -> int:
    try:
        if opts.queue_action == "add":
            return queue_add(opts, patterns)
        if opts.queue_action == "run":
            return queue_run(opts)
        if opts.queue_action == "list":
            return queue_list()
        if opts.queue_action == "clear":
            return queue_clear()
        return queue_remove(opts.queue_remove_id)
    except ToolError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def main(argv: list | None = None) -> int:
    opts, patterns = parse_args(sys.argv[1:] if argv is None else argv)

    if opts.queue_action:
        return handle_queue(opts, patterns)

    files = resolve_files(patterns)
    if not files:
        print("Error: no valid input files found.", file=sys.stderr)
        return 1
    total = len(files)
    if not opts.dry_run:
        register_active(os.path.dirname(os.path.abspath(files[0])))

    if opts.combine:
        if total < 2:
            print(f"Error: -c/--combine needs at least 2 valid input files (found {total}).", file=sys.stderr)
            return 1
        if not opts.resumable or opts.no_convert:
            if opts.jobs > 1:
                print("Note: -j only applies to a combine when -r is also given (clips are then "
                      "encoded separately); continuing with one job.", file=sys.stderr)
            opts.jobs = 1  # a single-pass combine produces one output, so concurrency does not apply

    gpu = None
    if opts.gpu_requested and not opts.no_convert:
        gpu = detect_gpu()
        if gpu:
            print(f"GPU-accelerated decode enabled (backend: {gpu.backend}). Encoding itself still runs "
                  "on the CPU.", file=sys.stderr)
        else:
            print("Warning: -use-gpu=true requested, but no usable GPU decode backend was detected "
                  "(checked cuda/vaapi/qsv). Falling back to CPU decoding.", file=sys.stderr)

    log_path = setup_log_path()
    rotate_log(log_path)
    logger = Logger(log_path, opts.verbose)
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    try:
        if not opts.dry_run:
            prepare_output_dir(opts)  # a dry run writes nothing, so it never creates the directory

        if opts.combine:
            logger.log(f"{RUN_MARKER} {stamp} :: tovinci {VERSION} :: combine {total} files ===")
            files = order_for_combine(files, opts, logger)
            if opts.dry_run:
                return run_dry_run(files, opts, gpu, logger, combine=True)
            return run_combine(files, opts, gpu, logger)

        if total == 1:
            logger.log(f"{RUN_MARKER} {stamp} :: tovinci {VERSION} :: '{files[0]}' ===")
        else:
            logger.log(f"{RUN_MARKER} {stamp} :: tovinci {VERSION} :: {total} files (jobs={opts.jobs}) ===")

        if opts.dry_run:
            return run_dry_run(files, opts, gpu, logger, combine=False)

        check_output_collisions(files, opts)

        def job(f: str) -> int:
            prefix = f"[{os.path.basename(f)}] " if opts.jobs > 1 else ""
            try:
                return process_file(f, opts, gpu, logger.child(prefix))
            except ToolError as exc:
                print(f"Error: {exc}", file=sys.stderr)
                return 1

        with ThreadPoolExecutor(max_workers=opts.jobs) as pool:
            results = list(pool.map(job, files))

        failed = [f for f, rc in zip(files, results) if rc != 0]
        if total > 1:
            logger.log(RULE)
            if not failed:
                logger.notify(f"Done! All {total} file(s) converted successfully.")
            else:
                logger.notify(f"Finished: {total - len(failed)}/{total} file(s) converted successfully.")
                logger.notify("Failed to convert:")
                for f in failed:
                    logger.notify(f"  - {f}")
                print(f"See {log_path} for details.", file=sys.stderr)
        return 1 if failed else 0

    except ToolError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        if opts.resumable:
            print("Re-run the same command to resume.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
