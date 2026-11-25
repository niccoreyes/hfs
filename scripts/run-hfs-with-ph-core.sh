#!/usr/bin/env bash
set -euo pipefail

# Run HFS + HTS with PH Core 0.2.1 R4, its pinned NPM dependency closure,
# local LOINC, and the local SNOMED GPS release. HFS loads PH Core profiles and
# referenced extension definitions, and activates the PH Core Practitioner
# identifier override. The GPS CodeSystem is flat: membership/display only.
#
# Profile registries are process-local, so this runner loads definitions into
# this HFS process before reporting ready. Default databases: ./fhir.db and
# ./data/hts.db. Local terminology ZIPs are not copied into the repository.

readonly PH_CORE_VERSION="0.2.1"
readonly PH_CORE_NAME="fhir.ph.core.r4"
readonly PH_CORE_URL="https://github.com/UPM-NTHC/ph-core/releases/download/0.2.1/package.r4.tgz"
readonly PH_CORE_SHA256="c9d239dbf8ec55e7f3e2234cd7d02ee294605f8bc5cba8377b00871c65f1f069"
readonly PH_CORE_SP_ID="practitioner-identifier"
readonly PH_CORE_SP_URL="https://fhir.doh.gov.ph/phcore/SearchParameter/practitioner-identifier"
readonly PH_CORE_SP_EXPRESSION="Practitioner.identifier | Practitioner.qualification.identifier"

# Direct and transitive dependencies from the pinned package manifests.
readonly EXT_R4_53_NAME="hl7.fhir.uv.extensions.r4"
readonly EXT_R4_53_VERSION="5.3.0"
readonly EXT_R4_53_URL="https://packages.fhir.org/hl7.fhir.uv.extensions.r4/5.3.0"
readonly EXT_R4_53_SHA256="dfbc3ac95df91ed845cc6b60920d2875f679361fa0e16f227cee93c4a9ab2104"
readonly THO_R4_74_NAME="hl7.terminology.r4"
readonly THO_R4_74_VERSION="7.4.0"
readonly THO_R4_74_URL="https://packages.fhir.org/hl7.terminology.r4/7.4.0"
readonly THO_R4_74_SHA256="1dc558c204f5ee1f2b96ab9a8cd83d0811475b08a4e06a7c2bcea55d1ab116ed"
readonly THO_R4_71_NAME="hl7.terminology.r4"
readonly THO_R4_71_VERSION="7.1.0"
readonly THO_R4_71_URL="https://packages.fhir.org/hl7.terminology.r4/7.1.0"
readonly THO_R4_71_SHA256="1cb0cd5601972925fcd04f2c175d9cc63a9ecd9346a91a6e735f1a865dc5fba1"
readonly EXT_R4_52_NAME="hl7.fhir.uv.extensions.r4"
readonly EXT_R4_52_VERSION="5.2.0"
readonly EXT_R4_52_URL="https://packages.fhir.org/hl7.fhir.uv.extensions.r4/5.2.0"
readonly EXT_R4_52_SHA256="b406e75575f05676559d0759770c5939d023ee72fb2ef38e0b3259328487720a"
readonly R4_VERSION="4.0.1"
readonly EXPECTED_PH_CORE_SD_COUNT=35
readonly EXPECTED_EXTENSION_SD_COUNT=18
readonly SNOMED_GPS_VERSION="20260101"

readonly -a EXTENSION_PROFILE_IDS=(
  elementdefinition-bestpractice
  elementdefinition-bestpractice-explanation
  elementdefinition-bindingName
  elementdefinition-isCommonBinding
  elementdefinition-maxValueSet
  elementdefinition-suppress
  elementdefinition-translatable
  obligation
  structuredefinition-display-hint
  structuredefinition-fhir-type
  structuredefinition-fmm
  structuredefinition-hierarchy
  structuredefinition-standards-status
  structuredefinition-standards-status-reason
  structuredefinition-type-characteristics
  structuredefinition-wg
  targetConstraint
  version-specific-use
)

CHECK_ONLY=false
if [[ "${1:-}" == "--check-only" ]]; then
  CHECK_ONLY=true
  shift
