#!/usr/bin/env bash
# Shadow check of the durable APT state: builds a candidate site from state/ and the
# release, then compares it with the live Pages site. Never deploys and never writes state/.
#
# usage: shadow-check.sh <package> <version> <package-distribution-dir> <work-dir>
# env:   GPG_KEY_ID (signing key already imported; the live key is verified against it)
set -euo pipefail

PKG="$1" VERSION="$2" PD="$3" WORK="$4"
LIVE="https://vmvarela.github.io/apt-packages"
CAT="$PD/catalog/$PKG.json"

die() {
  echo "::error::$*" >&2
  exit 1
}

[[ -f "$CAT" ]] || die "Unknown package catalog: ${PKG}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be stable X.Y.Z: ${VERSION}"
[[ -n "${GPG_KEY_ID:-}" ]] || die "GPG_KEY_ID is required."
[[ ! -e "$WORK/candidate" ]] || die "Work directory already holds a candidate: ${WORK}"

# Mirror the live site: key, signed indexes, and every file the indexes reference.
mkdir -p "$WORK/live/dists/stable"
curl --fail --silent --show-error --location "$LIVE/key.gpg" -o "$WORK/live/key.asc"
for f in Release Release.gpg InRelease; do
  curl --fail --silent --show-error --location "$LIVE/dists/stable/$f" -o "$WORK/live/dists/stable/$f"
done
# Hashed paths listed in the SHA256 section of Release (indented "hash size path" lines).
paths="$(awk '/^SHA256:/{f=1;next} /^[A-Za-z0-9]+:/{f=0} f && NF==3 {print $3}' "$WORK/live/dists/stable/Release")"
[[ -n "$paths" ]] || die "Live Release lists no hashed files."
while read -r p; do
  mkdir -p "$WORK/live/dists/stable/$(dirname "$p")"
  curl --fail --silent --show-error --location "$LIVE/dists/stable/$p" -o "$WORK/live/dists/stable/$p"
done <<<"$paths"
while read -r rel; do
  mkdir -p "$WORK/live/$(dirname "$rel")"
  curl --fail --silent --show-error --location "$LIVE/$rel" -o "$WORK/live/$rel"
done < <(grep '^Filename: ' "$WORK"/live/dists/stable/main/binary-*/Packages | sed 's/^[^:]*:Filename: //' | sort -u)

# Build the candidate. Exit 0 with action "noop" writes no site: the release already matches state/.
node "$PD/scripts/apt-publish.mjs" --catalog "$CAT" --version "$VERSION" --source github \
  --out "$WORK/candidate" --state state --release-date "$(date -u +%F)" --shadow

if [[ ! -f "$WORK/candidate/.complete" ]]; then
  echo "shadow: noop for ${PKG} ${VERSION}; no candidate site to compare."
  exit 0
fi

node "$PD/scripts/apt-compare.mjs" --candidate "$WORK/candidate" --live "$WORK/live" | tee "$WORK/compare.log"
