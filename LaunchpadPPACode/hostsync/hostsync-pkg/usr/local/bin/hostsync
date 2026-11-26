#!/usr/bin/env python3
"""hostsync - rsync wrapper for home lab / multi-host syncing.

Python port of the hostsync bash script. rsync and ssh are still the transport,
so they are still required (locally and, for rsync, on the remote end).

Requires Python 3.8+, rsync, ssh. sshpass is needed only for password logins.
--mkpath needs rsync 3.2.3+ on both ends.
Domain discovery (-D) uses dig for direct DNS server queries and getent (or the
Python resolver if getent is missing) for system resolver lookups.
"""
import argparse
import atexit
import fnmatch
import getpass
import ipaddress
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

# ---------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------
CONNECT_TIMEOUT = 5
DNS_JOBS = 32          # parallel reverse lookups during a domain sweep
MIN_PREFIX = 22        # smallest allowed subnet prefix for a sweep (/22 = 1022 hosts)
HOSTSYNC_ENV_VAR = "HOSTSYNC_HOSTS"
LOG_DIR = os.path.join(os.path.expanduser("~"), ".synchosts")
LOG_FILE = os.path.join(LOG_DIR, "hostsync.log")

if sys.stdout.isatty() and "NO_COLOR" not in os.environ:
    RED, YELLOW, GREEN, CYAN = "\033[0;31m", "\033[1;33m", "\033[0;32m", "\033[0;36m"
    BOLD, RESET = "\033[1m", "\033[0m"
else:
    RED = YELLOW = GREEN = CYAN = BOLD = RESET = ""

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
IPV4_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
USER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9._-]*$")
CIDR_RE = re.compile(r"^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$")

# Runtime state, filled in by main()
S = argparse.Namespace(
    hosts=[], domains=[], subnets=[], excludes=[], exclude_pats=[],
    local_ips=[], auth_prefix=[], ssh_opts=[], rsync_opts=[], delete_opt=[],
    rsh_cmd="", agent_pid=None, auth_mode="password", dns_server="",
    verbose=False,
)

_lock = threading.RLock()


# ---------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------
def strip_ansi(text):
    return ANSI_RE.sub("", text)


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def ensure_log():
    if not os.path.isdir(LOG_DIR):
        os.makedirs(LOG_DIR, exist_ok=True)
        os.chmod(LOG_DIR, 0o700)
    if not os.path.exists(LOG_FILE):
        fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.close(fd)


def log_file(text):
    with _lock:
        ensure_log()
        with open(LOG_FILE, "a", encoding="utf-8", errors="replace") as fh:
            fh.write(strip_ansi(text) + "\n")


def emit(msg, err=False):
    with _lock:
        print(msg, file=sys.stderr if err else sys.stdout, flush=True)
        log_file(f"[{now()}] {msg}")


def vlog(msg):
    with _lock:
        log_file(f"[{now()}] {msg}")
        if S.verbose:
            print(msg, flush=True)


def log_info(msg):
    emit(f"{CYAN}[hostsync]{RESET} {msg}")


def log_success(msg):
    emit(f"{GREEN}[  OK  ]{RESET} {msg}")


def log_warn(msg):
    emit(f"{YELLOW}[ WARN ]{RESET} {msg}")


def log_err(msg):
    emit(f"{RED}[ ERR  ]{RESET} {msg}", err=True)


def log_verbose(msg):
    vlog(f"{CYAN}[hostsync]{RESET} {msg}")


def die(msg, code=1, show_usage=False):
    log_err(msg)
    if show_usage:
        usage()
    sys.exit(code)


# ---------------------------------------------------------------------
# Cleanup (runs on every exit path)
# ---------------------------------------------------------------------
def cleanup():
    if S.agent_pid:
        try:
            os.kill(int(S.agent_pid), signal.SIGTERM)
        except (OSError, ValueError):
            pass
        S.agent_pid = None
    os.environ.pop("SSHPASS", None)
    S.password = ""


def _on_term(signum, frame):
    raise KeyboardInterrupt