fi
if [[ "$#" -gt 0 ]]; then
  printf 'Unexpected argument: %s\nUsage: %s [--check-only]\n' "$1" "$0" >&2
  exit 2
fi

for tool in awk cargo curl grep jq lsof python3 shasum tar unzip cp ln; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
LOINC_ZIP="${HFS_PH_CORE_LOINC_ZIP:-$REPO_ROOT/Loinc_2.83.zip}"
SNOMED_GPS_ZIP="${HFS_PH_CORE_SNOMED_GPS_ZIP:-$REPO_ROOT/SnomedINTL_GPSRelease_PRODUCTION_20260101T120000Z.zip}"
if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
  CACHE_ROOT="$XDG_CACHE_HOME"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  CACHE_ROOT="${HOME:?HOME is not set}/Library/Caches"
else
  CACHE_ROOT="${HOME:?HOME is not set}/.cache"
fi
PH_CORE_CACHE_DIR="${HFS_PH_CORE_CACHE_DIR:-$CACHE_ROOT/hfs/ph-core/$PH_CORE_VERSION}"
PACKAGE_CACHE_DIR="$PH_CORE_CACHE_DIR/packages"
HTS_BOOTSTRAP_DIR="${HFS_PH_CORE_HTS_BOOTSTRAP_DIR:-$PH_CORE_CACHE_DIR/hts-bootstrap}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hfs-ph-core.XXXXXX")"
HFS_PID=""
HTS_PID=""
HTS_READY_TIMEOUT_SECS="${HFS_PH_CORE_HTS_READY_TIMEOUT_SECS:-900}"

