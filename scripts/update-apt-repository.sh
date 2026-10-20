#!/usr/bin/env bash
# Shared logic for the APT repository update workflow (issue #29 hardening).
#
# Subcommands:
#   resolve <target> [requested-version]
#       Resolve and validate release versions; emits KEY=VALUE lines
#       (to $GITHUB_OUTPUT when set, stdout otherwise).
#   download <target> <sql-pipe-version> <ghoten-version> [root]
#       Download and verify DEBs into <root>/site/pool, then decide whether
#       the index may be rebuilt. Fails closed on any malformed release,
#       incomplete asset set, or checksum/metadata mismatch.
#
# Network access goes through curl and jq; package metadata through
# dpkg-deb. Tests override these via PATH.
set -euo pipefail

API_BASE="https://api.github.com/repos/vmvarela"
SITE_BASE="https://vmvarela.github.io/apt-packages"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

die() {
  echo "::error::$*" >&2
  exit 1
}

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1" >> "$GITHUB_OUTPUT"
  else
    echo "$1"
  fi
}

# fetch_release <repo> <tag|latest>: print release JSON.
fetch_release() {
  if [[ "$2" == "latest" ]]; then
    curl --fail --silent --show-error "${API_BASE}/${1}/releases/latest"
  else
    curl --fail --silent --show-error "${API_BASE}/${1}/releases/tags/$2"
  fi
}

# Validate a release object is the exact stable, non-draft, non-prerelease
# tag for <version>. validate_release <repo> <version> <json>
validate_release() {
  local repo="$1" version="$2" json="$3" tag
  tag="$(jq -r 'if (.tag_name | type) == "string" then .tag_name else "" end' <<<"$json")"
  if [[ -z "$tag" ]]; then
    die "Release v${version} for ${repo} has no tag_name; refusing to use it."
  fi
  # Fail closed: both flags must exist as JSON booleans and be exactly false.
  if ! jq -e '.draft == false and .prerelease == false' <<<"$json" >/dev/null; then
    die "Release v${version} for ${repo} is not a stable release: draft/prerelease flags are missing, not booleans, or true."
  fi
  if [[ "$tag" != "v${version}" ]]; then
    die "Release tag ${tag} for ${repo} does not match expected v${version}."
  fi
  if [[ ! "$version" =~ $VERSION_RE ]]; then
    die "Invalid stable release version for ${repo}: ${version}"
  fi
}

# asset_url <json> <asset-name>: print the asset's download URL (empty if absent).
asset_url() {
  jq -r --arg name "$2" '[(.assets[]? | select(.name == $name) | .browser_download_url)][0] // empty' <<<"$1"
}

# check_metadata <deb> <package> <version> <arch>: verify control fields.
check_metadata() {
  local deb="$1" package="$2" version="$3" arch="$4" field actual
  for field in Package Version Architecture; do
    actual="$(dpkg-deb -f "$deb" "$field" 2>/dev/null || true)"
    if [[ -z "$actual" ]]; then
      die "Unable to read ${field} from ${deb}; refusing to index a malformed package."
    fi
  done
  [[ "$(dpkg-deb -f "$deb" Package)" == "$package" ]] ||
    die "Package metadata mismatch in ${deb}: expected Package ${package}."
  [[ "$(dpkg-deb -f "$deb" Version)" == "$version" ]] ||
    die "Package metadata mismatch in ${deb}: expected Version ${version}."
  [[ "$(dpkg-deb -f "$deb" Architecture)" == "$arch" ]] ||
    die "Package metadata mismatch in ${deb}: expected Architecture ${arch}."
}

