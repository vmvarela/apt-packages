#!/usr/bin/env bash
# Local regression tests for scripts/update-apt-repository.sh.
#
# Deterministic and offline: curl, dpkg-deb and sha256sum are stubbed on
# PATH so the real script (not a copy) is exercised against fixture data.
# Run: bash scripts/test-update-apt-repository.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/update-apt-repository.sh"

pass=0
fail=0

expect_ok() {
  local desc="$1" out status
  shift
  if out="$("$@" 2>&1)"; then
    pass=$((pass + 1))
  else
    status=$?
    fail=$((fail + 1))
    echo "FAIL (expected success, got ${status}): ${desc}"
    echo "$out" | sed 's/^/    /'
  fi
}

expect_fail() {
  local desc="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    fail=$((fail + 1))
    echo "FAIL (expected failure): ${desc}"
    echo "$out" | sed 's/^/    /'
  else
    pass=$((pass + 1))
  fi
}

# Like expect_fail, but also requires the error output to match <pattern>.
expect_fail_msg() {
  local desc="$1" pattern="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    fail=$((fail + 1))
    echo "FAIL (expected failure): ${desc}"
    echo "$out" | sed 's/^/    /'
  elif grep -q "$pattern" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL (wrong error) for: ${desc} (wanted /${pattern}/)"
    echo "$out" | sed 's/^/    /'
  fi
}

# --- sandbox with stubbed commands -----------------------------------------

SANDBOX="$(mktemp -d)"
BIN="$SANDBOX/bin"
FIX="$SANDBOX/fixtures"
WORK="$SANDBOX/work"
MAP="$SANDBOX/url-map.tsv"
CURL_LOG="$SANDBOX/curl.log"
mkdir -p "$BIN" "$FIX" "$WORK"
: > "$MAP"
: > "$CURL_LOG"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Serves fixture files mapped in $FAKE_URL_MAP (URL<TAB>path). Exits 22 for
# unmapped URLs, like curl --fail on HTTP errors.
set -euo pipefail
url=""; out=""; location=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o) i=$((i + 1)); out="${args[$i]}" ;;
    --location|-L) location=1 ;;
    -*) ;;
    *) url="${args[$i]}" ;;
  esac
done
if [[ "$url" == */sha256sums.txt && "$location" -ne 1 ]]; then
  echo "stub curl: checksum asset request must follow GitHub's redirect" >&2
  exit 2
fi
if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
  printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
fi
fixture="$(awk -F '\t' -v u="$url" '$1 == u {print $2; exit}' "${FAKE_URL_MAP:?}")"
if [[ -z "$fixture" ]]; then
  echo "stub curl: no fixture for $url" >&2
  exit 22
fi
if [[ -n "$out" ]]; then
  cat "$fixture" > "$out"
else
  cat "$fixture"
fi
STUB

cat > "$BIN/dpkg-deb" <<'STUB'
#!/usr/bin/env bash
# Reads control fields from a "<deb>.meta" sidecar fixture.
set -euo pipefail
[[ "$1" == "-f" ]] || { echo "stub dpkg-deb: unsupported args" >&2; exit 2; }
deb="$2"; field="$3"
meta="${FAKE_FIXTURES:?}/$(basename "$deb").meta"
line="$(grep "^${field}: " "$meta" 2>/dev/null || true)"
[[ -n "$line" ]] || exit 1
echo "${line#*: }"
STUB

cat > "$BIN/sha256sum" <<'STUB'
#!/usr/bin/env bash
# sha256sum subset backed by shasum: verifies "<hash>  <file>" lines from stdin.
set -euo pipefail
quiet=0
for arg in "$@"; do
  [[ "$arg" == "--status" ]] && quiet=1
done
status=0
while read -r line; do
  [[ -z "$line" ]] && continue
  hash="${line%% *}"
  file="${line#*  }"
  actual="$(shasum -a 256 "$file")"
  actual="${actual%% *}"
  if [[ "$hash" == "$actual" ]]; then
    (( quiet )) || echo "${file}: OK"
  else
    echo "${file}: FAILED" >&2
    status=1
  fi
done
exit $status
STUB
chmod +x "$BIN/curl" "$BIN/dpkg-deb" "$BIN/sha256sum"

map_url() { printf '%s\t%s\n' "$1" "$2" >> "$MAP"; }