cleanup() {
  if [[ -n "$HFS_PID" ]] && kill -0 "$HFS_PID" 2>/dev/null; then
    kill "$HFS_PID" 2>/dev/null || true
    wait "$HFS_PID" 2>/dev/null || true
  fi
  if [[ -n "$HTS_PID" ]] && kill -0 "$HTS_PID" 2>/dev/null; then
    kill "$HTS_PID" 2>/dev/null || true
    wait "$HTS_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$PACKAGE_CACHE_DIR" "$HTS_BOOTSTRAP_DIR"
for zip_path in "$LOINC_ZIP" "$SNOMED_GPS_ZIP"; do
  [[ -f "$zip_path" ]] || { printf 'Terminology archive not found: %s\n' "$zip_path" >&2; exit 1; }
  unzip -tqq "$zip_path" || { printf 'Invalid ZIP archive: %s\n' "$zip_path" >&2; exit 1; }
done
unzip -Z1 "$LOINC_ZIP" | grep -Fx 'LoincTable/Loinc.csv' >/dev/null || {
  printf 'LOINC archive lacks LoincTable/Loinc.csv: %s\n' "$LOINC_ZIP" >&2
  exit 1
}
unzip -Z1 "$SNOMED_GPS_ZIP" \
  | grep -Fx "SnomedINTL_GPSRelease_PRODUCTION_${SNOMED_GPS_VERSION}T120000Z.txt" >/dev/null || {
    printf 'SNOMED GPS archive lacks its expected %s TSV.\n' "$SNOMED_GPS_VERSION" >&2
    exit 1
  }

download_verified() {
  local filename="$1" url="$2" expected_sha256="$3"
  local destination="$PACKAGE_CACHE_DIR/$filename" actual_sha256
  if [[ -f "$destination" ]] \
    && [[ "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected_sha256" ]]; then
    printf 'Using cached, verified %s.\n' "$filename" >&2
  else
    printf 'Downloading %s...\n' "$filename" >&2
    if ! curl --fail --location --silent --show-error \
      --output "$destination.tmp" "$url"; then
      rm -f "$destination.tmp"
      printf 'Download failed for %s.\n' "$filename" >&2
      return 1
    fi
    actual_sha256="$(shasum -a 256 "$destination.tmp" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      rm -f "$destination.tmp"
      printf 'SHA-256 mismatch for %s.\n' "$filename" >&2
      return 1
    fi
    mv "$destination.tmp" "$destination"
  fi
  printf '%s\n' "$destination"
}

verify_package() {
  local path="$1" expected_name="$2" expected_version="$3"
  tar -xOf "$path" package/package.json | jq --exit-status \
    --arg name "$expected_name" --arg version "$expected_version" \
    --arg fhir_version "$R4_VERSION" \
    '(.name == $name) and (.version == $version) and (.fhirVersions | index($fhir_version) != null)' \
    >/dev/null || {
      printf 'Package manifest mismatch in %s (expected %s#%s, FHIR %s).\n' \
        "$path" "$expected_name" "$expected_version" "$R4_VERSION" >&2
      return 1
    }
}

PH_CORE_PACKAGE="$(download_verified package.r4.tgz "$PH_CORE_URL" "$PH_CORE_SHA256")"
EXT_R4_53_PACKAGE="$(download_verified "$EXT_R4_53_NAME-$EXT_R4_53_VERSION.tgz" "$EXT_R4_53_URL" "$EXT_R4_53_SHA256")"
THO_R4_74_PACKAGE="$(download_verified "$THO_R4_74_NAME-$THO_R4_74_VERSION.tgz" "$THO_R4_74_URL" "$THO_R4_74_SHA256")"
THO_R4_71_PACKAGE="$(download_verified "$THO_R4_71_NAME-$THO_R4_71_VERSION.tgz" "$THO_R4_71_URL" "$THO_R4_71_SHA256")"
EXT_R4_52_PACKAGE="$(download_verified "$EXT_R4_52_NAME-$EXT_R4_52_VERSION.tgz" "$EXT_R4_52_URL" "$EXT_R4_52_SHA256")"

verify_package "$PH_CORE_PACKAGE" "$PH_CORE_NAME" "$PH_CORE_VERSION"
verify_package "$EXT_R4_53_PACKAGE" "$EXT_R4_53_NAME" "$EXT_R4_53_VERSION"
verify_package "$THO_R4_74_PACKAGE" "$THO_R4_74_NAME" "$THO_R4_74_VERSION"
verify_package "$THO_R4_71_PACKAGE" "$THO_R4_71_NAME" "$THO_R4_71_VERSION"
verify_package "$EXT_R4_52_PACKAGE" "$EXT_R4_52_NAME" "$EXT_R4_52_VERSION"
tar -xOf "$PH_CORE_PACKAGE" package/package.json | jq --exit-status \
  '.dependencies["hl7.fhir.r4.core"] == "4.0.1" and .dependencies["hl7.terminology.r4"] == "7.4.0" and .dependencies["hl7.fhir.uv.extensions.r4"] == "5.3.0"' >/dev/null
tar -xOf "$EXT_R4_53_PACKAGE" package/package.json | jq --exit-status \
  '.dependencies["hl7.fhir.r4.core"] == "4.0.1" and .dependencies["hl7.terminology.r4"] == "7.1.0"' >/dev/null
tar -xOf "$THO_R4_71_PACKAGE" package/package.json | jq --exit-status \
  '.dependencies["hl7.fhir.r4.core"] == "4.0.1" and .dependencies["hl7.fhir.uv.extensions.r4"] == "5.2.0"' >/dev/null
tar -xOf "$EXT_R4_52_PACKAGE" package/package.json | jq --exit-status \
  '.dependencies["hl7.fhir.r4.core"] == "4.0.1"' >/dev/null
tar -xOf "$THO_R4_74_PACKAGE" package/package.json | jq --exit-status \
  '.dependencies["hl7.fhir.r4.core"] == "4.0.1"' >/dev/null

CORE_R4_PACKAGE="$REPO_ROOT/crates/hts/terminology-data/hl7.fhir.r4.core-4.0.1.tgz"
[[ -f "$CORE_R4_PACKAGE" ]] || { printf 'Bundled R4 core package missing: %s\n' "$CORE_R4_PACKAGE" >&2; exit 1; }
tar -xOf "$CORE_R4_PACKAGE" package/package.json | jq --exit-status \
  --arg name hl7.fhir.r4.core --arg version "$R4_VERSION" \
  '(.name == $name) and (.version == $version)' >/dev/null

# Build and cache a local NPM CodeSystem package from the provided GPS TSV.
SNOMED_GPS_PACKAGE="$PACKAGE_CACHE_DIR/snomed-gps-r4-$SNOMED_GPS_VERSION.tgz"
SNOMED_GPS_MARKER="$PACKAGE_CACHE_DIR/.snomed-gps-$SNOMED_GPS_VERSION.sha256"
SNOMED_GPS_SOURCE_SHA256="$(shasum -a 256 "$SNOMED_GPS_ZIP" | awk '{print $1}')"
CACHED_GPS_SHA256=""
if [[ -f "$SNOMED_GPS_MARKER" ]]; then
  IFS= read -r CACHED_GPS_SHA256 < "$SNOMED_GPS_MARKER" || true
fi
if [[ ! -f "$SNOMED_GPS_PACKAGE" || "$CACHED_GPS_SHA256" != "$SNOMED_GPS_SOURCE_SHA256" ]]; then
  python3 "$SCRIPT_DIR/snomed-gps-to-hts-package.py" \
    "$SNOMED_GPS_ZIP" "$SNOMED_GPS_PACKAGE" "$SNOMED_GPS_VERSION"
  printf '%s\n' "$SNOMED_GPS_SOURCE_SHA256" > "$SNOMED_GPS_MARKER.tmp"
  mv "$SNOMED_GPS_MARKER.tmp" "$SNOMED_GPS_MARKER"
fi
verify_package "$SNOMED_GPS_PACKAGE" snomed.gps.r4 "$SNOMED_GPS_VERSION"

# Compose default HTS seeds and the requested terminology files in one stable
# bootstrap directory. HTS hashes files, skipping unchanged inputs on restart.
for package in "$CORE_R4_PACKAGE" "$PH_CORE_PACKAGE" "$EXT_R4_53_PACKAGE" \
  "$THO_R4_74_PACKAGE" "$THO_R4_71_PACKAGE" "$EXT_R4_52_PACKAGE" "$SNOMED_GPS_PACKAGE"; do
  cp -f "$package" "$HTS_BOOTSTRAP_DIR/$(basename "$package")"
done
for seed_file in "$REPO_ROOT"/crates/hts/terminology-data/*; do
  [[ -f "$seed_file" ]] || continue
  seed_destination="$HTS_BOOTSTRAP_DIR/$(basename "$seed_file")"
  [[ -e "$seed_destination" ]] || ln -s "$seed_file" "$seed_destination"
done
ln -sf "$LOINC_ZIP" "$HTS_BOOTSTRAP_DIR/$(basename "$LOINC_ZIP")"

PH_CORE_DIR="$WORK_DIR/ph-core"
EXT_R4_DIR="$WORK_DIR/extensions-r4"
mkdir -p "$PH_CORE_DIR" "$EXT_R4_DIR"
tar -xzf "$PH_CORE_PACKAGE" -C "$PH_CORE_DIR"
tar -xzf "$EXT_R4_53_PACKAGE" -C "$EXT_R4_DIR"
PH_CORE_SD_COUNT=0
for sd in "$PH_CORE_DIR"/package/StructureDefinition-*.json; do
  [[ -f "$sd" ]] || continue
  PH_CORE_SD_COUNT=$((PH_CORE_SD_COUNT + 1))
done
[[ "$PH_CORE_SD_COUNT" -eq "$EXPECTED_PH_CORE_SD_COUNT" ]] || {
  printf 'Expected %s PH Core StructureDefinitions, found %s.\n' "$EXPECTED_PH_CORE_SD_COUNT" "$PH_CORE_SD_COUNT" >&2
  exit 1
}
for profile_id in "${EXTENSION_PROFILE_IDS[@]}"; do
  [[ -f "$EXT_R4_DIR/package/StructureDefinition-$profile_id.json" ]] || {
    printf 'Missing referenced extension definition: %s\n' "$profile_id" >&2
    exit 1
  }
done

PH_CORE_SEARCH_PARAMETER="$PH_CORE_DIR/package/SearchParameter-practitioner-identifier.json"
ACTIVE_SEARCH_PARAMETER="$WORK_DIR/SearchParameter-practitioner-identifier-active.json"
jq --exit-status --arg url "$PH_CORE_SP_URL" --arg expr "$PH_CORE_SP_EXPRESSION" \
  '.url == $url and .status == "draft" and .base == ["Practitioner"] and .code == "identifier" and .type == "token" and .expression == $expr' \
  "$PH_CORE_SEARCH_PARAMETER" >/dev/null || {
    printf 'PH Core Practitioner identifier SearchParameter differs from expected draft.\n' >&2
    exit 1
  }
jq '.status = "active"' "$PH_CORE_SEARCH_PARAMETER" > "$ACTIVE_SEARCH_PARAMETER"

if [[ "$CHECK_ONLY" == true ]]; then
  printf 'Checks passed: packages, local LOINC/GPS archives, %s PH Core SDs, %s extension SDs, active-SP source.\n' \
    "$PH_CORE_SD_COUNT" "${#EXTENSION_PROFILE_IDS[@]}"
  printf 'HFS and HTS were not started.\n'
  exit 0
fi

SERVER_PORT="${HFS_SERVER_PORT:-8080}"
HTS_PORT="${HTS_SERVER_PORT:-8090}"
BOOTSTRAP_URL="${HFS_BOOTSTRAP_URL:-http://127.0.0.1:${SERVER_PORT}}"
HTS_URL="http://127.0.0.1:${HTS_PORT}"
for port in "$SERVER_PORT" "$HTS_PORT"; do
  LISTENER_PIDS="$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -z "$LISTENER_PIDS" ]] || { printf 'Port %s already has a listener.\n' "$port" >&2; exit 1; }
done

export HTS_SERVER_HOST=127.0.0.1
export HTS_SERVER_PORT="$HTS_PORT"
export HTS_BOOTSTRAP_DIR="$HTS_BOOTSTRAP_DIR"
export HTS_DATABASE_URL="${HTS_DATABASE_URL:-./data/hts.db}"
export HFS_SERVER_HOST=127.0.0.1
export HFS_SERVER_PORT="$SERVER_PORT"
export HFS_BASE_URL="${HFS_BASE_URL:-http://127.0.0.1:${SERVER_PORT}}"
export HFS_TERMINOLOGY_SERVER="$HTS_URL"
export FHIRPATH_TERMINOLOGY_SERVER="$HTS_URL"
export HFS_VALIDATION_MODE=enforce
export HFS_VALIDATION_META_PROFILES=true
export HFS_VALIDATION_STORED_PROFILES=true
export HFS_VALIDATION_UNKNOWN_PROFILE=error
export HFS_VALIDATION_TERMINOLOGY=remote
export HFS_VALIDATION_TERMINOLOGY_FAIL=closed

cd "$REPO_ROOT"
BUILD_PROFILE="${HFS_BUILD_PROFILE:-debug}"
case "$BUILD_PROFILE" in
  debug)
    printf 'Building HFS and HTS (debug)...\n'
    cargo build -p helios-hfs --bin hfs -p helios-hts --bin hts
    BIN_DIR="$REPO_ROOT/target/debug"
    ;;
  release)
    printf 'Building HFS and HTS (release)...\n'
    cargo build --release -p helios-hfs --bin hfs -p helios-hts --bin hts
    BIN_DIR="$REPO_ROOT/target/release"
    ;;
  *) printf 'HFS_BUILD_PROFILE must be debug or release.\n' >&2; exit 2 ;;
esac

printf 'Starting HTS on 127.0.0.1:%s; first bootstrap can take several minutes.\n' "$HTS_PORT"
"$BIN_DIR/hts" &
HTS_PID=$!
HTS_READY=false
for _ in $(seq 1 "$HTS_READY_TIMEOUT_SECS"); do
  kill -0 "$HTS_PID" 2>/dev/null || { wait "$HTS_PID" || true; printf 'HTS exited before ready.\n' >&2; exit 1; }
  if curl --fail --silent --show-error --max-time 2 "$HTS_URL/health" >/dev/null 2>&1; then
    HTS_READY=true
    break
  fi
  sleep 1
done
[[ "$HTS_READY" == true ]] || { printf 'HTS did not become healthy within %ss.\n' "$HTS_READY_TIMEOUT_SECS" >&2; exit 1; }

printf 'Starting HFS on 127.0.0.1:%s...\n' "$SERVER_PORT"
"$BIN_DIR/hfs" &
HFS_PID=$!
HFS_READY=false
for _ in $(seq 1 60); do
  kill -0 "$HFS_PID" 2>/dev/null || { wait "$HFS_PID" || true; printf 'HFS exited before ready.\n' >&2; exit 1; }
  if curl --fail --silent --show-error --max-time 2 "$BOOTSTRAP_URL/metadata" >/dev/null 2>&1; then
    HFS_READY=true
    break
  fi
  sleep 1
done
[[ "$HFS_READY" == true ]] || { printf 'HFS did not become healthy within 60s.\n' >&2; exit 1; }

put_resource() {
  local type="$1" id="$2" file="$3" resp="$WORK_DIR/response.json" status
  status="$(curl --silent --show-error --output "$resp" --write-out '%{http_code}' \
    --request PUT "$BOOTSTRAP_URL/$type/$id" --header 'Content-Type: application/fhir+json' \
    --data-binary "@$file")"
  case "$status" in
    200|201) ;;
    *) printf 'PUT %s/%s failed (HTTP %s):\n' "$type" "$id" "$status" >&2; cat "$resp" >&2; return 1 ;;
  esac
  curl --fail --silent --show-error "$BOOTSTRAP_URL/$type/$id" \
    | jq --exit-status --arg id "$id" '.id == $id' >/dev/null
}

printf 'Registering PH Core and referenced extension profiles...\n'
IMPORTED_COUNT=0
for profile_id in "${EXTENSION_PROFILE_IDS[@]}"; do
  put_resource StructureDefinition "$profile_id" "$EXT_R4_DIR/package/StructureDefinition-$profile_id.json"
  IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
done
for sd in "$PH_CORE_DIR"/package/StructureDefinition-*.json; do
  [[ -f "$sd" ]] || continue
  profile_id="$(jq --exit-status --raw-output '.id | strings' "$sd")"
  put_resource StructureDefinition "$profile_id" "$sd"
  IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
done
EXPECTED_TOTAL=$((EXPECTED_PH_CORE_SD_COUNT + EXPECTED_EXTENSION_SD_COUNT))
[[ "$IMPORTED_COUNT" -eq "$EXPECTED_TOTAL" ]] || { printf 'Imported %s profiles; expected %s.\n' "$IMPORTED_COUNT" "$EXPECTED_TOTAL" >&2; exit 1; }

printf 'Activating the PH Core Practitioner identifier SearchParameter...\n'
put_resource SearchParameter "$PH_CORE_SP_ID" "$ACTIVE_SEARCH_PARAMETER"
if ! curl --fail --silent --show-error "$BOOTSTRAP_URL/metadata" \
  | jq --exit-status --arg expected_url "$PH_CORE_SP_URL" \
    '[.rest[]?.resource[]? | select(.type == "Practitioner") | .searchParam[]? | select(.name == "identifier" and .definition == $expected_url)] | length == 1' >/dev/null; then
  printf 'CapabilityStatement does not advertise the active PH Core Practitioner identifier override.\n' >&2
  exit 1
fi

printf 'Loaded %s PH Core/support profiles; activated the Practitioner.identifier override.\n' "$IMPORTED_COUNT"
printf 'HTS contains LOINC 2.83 and the flat SNOMED GPS set. GPS supports membership/display, not hierarchy.\n'
printf 'HFS: %s/ui | HTS: %s/ui/hts\n' "$BOOTSTRAP_URL" "$HTS_URL"
printf 'Press Ctrl-C to stop both servers.\n'
wait "$HFS_PID"