# download_package <repo> <version> <dir> <require-all|yes|no> <arch>...
# Sets DOWNLOAD_PACKAGE_COUNT to the number of DEBs downloaded.
# Version and assets stay tied together: assets are only taken from the
# release object fetched for that exact tag.
download_package() {
  local repo="$1" version="$2" dir="$3" require_all="$4"
  shift 4
  local json file url sha_url sha_tmp line arch count=0
  local -a downloaded=()

  json="$(fetch_release "$repo" "v${version}")"
  validate_release "$repo" "$version" "$json"

  sha_url="$(asset_url "$json" sha256sums.txt)"
  sha_tmp=""
  if [[ -n "$sha_url" ]]; then
    sha_tmp="$(mktemp)"
    curl --fail --silent --show-error --location "$sha_url" > "$sha_tmp"
  fi

  for arch in "$@"; do
    file="${repo}_${version}_${arch}.deb"
    url="$(asset_url "$json" "$file")"
    if [[ -z "$url" ]]; then
      if [[ "$require_all" == "yes" ]]; then
        die "Release v${version} of ${repo} is missing asset ${file}; refusing to rebuild the index."
      fi
      echo "Ghoten native package not available yet: ${file}" >&2
      continue
    fi
    mkdir -p "$dir"
    curl --fail --silent --show-error --location "$url" -o "${dir}/${file}"
    check_metadata "${dir}/${file}" "$repo" "$version" "$arch"
    downloaded+=("$file")
    count=$((count + 1))
  done

  if (( count > 0 )); then
    if [[ -z "$sha_tmp" ]]; then
      die "Release v${version} of ${repo} has no sha256sums.txt asset; refusing to index unverified DEBs."
    fi
    for file in "${downloaded[@]}"; do
      line="$(awk -v f="$file" '$2 == f {print; exit}' "$sha_tmp")"
      if [[ -z "$line" ]]; then
        die "Checksum entry for ${file} missing from ${repo} v${version} sha256sums.txt."
      fi
      if ! (cd "$dir" && printf '%s\n' "$line" | sha256sum --check --status); then
        die "Checksum mismatch for ${file} in ${repo} v${version}."
      fi
    done
  fi
  rm -f "$sha_tmp"
  DOWNLOAD_PACKAGE_COUNT=$count
}

# Fail closed if any deployed index cannot be read and ghoten may be dropped.
deployed_index_has_ghoten() {
  local apt_arch content
  for apt_arch in amd64 arm64; do
    if content="$(curl --fail --silent --show-error "${SITE_BASE}/dists/stable/main/binary-${apt_arch}/Packages")"; then
      if grep -q '^Package: ghoten' <<<"$content"; then
        return 0
      fi
    else
      die "Unable to read the deployed APT repository (${apt_arch} index) to check for existing ghoten packages."
    fi
  done
  return 1
}

cmd_resolve() {
  local target="$1" requested="${2:-}"
  local repo json tag version
  for repo in sql-pipe ghoten; do
    json="$(fetch_release "$repo" latest)"
    tag="$(jq -r '.tag_name // empty' <<<"$json")"
    version="${tag#v}"
    validate_release "$repo" "$version" "$json"
    if [[ "$repo" == "$target" && -n "$requested" ]]; then
      requested="${requested#v}"
      if [[ ! "$requested" =~ $VERSION_RE ]]; then
        die "Requested version for ${repo} is not a valid stable version (expected X.Y.Z): ${requested}"
      fi
      json="$(fetch_release "$repo" "v${requested}")" ||
        die "Requested release v${requested} for ${repo} not found."
      version="$requested"
      validate_release "$repo" "$version" "$json"
    fi
    if [[ "$repo" == "sql-pipe" ]]; then
      sql_pipe_version="$version"
    else
      ghoten_version="$version"
    fi
  done
  emit "target=$target"
  emit "sql_pipe_version=$sql_pipe_version"
  emit "ghoten_version=$ghoten_version"
  echo "Rebuilding APT repository: sql-pipe=$sql_pipe_version, ghoten=$ghoten_version" >&2
}

cmd_download() {
  local target="$1" sql_pipe_version="$2" ghoten_version="$3"
  local root="${4:-.}"
  mkdir -p "$root/site/pool/main/s/sql-pipe" "$root/site/pool/main/g/ghoten"

  download_package sql-pipe "$sql_pipe_version" "$root/site/pool/main/s/sql-pipe" yes amd64 arm64 armhf i386

  download_package ghoten "$ghoten_version" "$root/site/pool/main/g/ghoten" no amd64 arm64
  local ghoten_count="$DOWNLOAD_PACKAGE_COUNT"

  if (( ghoten_count == 1 )); then
    die "Ghoten package set is incomplete; refusing to publish an index missing one of amd64/arm64. Retry once assets are available."
  fi
  if (( ghoten_count == 0 )); then
    if [[ "$target" == "ghoten" ]]; then
      die "A Ghoten-triggered rebuild requires both Ghoten DEB packages."
    fi
    if deployed_index_has_ghoten; then
      die "ghoten is already published in the deployed repository; refusing to silently drop it. Retry once assets are reachable."
    fi
    echo '::notice::Ghoten native packages are not available yet; skipping ghoten'
  fi

  find "$root/site/pool" -maxdepth 5 -type f -print | sort
}

case "${1:-}" in
  resolve) shift; cmd_resolve "$@" ;;
  download) shift; cmd_download "$@" ;;
  *) die "usage: $0 {resolve <target> [requested-version] | download <target> <sql-pipe-version> <ghoten-version> [root]}" ;;
esac