# ---------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------
USAGE_TEXT = """
{B}hostsync{R} - sync files/directories to one or more remote hosts via rsync

{B}USAGE{R}
  hostsync [OPTIONS] <file(s)...> -o <remote_path>
  hostsync [OPTIONS] -d <directory> -o <remote_path>
  Use -- before file names that start with a dash.

{B}AUTH OPTIONS{R}
  -k <path>       Path to SSH private key file. The key is loaded into a private,
                  temporary ssh-agent (you are prompted for a passphrase if it
                  has one) and the agent is killed on exit.
                  With -s, the password (see below) is used only for sudo.
  -p <password>   Login/sudo password. WARNING: visible in the process list and
                  shell history. Prefer $HOSTSYNC_PASSWORD or the interactive
                  prompt. Password logins require sshpass.

{B}HOST OPTIONS{R}  (combinable, all collected hosts are merged and deduplicated)
  -h <host|file>  Single IP/hostname on the CLI, OR a file containing exactly
                  one IP/hostname (lines starting with # are ignored)
  -H <list|file>  Semicolon-separated IPs/hostnames on the CLI, OR a file
                  containing IPs/hostnames separated by semicolons and/or
                  newlines (lines starting with # are ignored)
  -e              Read hosts from the ${ENVVAR} environment variable
                  (semicolon-separated list, same format as -H)
  -a              Auto-discover hosts via 'ip n show'  (see warning below)

{B}DOMAIN OPTIONS{R}
  -D <domain>     Sync to every device whose reverse-DNS (PTR) name ends in this
                  domain, e.g. -D example.lan matches server1.example.lan. Can be
                  repeated or semicolon-separated.
                  DNS cannot list a zone on request, so hostsync sweeps the PTR
                  records of the subnets below and keeps the matches. A match is
                  used by name only if its forward lookup points back at the same
                  IP, otherwise the IP is used and a warning is shown.
                  This machine is skipped automatically.
  --dns-server <ip|host>
                  Ask this DNS server directly for the PTR/A lookups instead of
                  the system resolver. Your system resolver may not serve reverse
                  records for the whole zone. If omitted, hostsync tries to find
                  the server from the domain's NS records (needs dig). Also used
                  to match -x exclusions by IP or name.
  --subnet <cidr> Subnet(s) to sweep for -D (semicolon-separated, repeatable).
                  Default: the subnets of this machine's network interfaces
                  (docker/virtual bridges and anything larger than /{MINP} skipped).
  --axfr-server <ip|host>
                  Try a DNS zone transfer (AXFR) from this server first. Only
                  works if the server allows transfers from this machine.
                  Falls back to the sweep. Needs dig.
  -x <list|file>  Exclude hosts. Semicolon-separated names, IPs or glob patterns,
                  or a file of them (one per line, # comments). Applies to every
                  host source, and matches either the name or the IP of a host.
                  Quote patterns so your shell does not expand the *.
                  A pattern starting with a dot is a suffix match:
                  '.printer.example.lan' means '*.printer.example.lan'.
  --list-hosts    Resolve and print the final target hosts, then exit. Needs no
                  files or -o, so it is a good way to preview -D and -x.

{B}OTHER OPTIONS{R}
  -u <username>   Remote username  (default: current user)
  -d <directory>  Sync a local directory instead of individual files
  -o <path>       {B}Required.{R} Destination path on the remote host(s).
                  Created automatically if it does not exist. Use an absolute
                  path (a leading ~ is not expanded).
  -s              Deploy with sudo on the remote host (for root-owned paths).
                  Files are staged in a private temp dir, then copied into place
                  with a single sudo rsync. The sudo password is sent over
                  stdin, never placed on a command line.
  -y              Skip the 'Proceed?' confirmation (for scripts and cron)
  -v              Verbose: print all rsync output to stdout as well as the log
  --mp <int>      Maximum number of parallel jobs (default 8)
  --dry-run       Pass --dry-run to rsync (nothing is changed). With -s only the
                  staging connection is tested and the deploy step is skipped.
  --delete        Mirror mode: delete extra files in the destination.
                  Only allowed together with -d.
  --no-parallel   Sync hosts sequentially instead of in parallel
  --help          Show this help

{B}LOGGING{R}
  All activity is recorded to: {LOG}

{B}EXIT STATUS{R}
  0 if every host synced, 1 if any host failed.

{B}ENVIRONMENT{R}
  HOSTSYNC_HOSTS      semicolon-separated hosts, used with -e
  HOSTSYNC_PASSWORD   login/sudo password, safer than -p

{B}EXAMPLES{R}
  # Single host, interactive password prompt
  hostsync -u admin -h server1.example.lan app.conf -o /home/admin/myapp/

  # Multiple hosts, SSH key, remote sudo deploy
  hostsync -k ~/.ssh/id_ed25519 -s -H 'server1.example.lan;server2.example.lan' -d ./configs -o /usr/local/bin/

  # Everything in the .example.lan domain, except the firewall and all printers
  hostsync -k ~/.ssh/id_ed25519 -D example.lan -x 'cisco.firewall.example.lan;.printer.example.lan' -d ./scripts -o /home/me/scripts/

  # Same, naming the DNS server explicitly
  hostsync -D example.lan --dns-server 192.0.2.53 -x 'cisco.firewall.example.lan' --list-hosts

  # Hosts from file + environment variable, verbose
  hostsync -H ~/lab_hosts -e -v -d ./scripts -o /home/pi/scripts/

  # Auto-discover
  hostsync -a -u pi -d ./dotfiles -o /home/pi/dotfiles/

{B}AUTO-DISCOVER WARNING{R}
  -a queries the kernel ARP/NDP neighbour table ('ip n show') and will attempt
  to contact EVERY IP in the cache: routers, printers, IoT devices, etc.
  You will be asked to confirm before any transfer begins.
"""