map_remove() { # <url>
  awk -F '\t' -v u="$1" '$1 != u' "$MAP" > "${MAP}.tmp" && mv "${MAP}.tmp" "$MAP"
}

# add_deb <repo> <version> <arch> [meta-version] [meta-package] [meta-arch]
add_deb() {
  local repo="$1" version="$2" arch="$3"
  local meta_version="${4:-$version}" meta_package="${5:-$repo}" meta_arch="${6:-$arch}"
  local name="${repo}_${version}_${arch}.deb"
  local file="$FIX/$name"
  printf 'deb-content::%s\n' "$name" > "$file"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' \
    "$meta_package" "$meta_version" "$meta_arch" > "${file}.meta"
  map_url "https://github.com/vmvarela/${repo}/releases/download/v${version}/${name}" "$file"
}

# write_release <repo> <tag> <json-fixture-name> <asset-name>...
write_release() {
  local repo="$1" tag="$2" name="$3"
  shift 3
  local assets="" f
  for f in "$@"; do
    assets+="{\"name\":\"${f}\",\"browser_download_url\":\"https://github.com/vmvarela/${repo}/releases/download/${tag}/${f}\"},"
    if [[ "$f" == *.deb ]]; then
      map_url "https://github.com/vmvarela/${repo}/releases/download/${tag}/${f}" "$FIX/${f}"
    fi
  done
  local json="$FIX/$name"
  # DRAFT/PRERELEASE: false (default), true, raw JSON like '"no"', or
  # "missing" to omit the field entirely.
  local fields=""
  if [[ "${DRAFT:-false}" != "missing" ]]; then
    fields+="\"draft\":${DRAFT:-false},"
  fi
  if [[ "${PRERELEASE:-false}" != "missing" ]]; then
    fields+="\"prerelease\":${PRERELEASE:-false},"
  fi
  printf '{"tag_name":"%s",%s"assets":[%s]}\n' \
    "$tag" "$fields" "${assets%,}" > "$json"
  map_url "https://api.github.com/repos/vmvarela/${repo}/releases/latest" "$json"
  map_url "https://api.github.com/repos/vmvarela/${repo}/releases/tags/${tag}" "$json"
}

# write_sums <repo> <version> <json-fixture-name> <deb-name>...
# Writes a sha256sums.txt fixture and maps its download URL.
write_sums() {
  local repo="$1" version="$2" name="$3"
  shift 3
  local sums="$FIX/${name}"
  : > "$sums"
  local f hash
  for f in "$@"; do
    hash="$(shasum -a 256 "$FIX/$f")"
    printf '%s  %s\n' "${hash%% *}" "$f" >> "$sums"
  done
  map_url "https://github.com/vmvarela/${repo}/releases/download/v${version}/sha256sums.txt" "$sums"
}

map_deployed_index() { # <apt-arch> <fixture-file|""> (empty = unreachable)
  local url="https://vmvarela.github.io/apt-packages/dists/stable/main/binary-$1/Packages"
  if [[ -n "${2:-}" ]]; then
    map_url "$url" "$2"
  fi
}

run_download() { # <target> <sql-pipe-version> <ghoten-version>
  (cd "$WORK" && export FAKE_URL_MAP="$MAP" FAKE_FIXTURES="$FIX" FAKE_CURL_LOG="$CURL_LOG" &&
    PATH="$BIN:$PATH" bash "$SCRIPT" download "$1" "$2" "$3" .)
}

run_resolve() { # <target> [requested-version]
  (cd "$WORK" && export FAKE_URL_MAP="$MAP" FAKE_FIXTURES="$FIX" FAKE_CURL_LOG="$CURL_LOG" &&
    PATH="$BIN:$PATH" bash "$SCRIPT" resolve "$1" "${2:-}")
}

# --- helpers to stage a full valid release set ------------------------------

stage_full_success() {
  local sql_debs=() ghoten_debs=() arch
  for arch in amd64 arm64 armhf i386; do
    add_deb sql-pipe 1.2.3 "$arch"
    sql_debs+=("sql-pipe_1.2.3_${arch}.deb")
  done
  for arch in amd64 arm64; do
    add_deb ghoten 2.0.0 "$arch"
    ghoten_debs+=("ghoten_2.0.0_${arch}.deb")
  done
  write_release sql-pipe v1.2.3 sql-latest.json "${sql_debs[@]}" sha256sums.txt
  write_sums sql-pipe 1.2.3 sql-sums.txt "${sql_debs[@]}"
  write_release ghoten v2.0.0 ghoten-latest.json "${ghoten_debs[@]}" sha256sums.txt
  write_sums ghoten 2.0.0 ghoten-sums.txt "${ghoten_debs[@]}"
}

