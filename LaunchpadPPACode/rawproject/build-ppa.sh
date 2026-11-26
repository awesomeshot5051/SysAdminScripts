#!/bin/bash
# Build signed source packages for Launchpad and (optionally) upload them.
#
#   ./build-ppa.sh                 build for every series in SERIES (no upload)
#   ./build-ppa.sh --upload        build and dput to the PPA
#   ./build-ppa.sh --unsigned      build without signing (local test only)
#   ./build-ppa.sh resolute        build for one series only
#
# Launchpad PPAs only build for Ubuntu series. Debian trixie is not supported.
set -euo pipefail

PPA="rawproject-upload"   # host stanza in ~/.dput.cf (the system [ppa] entry is a placeholder)
MAINT="awesomeshot5051 <englandtechnologies@gmail.com>"
SERIES=(resolute)          # Ubuntu 26.04 "Resolute Raccoon"
GPG_KEY=""                 # optional: key ID/email to sign with

UPLOAD=0; SIGN=1; ONLY=()
for a in "$@"; do
  case "$a" in
    --upload)   UPLOAD=1 ;;
    --unsigned) SIGN=0 ;;
    -*)         echo "Unknown option: $a" >&2; exit 1 ;;
    *)          ONLY+=("$a") ;;
  esac
done
[ ${#ONLY[@]} -gt 0 ] && SERIES=("${ONLY[@]}")

cd "$(dirname "$(readlink -f "$0")")"
BASE=$(dpkg-parsechangelog -l debian/changelog -S Version | sed 's/+.*//')
OUT="$PWD/ppa-build"
rm -rf "$OUT"; mkdir -p "$OUT"

for s in "${SERIES[@]}"; do
  ver="${BASE}+${s}1"       # bump the trailing number for re-uploads
  src="$OUT/rawproject-$ver"
  echo "==> Building source package $ver for $s"
  mkdir -p "$src"
  cp -a debian rawproject-pkg "$src/"
  cat > "$src/debian/changelog" <<CHANGELOG
rawproject ($ver) $s; urgency=medium

  * Release $BASE for Ubuntu $s.

 -- $MAINT  $(date -R)
CHANGELOG
  opts=(-S -sa)
  if [ "$SIGN" = 1 ]; then
    [ -n "$GPG_KEY" ] && opts+=("-k$GPG_KEY")
  else
    opts+=(-us -uc)
  fi
  (cd "$src" && dpkg-buildpackage "${opts[@]}")
  if [ "$UPLOAD" = 1 ]; then
    [ "$SIGN" = 1 ] || { echo "Refusing to upload unsigned packages." >&2; exit 1; }
    dput "$PPA" "$OUT/rawproject_${ver}_source.changes"
  else
    echo "    To upload: dput $PPA $OUT/rawproject_${ver}_source.changes"
  fi
done