def usage():
    ensure_log()
    print(USAGE_TEXT.format(B=BOLD, R=RESET, ENVVAR=HOSTSYNC_ENV_VAR,
                            MINP=MIN_PREFIX, LOG=LOG_FILE))


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
def valid_host(h):
    return bool(HOST_RE.match(h))


def valid_user(u):
    return bool(USER_RE.match(u))


def rsync_host(h):
    """rsync needs IPv6 literals in brackets."""
    return f"[{h}]" if ":" in h else h


def parse_list_input(value, allow_file=True):
    """Items of a semicolon-separated list. If allow_file and value is an
    existing file, read it instead (semicolons and/or newlines, # comments)."""
    items = []
    if allow_file and os.path.isfile(value):
        with open(value, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.split("#", 1)[0]
                items.extend(line.split(";"))
    else:
        items = value.split(";")
    out = []
    for item in items:
        item = re.sub(r"\s+", "", item)
        if item:
            out.append(item)
    return out


def last_line(text):
    for line in reversed((text or "").splitlines()):
        if line.strip():
            return line.strip()
    return ""


def run_text(cmd, timeout):
    """Run a command, return stdout text ('' on any failure or timeout)."""
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              stdin=subprocess.DEVNULL, text=True, errors="replace",
                              timeout=timeout)
        return proc.stdout
    except (subprocess.TimeoutExpired, OSError):
        return ""


def run_logged(label, cmd):
    """Run cmd, log its output (and show it live with -v). Returns (rc, output)."""
    lines = []
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, text=True, errors="replace",
                                bufsize=1)
    except OSError as exc:
        log_file(f"[{label}] could not start {cmd[0]}: {exc}")
        return 127, str(exc)
    for line in proc.stdout:
        line = line.rstrip("\n")
        lines.append(line)
        if S.verbose:
            with _lock:
                print(line, flush=True)
                log_file(line)
    proc.wait()
    out = "\n".join(lines)
    if not S.verbose and out:
        log_file(f"[{label}] output:\n{out}")
    return proc.returncode, out