# The deployed-index fixtures used by the ghoten skip/drop scenarios.
no_ghoten_index="$FIX/index-no-ghoten.txt"
printf 'Package: sql-pipe\nVersion: 1.2.3\nArchitecture: amd64\n' > "$no_ghoten_index"
with_ghoten_index="$FIX/index-with-ghoten.txt"
printf 'Package: sql-pipe\nVersion: 1.2.3\nArchitecture: amd64\n\nPackage: ghoten\nVersion: 2.0.0\nArchitecture: arm64\n' > "$with_ghoten_index"

# --- scenarios --------------------------------------------------------------

# 1. Full success: all DEBs download, verify and index into site/pool.
stage_full_success
map_deployed_index amd64 "$no_ghoten_index"
map_deployed_index arm64 "$no_ghoten_index"
expect_ok "full valid release set downloads and verifies" run_download sql-pipe 1.2.3 2.0.0
if [[ "$(find "$WORK/site/pool" -name '*.deb' | wc -l | tr -d ' ')" == "6" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: expected 6 DEBs in site/pool after success case"
fi
rm -rf "$WORK/site"

# 2. resolve emits versions for the latest stable releases.
expect_ok "resolve picks up latest stable versions" run_resolve sql-pipe
rm -rf "$WORK/site"

# 3. Requested version: tag mismatch is rejected.
reset_map() { rm -f "$MAP"; : > "$MAP"; }
reset_map
stage_full_success
map_remove "https://api.github.com/repos/vmvarela/sql-pipe/releases/tags/v1.2.3"
# The release found at tags/v1.2.3 reports tag_name v1.2.4 -> mismatch.
write_release sql-pipe v1.2.4 sql-requested.json sha256sums.txt
map_url "https://api.github.com/repos/vmvarela/sql-pipe/releases/tags/v1.2.3" "$FIX/sql-requested.json"
expect_fail_msg "requested version whose tag differs is rejected" \
  "does not match expected v1.2.3" run_resolve sql-pipe 1.2.3

# 4. Requested version that does not exist is rejected.
reset_map
stage_full_success
expect_fail "requested version missing from GitHub is rejected" run_resolve sql-pipe 9.9.9

# 5. Prerelease and draft releases are rejected (resolve + download).
reset_map
stage_full_success
PRERELEASE=true write_release sql-pipe v1.2.3 sql-latest.json \
  sql-pipe_1.2.3_amd64.deb sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sql-pipe_1.2.3_i386.deb sha256sums.txt
expect_fail "prerelease latest release is rejected by resolve" run_resolve sql-pipe
expect_fail "prerelease release is rejected by download" run_download sql-pipe 1.2.3 2.0.0
DRAFT=true write_release sql-pipe v1.2.3 sql-latest.json \
  sql-pipe_1.2.3_amd64.deb sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sql-pipe_1.2.3_i386.deb sha256sums.txt
expect_fail "draft release is rejected by resolve" run_resolve sql-pipe

# 6. Checksum mismatch fails before indexing.
rm -f "$MAP"
: > "$MAP"
stage_full_success
printf '0000000000000000000000000000000000000000000000000000000000000000  sql-pipe_1.2.3_amd64.deb\n' \
  > "$FIX/sql-sums.txt"
expect_fail "checksum mismatch fails the build" run_download sql-pipe 1.2.3 2.0.0
if [[ ! -e "$WORK/site/dists" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: dists/ must not be built when verification fails"
fi
rm -rf "$WORK/site"

# 7. DEB missing from sha256sums.txt fails.
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_sums sql-pipe 1.2.3 sql-sums.txt sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sql-pipe_1.2.3_i386.deb
expect_fail "missing checksum entry fails the build" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 8. Package metadata mismatch (wrong Version field) fails.
rm -f "$MAP"
: > "$MAP"
stage_full_success
add_deb sql-pipe 1.2.3 amd64 9.9.9
write_release sql-pipe v1.2.3 sql-latest.json \
  sql-pipe_1.2.3_amd64.deb sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sql-pipe_1.2.3_i386.deb sha256sums.txt
write_sums sql-pipe 1.2.3 sql-sums.txt \
  sql-pipe_1.2.3_amd64.deb sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sql-pipe_1.2.3_i386.deb
expect_fail "wrong Version metadata fails the build" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 9. Asset missing from release JSON fails for sql-pipe (full set required).
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_release sql-pipe v1.2.3 sql-latest.json \
  sql-pipe_1.2.3_amd64.deb sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sha256sums.txt
expect_fail "incomplete sql-pipe asset set fails the build" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 10. One ghoten DEB missing -> incomplete set failure.
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_release ghoten v2.0.0 ghoten-latest.json ghoten_2.0.0_amd64.deb sha256sums.txt
write_sums ghoten 2.0.0 ghoten-sums.txt ghoten_2.0.0_amd64.deb
expect_fail "incomplete ghoten set fails the build" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 11. Ghoten DEBs absent, sql-pipe triggered, deployed index lacks ghoten -> skip.
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_release ghoten v2.0.0 ghoten-latest.json sha256sums.txt
map_deployed_index amd64 "$no_ghoten_index"
map_deployed_index arm64 "$no_ghoten_index"
expect_ok "ghoten skip is allowed when the deployed index lacks ghoten" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 12. Ghoten DEBs absent but deployed index already has ghoten -> refuse to drop.
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_release ghoten v2.0.0 ghoten-latest.json sha256sums.txt
map_deployed_index amd64 "$with_ghoten_index"
map_deployed_index arm64 "$with_ghoten_index"
expect_fail "published ghoten is not silently dropped" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 13. Deployed index unreachable when ghoten would be dropped -> fail closed.
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_release ghoten v2.0.0 ghoten-latest.json sha256sums.txt
expect_fail "unreachable deployed index fails closed" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 13b. One deployed index unreachable, the other reachable without ghoten
#      -> still fail closed; a single reachable index proves nothing.
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_release ghoten v2.0.0 ghoten-latest.json sha256sums.txt
map_deployed_index arm64 "$no_ghoten_index"
expect_fail "partially unreachable deployed index fails closed" run_download sql-pipe 1.2.3 2.0.0
rm -rf "$WORK/site"

# 14. Ghoten-triggered rebuild with no ghoten DEBs at all -> fail.
rm -f "$MAP"
: > "$MAP"
stage_full_success
write_release ghoten v2.0.0 ghoten-latest.json sha256sums.txt
map_deployed_index amd64 "$no_ghoten_index"
map_deployed_index arm64 "$no_ghoten_index"
expect_fail "ghoten-triggered rebuild requires the ghoten DEBs" run_download ghoten 1.2.3 2.0.0
rm -rf "$WORK/site"

# 15. Missing draft flag in the release JSON fails closed.
reset_map
stage_full_success
map_remove "https://api.github.com/repos/vmvarela/sql-pipe/releases/latest"
DRAFT=missing write_release sql-pipe v1.2.3 sql-latest.json \
  sql-pipe_1.2.3_amd64.deb sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sql-pipe_1.2.3_i386.deb sha256sums.txt
expect_fail "missing draft flag fails closed" run_resolve sql-pipe

# 16. Non-boolean prerelease flag fails closed.
reset_map
stage_full_success
map_remove "https://api.github.com/repos/vmvarela/sql-pipe/releases/latest"
PRERELEASE='"false"' write_release sql-pipe v1.2.3 sql-latest.json \
  sql-pipe_1.2.3_amd64.deb sql-pipe_1.2.3_arm64.deb sql-pipe_1.2.3_armhf.deb sql-pipe_1.2.3_i386.deb sha256sums.txt
expect_fail "non-boolean prerelease flag fails closed" run_resolve sql-pipe

# 17. Malformed requested version is rejected before any release-tags fetch.
reset_map
stage_full_success
: > "$CURL_LOG"
expect_fail "malformed requested version is rejected" run_resolve sql-pipe 1.2
if grep -q 'releases/tags/' "$CURL_LOG"; then
  fail=$((fail + 1))
  echo "FAIL: malformed requested version reached the release-tags API"
else
  pass=$((pass + 1))
fi
rm -rf "$WORK/site"

# --- report -----------------------------------------------------------------

echo "tests: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