def remote_cleanup(ssh_target, staging):
    """Best-effort removal of the remote staging directory."""
    try:
        subprocess.run(S.auth_prefix + ["ssh"] + S.ssh_opts +
                       [ssh_target, f"rm -rf -- {shlex.quote(staging)}"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        pass


def ip_sort_key(ip):
    try:
        return (0, int(ipaddress.ip_address(ip)))
    except ValueError:
        return (1, 0)


# ---------------------------------------------------------------------
# Subnet math
# ---------------------------------------------------------------------
class CidrInvalid(ValueError):
    pass


class CidrTooLarge(ValueError):
    pass


def expand_cidr(cidr):
    """Every usable host address in a CIDR block, as strings."""
    if not CIDR_RE.match(cidr):
        raise CidrInvalid(cidr)
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        raise CidrInvalid(cidr)
    if net.prefixlen < MIN_PREFIX:
        raise CidrTooLarge(cidr)
    if net.prefixlen >= 31:
        return [str(a) for a in net]
    return [str(a) for a in net.hosts()]


# ---------------------------------------------------------------------
# DNS lookups
# ---------------------------------------------------------------------
def _clean_name(n):
    return n.lower().rstrip(".")


def dns_ptr(ip, server=""):
    """Reverse lookup. Lowercase names without trailing dot."""
    if server:
        out = run_text(["dig", f"@{server}", "+short", "+time=2", "+tries=1", "-x", ip], 10)
        return [_clean_name(l.split()[0]) for l in out.splitlines()
                if l.strip() and not l.startswith(";")]
    if shutil.which("getent"):
        out = run_text(["getent", "hosts", ip], 3)
        names = []
        for line in out.splitlines():
            names.extend(_clean_name(f) for f in line.split()[1:])
        return names
    try:
        host, aliases, _ = socket.gethostbyaddr(ip)
        return [_clean_name(host)] + [_clean_name(a) for a in aliases]
    except OSError:
        return []


def dns_a(name, server=""):
    """Forward lookup. IPv4 addresses."""
    if server:
        out = run_text(["dig", f"@{server}", "+short", "+time=2", "+tries=1", "A", name], 10)
        return [l.strip() for l in out.splitlines() if IPV4_RE.match(l.strip())]
    if shutil.which("getent"):
        out = run_text(["getent", "ahostsv4", name], 3)
        seen = []
        for line in out.splitlines():
            parts = line.split()
            if parts and parts[0] not in seen:
                seen.append(parts[0])
        return seen
    try:
        return socket.gethostbyname_ex(name)[2]
    except OSError:
        return []


def detect_dns_server(dom):
    """Find the DNS server for a domain from its NS record ('' if none)."""
    out = run_text(["dig", "+short", "+time=2", "+tries=1", "NS", dom], 10)
    ns = ""
    for line in out.splitlines():
        if line.strip() and not line.startswith(";"):
            ns = line.split()[0].rstrip(".")
            break
    if not ns:
        return ""
    if IPV4_RE.match(ns):
        return ns
    out = run_text(["dig", "+short", "+time=2", "+tries=1", "A", ns], 10)
    for line in out.splitlines():
        if IPV4_RE.match(line.strip()):
            return line.strip()
    return ""


def resolve_one(ip, doms, server):
    """Reverse-resolve one IP. If its name ends in one of the domains, return
    (ip, name, 'ok'|'mismatch'), where ok means the name resolves forward to
    the same IP. Otherwise None."""
    names = dns_ptr(ip, server)
    if not names:
        return None
    name = names[0]
    if not any(name.endswith("." + d) for d in doms):
        return None
    status = "ok" if ip in dns_a(name, server) else "mismatch"
    return (ip, name, status)


def axfr_rows(domain, server):
    out = run_text(["dig", "+noall", "+answer", "+time=3", "+tries=1",
                    "AXFR", domain, f"@{server}"], 60)
    rows = []
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 5 and f[3] == "A":
            rows.append((f[4], _clean_name(f[0]), "ok"))
    return rows


def load_local_ips():
    S.local_ips = []
    if shutil.which("ip"):
        out = run_text(["ip", "-4", "-o", "addr", "show"], 10)
        for line in out.splitlines():
            f = line.split()
            if len(f) >= 4:
                S.local_ips.append(f[3].split("/")[0])


# ---------------------------------------------------------------------
# Domain discovery
# ---------------------------------------------------------------------
def resolve_subnets():
    sweep = []
    if S.subnets:
        for c in S.subnets:
            try:
                expand_cidr(c)
            except CidrInvalid:
                die(f"Invalid subnet: '{c}' (expected something like 192.0.2.0/24)")
            except CidrTooLarge:
                die(f"Subnet '{c}' is larger than /{MIN_PREFIX}. Split it into smaller --subnet blocks.")
            sweep.append(c)
        return sweep

    if not shutil.which("ip"):
        die("The 'ip' command is not available. Pass the networks to sweep with --subnet.")

    out = run_text(["ip", "-4", "-o", "addr", "show", "scope", "global"], 10)
    for line in out.splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        ifc, cidr = f[1], f[3]
        if re.match(r"(docker|br-|veth|virbr|cni|flannel)", ifc):
            continue
        try:
            expand_cidr(cidr)
            sweep.append(cidr)
        except CidrTooLarge:
            log_verbose(f"Skipping {cidr} on {ifc}: larger than /{MIN_PREFIX}")
        except CidrInvalid:
            pass

    if not sweep:
        die("No usable local subnet found for the sweep. Pass the networks with --subnet.")
    return sweep


def discover_domains():
    added = skipped_self = 0
    rows = []
    sweep_doms = []

    for tool in ("dig",) if S.axfr_server else ():
        if not shutil.which(tool):
            die(f"--axfr-server needs {tool}, which was not found.")

    norm = []
    for d in S.domains:
        dom = d.lower().lstrip(".").rstrip(".")
        if not re.match(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", dom):
            die(f"Invalid domain: '{d}'")
        norm.append(dom)

    load_local_ips()

    # 1) Optional zone transfer
    if S.axfr_server:
        for dom in norm:
            hits = axfr_rows(dom, S.axfr_server)
            if hits:
                log_info(f"Zone transfer for {dom}: {len(hits)} record(s) from {S.axfr_server}")
                rows.extend(hits)
            else:
                log_warn(f"Zone transfer for {dom} was refused or empty, falling back to a reverse-DNS sweep")
                sweep_doms.append(dom)
    else:
        sweep_doms = list(norm)

    # 2) Reverse-DNS sweep
    if sweep_doms:
        if not S.dns_server and shutil.which("dig"):
            for dom in sweep_doms:
                S.dns_server = detect_dns_server(dom)
                if S.dns_server:
                    log_info(f"Using DNS server {S.dns_server} (from the NS record of {dom}) for lookups")
                    break
        if not S.dns_server:
            log_info("Lookups use the system resolver. If hosts are missing, pass --dns-server <your DNS server>.")

        subnets = resolve_subnets()
        ips = set()
        for c in subnets:
            ips.update(expand_cidr(c))
        ips = sorted(ips, key=ip_sort_key)
        if ips:
            log_info(f"Sweeping {len(ips)} address(es) in {' '.join(subnets)} for names under: {' '.join(sweep_doms)}")
            with ThreadPoolExecutor(max_workers=DNS_JOBS) as ex:
                for res in ex.map(lambda ip: resolve_one(ip, sweep_doms, S.dns_server), ips):
                    if res:
                        rows.append(res)

    # 3) Merge into hosts
    for ip, name, status in sorted(set(rows), key=lambda r: (ip_sort_key(r[0]), r[1])):
        if ip in S.local_ips:
            skipped_self += 1
            log_verbose(f"Skipping this machine ({name} / {ip})")
            continue
        target = name
        if status != "ok":
            log_warn(f"{name} does not resolve forward to {ip}; using the IP instead")
            target = ip
        if not valid_host(target):
            log_warn(f"Skipping unusable host name '{target}'")
            continue
        if target in S.hosts or ip in S.hosts or name in S.hosts:
            continue
        S.hosts.append(target)
        added += 1

    if added == 0:
        log_warn(f"No hosts found under: {' '.join(norm)}. Check that those names have PTR (reverse) "
                 "records, or pass --dns-server / --subnet.")
    else:
        log_info(f"Domain discovery added {added} host(s)")
    if skipped_self:
        log_verbose(f"Skipped {skipped_self} address(es) belonging to this machine")


# ---------------------------------------------------------------------
# Exclusions
# ---------------------------------------------------------------------
def host_ids(h):
    """The host itself plus its reverse names (if an IP) or addresses (if a name)."""
    ids = [h]
    ids.extend(dns_ptr(h, S.dns_server) if IPV4_RE.match(h) else dns_a(h, S.dns_server))
    return ids


def normalize_excludes():
    S.exclude_pats = []
    for p in S.excludes:
        p = p.lower().rstrip(".")
        if p.startswith("."):
            p = "*" + p
        S.exclude_pats.append(p)


def apply_excludes():
    if not S.exclude_pats:
        return
    with ThreadPoolExecutor(max_workers=min(DNS_JOBS, max(1, len(S.hosts)))) as ex:
        all_ids = list(ex.map(host_ids, S.hosts))

    kept, removed = [], 0
    for h, ids in zip(S.hosts, all_ids):
        hit = ""
        for ident in ids:
            ident = ident.lower()
            if not ident:
                continue
            for pat in S.exclude_pats:
                if fnmatch.fnmatchcase(ident, pat):
                    hit = f"pattern '{pat}' matched {ident}"
                    break
            if hit:
                break
        if hit:
            log_info(f"Excluding {h}: {hit}")
            removed += 1
        else:
            kept.append(h)
    S.hosts = kept
    log_verbose(f"Exclusions removed {removed} host(s)")


# ---------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------
class Parser(argparse.ArgumentParser):
    def error(self, message):
        log_err(message)
        usage()
        sys.exit(1)


def build_parser():
    p = Parser(prog="hostsync", add_help=False, allow_abbrev=False)
    p.add_argument("sources", nargs="*")
    p.add_argument("-k", dest="key", default="")
    p.add_argument("-p", dest="password", default=None)
    p.add_argument("-u", dest="user", default=os.environ.get("USER") or getpass.getuser())
    p.add_argument("-h", "-H", dest="hosts_raw", action="append", default=[])
    p.add_argument("-D", dest="domains_raw", action="append", default=[])
    p.add_argument("-x", dest="excludes_raw", action="append", default=[])
    p.add_argument("--subnet", dest="subnets_raw", action="append", default=[])
    p.add_argument("--dns-server", dest="dns_server", default="")
    p.add_argument("--axfr-server", dest="axfr_server", default="")
    p.add_argument("--list-hosts", dest="list_only", action="store_true")
    p.add_argument("-e", dest="env_hosts", action="store_true")
    p.add_argument("-a", dest="auto", action="store_true")
    p.add_argument("-s", dest="sudo", action="store_true")
    p.add_argument("-y", dest="yes", action="store_true")
    p.add_argument("-d", dest="directory", default=None)
    p.add_argument("-o", dest="remote_path", default="")
    p.add_argument("-v", dest="verbose", action="store_true")
    p.add_argument("--mp", dest="mp", default="8")
    p.add_argument("--dry-run", dest="dry_run", action="store_true")
    p.add_argument("--delete", dest="delete", action="store_true")
    p.add_argument("--no-parallel", dest="no_parallel", action="store_true")
    p.add_argument("--help", "-?", dest="help", action="store_true")
    return p


# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------
def validate_basic():
    if not re.match(r"^[0-9]+$", S.mp):
        die(f"Invalid value for --mp: '{S.mp}'. Must be a positive integer.")
    S.max_parallel = int(S.mp)
    if S.max_parallel == 0:
        die("Invalid value for --mp: 0. To disable parallel syncing use --no-parallel.")

    if not valid_user(S.user):
        die(f"Invalid remote username: '{S.user}'")

    if S.dns_server:
        if not valid_host(S.dns_server):
            die(f"Invalid --dns-server value: '{S.dns_server}'")
        if not shutil.which("dig"):
            die("--dns-server needs dig, which was not found (package: dnsutils or bind-utils).")

    if S.axfr_server:
        if not valid_host(S.axfr_server):
            die(f"Invalid --axfr-server value: '{S.axfr_server}'")
        if not S.domains:
            die("--axfr-server only makes sense together with -D <domain>.")

    if S.subnets and not S.domains:
        die("--subnet only makes sense together with -D <domain>.")


def validate_transfer_args():
    if S.key:
        S.key = os.path.expanduser(S.key)
        if not os.path.isfile(S.key):
            die(f"SSH key file not found: {S.key}")

    if not S.remote_path:
        die("Remote destination path (-o) is required.", show_usage=True)

    if S.directory_mode:
        if not S.directory:
            die("-d requires a directory argument.")
        if not os.path.isdir(S.directory):
            die(f"Source directory does not exist: {S.directory}")
        if S.sources:
            log_warn("Positional file arguments ignored in directory mode (-d).")
    else:
        if not S.sources:
            die("No source files specified. Use -d for directory mode.", show_usage=True)
        for f in S.sources:
            if not os.path.exists(f):
                die(f"Source path does not exist: {f}")

    if S.delete:
        if not S.directory_mode:
            die("--delete is only allowed with -d. In file mode it would remove every other file in the destination.")
        if S.remote_path == "/":
            die("Refusing to use --delete with a remote path of '/'.")

    for tool in ("rsync", "ssh"):
        if not shutil.which(tool):
            die(f"Required tool not found: {tool}")


# ---------------------------------------------------------------------
# Single-host sync
# ---------------------------------------------------------------------
def sync_host(host):
    prefix = f"{CYAN}[{host}]{RESET}"
    ssh_target = f"{S.user}@{host}"
    rsync_target = f"{S.user}@{rsync_host(host)}"
    sources = [S.directory.rstrip("/") + "/"] if S.directory_mode else list(S.sources)
    if S.directory_mode and S.directory.rstrip("/") == "":
        sources = ["/"]

    log_verbose(f"{prefix} Starting sync to {ssh_target}:{S.remote_path}")

    # ---- Plain deployment: rsync straight to the destination ----
    if not S.sudo:
        cmd = (S.auth_prefix + ["rsync"] + S.rsync_opts + S.delete_opt +
               ["-e", S.rsh_cmd] + sources + [f"{rsync_target}:{S.remote_path}/"])
        rc, out = run_logged(host, cmd)
        if rc == 0:
            log_success(f"{prefix} Sync complete to {ssh_target}:{S.remote_path}")
            return True
        reason = last_line(out)
        log_err(f"{prefix} rsync failed: {reason or 'exit ' + str(rc)} (details in {LOG_FILE})")
        return False

    # ---- Sudo deployment: stage as normal user, then one privileged rsync ----
    try:
        proc = subprocess.run(
            S.auth_prefix + ["ssh"] + S.ssh_opts +
            [ssh_target, "mktemp -d /tmp/hostsync.XXXXXXXXXX"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, errors="replace")
        staging = proc.stdout.strip()
        stderr = proc.stderr
        rc = proc.returncode
    except OSError as exc:
        staging, stderr, rc = "", str(exc), 127
    if stderr.strip():
        log_file(f"[{host}] ssh: {stderr.strip()}")
    if rc != 0 or not staging.startswith("/tmp/hostsync."):
        reason = last_line(stderr) or "no response"
        log_err(f"{prefix} Could not create a staging directory: {reason}")
        return False

    cmd = (S.auth_prefix + ["rsync"] + S.rsync_opts + ["-e", S.rsh_cmd] +
           sources + [f"{rsync_target}:{staging}/"])
    rc, out = run_logged(host, cmd)
    if rc != 0:
        log_err(f"{prefix} rsync to staging area failed: {last_line(out) or 'exit ' + str(rc)} "
                f"(details in {LOG_FILE})")
        remote_cleanup(ssh_target, staging)
        return False

    if S.dry_run:
        log_info(f"{prefix} Dry run: staging connection OK, sudo deploy step skipped")
        remote_cleanup(ssh_target, staging)
        return True

    # One sudo call. The password goes in over stdin (no -t, no command line).
    # Args are shell-quoted, and the staging dir is removed afterwards.
    delete_flag = "--delete" if S.delete else ""
    remote_cmd = (
        "sudo -S -p '' sh -c 'mkdir -p -- \"$1\" && rsync -a " + delete_flag +
        " -- \"$2/\" \"$1/\"' sh " + shlex.quote(S.remote_path) + " " + shlex.quote(staging) +
        "; rc=$?; rm -rf -- " + shlex.quote(staging) + "; exit $rc"
    )
    try:
        proc = subprocess.run(
            S.auth_prefix + ["ssh"] + S.ssh_opts + [ssh_target, remote_cmd],
            input=(S.password or "") + "\n", stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, errors="replace")
        out, deploy_rc = proc.stdout.strip(), proc.returncode
    except OSError as exc:
        out, deploy_rc = str(exc), 127
    if out:
        log_file(f"[{host}] deploy output:\n{out}")

    if deploy_rc == 0:
        log_success(f"{prefix} Sync complete (staged, deployed with sudo) to {ssh_target}:{S.remote_path}")
        return True

    log_err(f"{prefix} Privileged deploy failed: {last_line(out) or 'exit ' + str(deploy_rc)}. "
            f"See {LOG_FILE}")
    remote_cleanup(ssh_target, staging)
    return False


# ---------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------
def start_agent_and_add_key():
    proc = subprocess.run(["ssh-agent", "-s"], stdout=subprocess.PIPE, text=True)
    sock = re.search(r"SSH_AUTH_SOCK=([^;]+);", proc.stdout)
    pid = re.search(r"SSH_AGENT_PID=([0-9]+);", proc.stdout)
    if proc.returncode != 0 or not sock or not pid:
        die("Could not start ssh-agent.")
    os.environ["SSH_AUTH_SOCK"] = sock.group(1)
    os.environ["SSH_AGENT_PID"] = pid.group(1)
    S.agent_pid = pid.group(1)

    log_info("Loading SSH key into a temporary ssh-agent...")
    if subprocess.run(["ssh-add", S.key]).returncode != 0:
        die("Failed to add SSH key to the agent.")


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
def main():
    args = build_parser().parse_intermixed_args()
    if args.help:
        usage()
        return 0

    S.__dict__.update(vars(args))
    S.verbose = args.verbose
    S.directory_mode = args.directory is not None
    S.password_from_cli = args.password is not None
    S.password = args.password if args.password is not None else os.environ.get("HOSTSYNC_PASSWORD", "")

    S.hosts = []
    for raw in args.hosts_raw:
        S.hosts.extend(parse_list_input(raw))
    S.domains = []
    for raw in args.domains_raw:
        S.domains.extend(parse_list_input(raw, allow_file=False))
    S.excludes = []
    for raw in args.excludes_raw:
        S.excludes.extend(parse_list_input(raw))
    S.subnets = []
    for raw in args.subnets_raw:
        S.subnets.extend(parse_list_input(raw, allow_file=False))

    validate_basic()
    if not S.list_only:
        validate_transfer_args()

    # Hosts from environment variable (-e)
    if S.env_hosts:
        value = os.environ.get(HOSTSYNC_ENV_VAR, "")
        if not value:
            log_warn(f"${HOSTSYNC_ENV_VAR} is not set or empty, skipping.")
        else:
            S.hosts.extend(parse_list_input(value, allow_file=False))
            log_verbose(f"Loaded hosts from ${HOSTSYNC_ENV_VAR}")

    # Hosts from DNS domains (-D)
    if S.domains:
        discover_domains()

    # Auto-discover (-a)
    if S.auto:
        print(f"{YELLOW}{BOLD}AUTO-DISCOVER WARNING{RESET}")
        print("   hostsync will query your kernel's ARP/NDP neighbour table ('ip n show')")
        print("   and attempt to connect to EVERY IP found, including routers, printers,")
        print("   smart TVs, IoT devices, and other hosts you may NOT want to sync to.")
        print()
        confirm = input("   Type YES to continue with auto-discovery: ")
        if confirm != "YES":
            log_info("Auto-discovery cancelled by user.")
        else:
            out = run_text(["ip", "n", "show"], 10)
            found = []
            for line in out.splitlines():
                f = line.split()
                if f and re.search(r"REACHABLE|STALE|DELAY|PROBE", line) and IPV4_RE.match(f[0]):
                    found.append(f[0])
            if not found:
                log_warn("No reachable neighbours found in ARP table.")
            else:
                log_info(f"Discovered {len(found)} neighbour(s): {' '.join(found)}")
                S.hosts.extend(found)

    # Deduplicate
    S.hosts = sorted(set(S.hosts))
    if not S.hosts:
        die("No target hosts found. Use -h, -H, -e, -D, or -a.", show_usage=True)

    # Reject anything that could be parsed as an ssh/rsync option
    for h in S.hosts:
        if not valid_host(h):
            die(f"Invalid host name or address: '{h}'")

    # Exclusions (-x)
    normalize_excludes()
    apply_excludes()
    if not S.hosts:
        die("No target hosts remain after applying exclusions.")

    # --list-hosts
    if S.list_only:
        print()
        print(f"{BOLD}Resolved {len(S.hosts)} target host(s):{RESET}")
        for h in S.hosts:
            print(f"  {h}")
        return 0

    # Auth mode, ssh and rsync options
    if S.key:
        S.auth_mode = "key"
    else:
        S.auth_mode = "password"
        if not shutil.which("sshpass"):
            die("sshpass is required for password logins. Install it or use -k <keyfile>.")

    if S.password_from_cli:
        log_warn("-p exposes the password in the process list and shell history. "
                 "Prefer $HOSTSYNC_PASSWORD or the prompt.")

    if S.auth_mode == "key" and S.password and not S.sudo:
        log_warn("A password was given with -k but without -s, so it will not be used.")
        S.password = ""

    S.ssh_opts = [
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"ConnectTimeout={CONNECT_TIMEOUT}",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
    ]
    if S.auth_mode == "key":
        S.ssh_opts += ["-o", "BatchMode=yes", "-o", "PasswordAuthentication=no"]
    else:
        S.ssh_opts += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                       "-o", "PubkeyAuthentication=no",
                       "-o", "NumberOfPasswordPrompts=1"]
    S.rsh_cmd = "ssh " + " ".join(S.ssh_opts)

    S.rsync_opts = ["-az", "--mkpath", "--protect-args"]
    if S.dry_run:
        S.rsync_opts.append("--dry-run")
    S.rsync_opts += ["-v", "--progress"] if S.verbose else ["-q"]
    S.delete_opt = ["--delete"] if S.delete else []

    # Pre-flight summary
    print()
    print(f"{BOLD}hostsync transfer summary{RESET}")
    print(f"  User      : {S.user}")
    print(f"  Auth      : SSH key ({S.key})" if S.auth_mode == "key" else "  Auth      : password")
    if S.directory_mode:
        print(f"  Source    : [directory] {S.directory}")
    else:
        print(f"  Sources   : {' '.join(S.sources)}")
    print(f"  Dest path : {S.remote_path}")
    print(f"  Hosts ({len(S.hosts)}): {' '.join(S.hosts)}")
    if S.domains:
        print(f"  Domains   : {' '.join(S.domains)}")
    if S.exclude_pats:
        print(f"  Excluding : {' '.join(S.exclude_pats)}")
    print(f"  Log file  : {LOG_FILE}")
    if S.verbose:
        print("  Verbose   : on")
    if S.sudo:
        print("  Remote Sudo: enabled")
    if S.dry_run:
        print(f"  {YELLOW}DRY RUN: no files will be transferred{RESET}")
    if S.delete:
        print(f"  {YELLOW}DELETE mode enabled (mirror){RESET}")
    parallel = not S.no_parallel and len(S.hosts) > 1
    if parallel:
        print(f"  Parallel  : up to {S.max_parallel} concurrent jobs")
    print()

    if not S.yes:
        go = input("Proceed? [Y/n] ")
        if go.strip().lower() in ("n", "no"):
            log_info("Aborted by user.")
            return 0

    # Credentials
    if S.auth_mode == "key":
        start_agent_and_add_key()
        if S.sudo and not S.password:
            S.password = getpass.getpass(f"[hostsync] Remote sudo password for {S.user}: ")
    else:
        if not S.password:
            S.password = getpass.getpass(f"SSH login/sudo password for {S.user}@<hosts>: ")
        # sshpass -e reads the password from the environment, so it never appears in 'ps'
        os.environ["SSHPASS"] = S.password
        S.auth_prefix = ["sshpass", "-e"]

    # Execute
    log_file(f"===== hostsync session start: user={S.user} dest={S.remote_path} "
             f"hosts={' '.join(S.hosts)} =====")
    start = datetime.now()

    if parallel:
        log_info(f"Syncing to {len(S.hosts)} host(s) in parallel (max {S.max_parallel} jobs)...")
        ex = ThreadPoolExecutor(max_workers=S.max_parallel)
        try:
            results = list(ex.map(sync_host, S.hosts))
        finally:
            ex.shutdown(wait=False, cancel_futures=True)
    else:
        log_info(f"Syncing to {len(S.hosts)} host(s) sequentially...")
        results = [sync_host(h) for h in S.hosts]

    elapsed = int((datetime.now() - start).total_seconds())
    failed = [h for h, ok in zip(S.hosts, results) if not ok]
    log_file(f"===== hostsync session end: elapsed={elapsed}s failed={len(failed)} =====")
    print()

    if not failed:
        log_success(f"All {len(S.hosts)} host(s) done in {elapsed}s.  Log: {LOG_FILE}")
        return 0
    log_err(f"{len(failed)} of {len(S.hosts)} host(s) failed: {' '.join(failed)}  "
            f"({elapsed}s, log: {LOG_FILE})")
    return 1


if __name__ == "__main__":
    atexit.register(cleanup)
    signal.signal(signal.SIGTERM, _on_term)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nhostsync: interrupted.")
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
