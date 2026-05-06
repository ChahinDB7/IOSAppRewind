#!/bin/bash

# install_ipa.sh — list / download a specific App Store version of an iOS app via ipatool.
#
# Usage:
#   ./install_ipa.sh --app-id ID                            # list every version (parallel)
#   ./install_ipa.sh --app-id ID --version VER              # download by version string
#   ./install_ipa.sh --app-id ID --id EXT_ID                # download by external version id
#   ./install_ipa.sh --version VER                          # resolve app from .cache, download
#   ./install_ipa.sh --id EXT_ID                            # resolve app from .cache, download
#   ./install_ipa.sh --app-id ID --output-folder PATH ...
#   ./install_ipa.sh --app-id ID --refresh                  # ignore cache, re-fetch from Apple
#
# Caches per-app version metadata in ./.cache/versions.json so subsequent runs are instant.

# --- Defaults ---
OUTPUT_DIR="./.output"
CACHE_DIR="./.cache"
CACHE_FILE="$CACHE_DIR/versions.json"
REFRESH_CACHE=false
PARALLEL=10

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --app-id)        APP_ID="$2"; shift 2 ;;
    --version)       TARGET_VERSION="$2"; shift 2 ;;
    --id)            TARGET_ID="$2"; shift 2 ;;
    --output-folder) OUTPUT_DIR="$2"; shift 2 ;;
    --refresh)       REFRESH_CACHE=true; shift ;;
    *)               echo "Unknown option $1"; exit 1 ;;
  esac
done

# --- Validation ---
if [ -z "$APP_ID" ] && [ -z "$TARGET_VERSION" ] && [ -z "$TARGET_ID" ]; then
    cat <<USAGE
❌ Error: must provide at least --app-id, --version, or --id.

Usage:
  $0 --app-id ID                     # list versions
  $0 --app-id ID --version VER       # download by version
  $0 --app-id ID --id EXT_ID         # download by external id
  $0 --version VER                   # resolve app from .cache, download
  $0 --id EXT_ID                     # resolve app from .cache, download
  $0 --output-folder PATH ...        # override default ($OUTPUT_DIR)
  $0 --refresh ...                   # ignore cache, re-fetch from Apple
USAGE
    exit 1
fi

# --- Dependency Check ---
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Error: 'jq' is required. Install with: brew install jq"
    exit 1
fi
if ! command -v ipatool >/dev/null 2>&1; then
    echo "❌ Error: 'ipatool' is required. Install with: brew install ipatool"
    exit 1
fi

# --- Auth Check ---
if ! ipatool auth info --format json >/dev/null 2>&1; then
    echo "❌ Not signed in to ipatool."
    echo "   Run: ipatool auth login --email <APPLE_ID>"
    exit 1
fi

# --- Paths ---
OUTPUT_DIR="${OUTPUT_DIR%/}"
mkdir -p "$CACHE_DIR"

# --- Resolve APP_ID from cache when omitted ---
if [ -z "$APP_ID" ]; then
    if [ ! -f "$CACHE_FILE" ]; then
        echo "❌ Error: --app-id is required when no cache exists at $CACHE_FILE."
        exit 1
    fi

    if [ -n "$TARGET_VERSION" ]; then
        matches=$(jq -c --arg v "$TARGET_VERSION" \
            '[.[] | select(.versions | map(.version) | index($v))]' "$CACHE_FILE")
        lookup_label="version $TARGET_VERSION"
    else
        matches=$(jq -c --arg id "$TARGET_ID" \
            '[.[] | select(.versions | map(.external_id) | index($id))]' "$CACHE_FILE")
        lookup_label="external_id $TARGET_ID"
    fi

    count=$(echo "$matches" | jq 'length')
    if [ "$count" = "0" ]; then
        echo "❌ Could not resolve app from cache for $lookup_label."
        echo "   Provide --app-id explicitly so the version list can be fetched."
        exit 1
    elif [ "$count" -gt 1 ]; then
        echo "❌ Ambiguous: multiple cached apps contain $lookup_label. Specify --app-id."
        echo "$matches" | jq -r '.[] | "   - \(.app_id) (\(.name))"'
        exit 1
    fi

    APP_ID=$(echo "$matches" | jq -r '.[0].app_id')
    resolved_name=$(echo "$matches" | jq -r '.[0].name')
    echo "🔎 Resolved app from cache: $APP_ID (\"$resolved_name\")"
fi

echo "---------------------------------------"
echo "Targeting App ID : $APP_ID"
[ -n "$TARGET_VERSION" ] && echo "Targeting Version: $TARGET_VERSION"
[ -n "$TARGET_ID" ]      && echo "Targeting Ext. ID: $TARGET_ID"
echo "---------------------------------------"

# --- Helper: fetch displayVersion for a given external version id ---
fetch_version() {
    local id="$1"
    local app_id="$2"
    local output
    output=$(ipatool get-version-metadata -i "$app_id" --external-version-id "$id" --format json 2>&1)
    echo "$output" | sed -n 's/.*"displayVersion":"\([^"]*\)".*/\1/p' | tr -d '[:space:]' | tr -d '\r'
}
export -f fetch_version

# --- Try cache for this APP_ID ---
cached_versions=""
cached_name=""

if [ "$REFRESH_CACHE" = false ] && [ -f "$CACHE_FILE" ]; then
    cached_entry=$(jq -c --arg id "$APP_ID" '.[] | select((.app_id|tostring) == $id)' "$CACHE_FILE" 2>/dev/null)
    if [ -n "$cached_entry" ]; then
        cached_versions=$(echo "$cached_entry" | jq -c '.versions')
        cached_name=$(echo "$cached_entry" | jq -r '.name')
        cached_count=$(echo "$cached_versions" | jq 'length')
        echo "💾 Cache hit: $cached_count versions for \"$cached_name\" (use --refresh to re-fetch)"
        echo "---------------------------------------"
    fi
fi

# --- Cache miss: fetch from Apple ---
if [ -z "$cached_versions" ]; then
    echo "Step 1: Ensuring app is licensed..."
    ipatool purchase -i "$APP_ID" > /dev/null 2>&1

    echo "Step 2: Fetching version list..."
    raw_ids=$(ipatool list-versions -i "$APP_ID" --format json 2>&1 \
        | grep -o '"externalVersionIdentifiers":\[[^]]*\]' \
        | sed 's/"externalVersionIdentifiers":\[//;s/\]//;s/"//g;s/,/ /g')
    ids=($raw_ids)

    if [ ${#ids[@]} -eq 0 ]; then
        echo "❌ Error: No version IDs found for App ID $APP_ID."
        exit 1
    fi

    echo "Step 3: Fetching metadata for ${#ids[@]} versions in parallel ($PARALLEL workers)..."
    raw_results=$(printf '%s\n' "${ids[@]}" | xargs -n1 -P"$PARALLEL" -I{} bash -c '
        id="$1"; app_id="$2"
        v=$(fetch_version "$id" "$app_id")
        [ -n "$v" ] && printf "%s %s\n" "$id" "$v"
    ' _ {} "$APP_ID")

    app_name=$(curl -s "https://itunes.apple.com/lookup?id=$APP_ID" 2>/dev/null \
        | jq -r '.results[0].trackName // ""' 2>/dev/null)
    [ -z "$app_name" ] && app_name="App $APP_ID"

    cached_versions=$(echo "$raw_results" | jq -R -s -c '
        split("\n") | map(select(length > 0)) | map(
            split(" ") | {external_id: .[0], version: .[1]}
        ) | sort_by(.external_id | tonumber)
    ')

    new_entry=$(jq -n --arg id "$APP_ID" --arg name "$app_name" --argjson versions "$cached_versions" \
        '{app_id: $id, name: $name, versions: $versions}')

    if [ -f "$CACHE_FILE" ]; then
        jq --argjson new "$new_entry" --arg id "$APP_ID" \
            'map(select((.app_id|tostring) != $id)) + [$new]' \
            "$CACHE_FILE" > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
    else
        echo "[$new_entry]" | jq '.' > "$CACHE_FILE"
    fi

    cached_count=$(echo "$cached_versions" | jq 'length')
    echo "💾 Cached $cached_count versions for \"$app_name\" -> $CACHE_FILE"
    echo "---------------------------------------"
fi

# --- List-only mode (no --version, no --id) ---
if [ -z "$TARGET_VERSION" ] && [ -z "$TARGET_ID" ]; then
    echo "Available versions:"
    echo "---------------------------------------"
    echo "$cached_versions" | jq -r '.[] | "ID: \(.external_id) -> \(.version)"'
    echo "---------------------------------------"
    echo "✅ Done."
    exit 0
fi

# --- Resolve match_id (and back-fill TARGET_VERSION when --id was used) ---
if [ -n "$TARGET_ID" ]; then
    match_entry=$(echo "$cached_versions" | jq -c --arg id "$TARGET_ID" \
        '[.[] | select(.external_id == $id)] | .[0] // empty')
    if [ -z "$match_entry" ]; then
        echo "❌ External ID $TARGET_ID not found for App ID $APP_ID."
        echo "   (try --refresh if cache may be stale)"
        exit 1
    fi
    match_id="$TARGET_ID"
    TARGET_VERSION=$(echo "$match_entry" | jq -r '.version')
    echo "🔎 Matched external_id $TARGET_ID -> version $TARGET_VERSION"
else
    match_id=$(echo "$cached_versions" | jq -r --arg v "$TARGET_VERSION" \
        '[.[] | select(.version == $v)] | .[0].external_id // empty')
    if [ -z "$match_id" ]; then
        echo "❌ Version $TARGET_VERSION not found for App ID $APP_ID."
        echo "   (try --refresh if cache may be stale)"
        exit 1
    fi
    echo "✅ MATCH FOUND: $match_id"
fi

# --- Output path (after TARGET_VERSION is known) ---
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "📂 Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
fi
FILENAME="cTrader_${TARGET_VERSION}.ipa"
OUTPUT_PATH="${OUTPUT_DIR}/${FILENAME}"
echo "Output Path      : $OUTPUT_PATH"
echo "Preparing download..."

# Clean up old file to prevent Zip Reader error
if [ -f "$OUTPUT_PATH" ]; then
    echo "🗑  Removing existing file: $OUTPUT_PATH"
    rm -f "$OUTPUT_PATH"
    if [ -f "$OUTPUT_PATH" ]; then
        echo "❌ Failed to remove existing file. Aborting."
        exit 1
    fi
fi

# Ensure licensed before download (cache path may have skipped purchase)
ipatool purchase -i "$APP_ID" > /dev/null 2>&1

ipatool download -i "$APP_ID" --external-version-id "$match_id" -o "$OUTPUT_PATH"

if [ $? -eq 0 ]; then
    echo "---------------------------------------"
    echo "🚀 SUCCESS!"
    echo "File saved to: $OUTPUT_PATH"
    echo "---------------------------------------"
    exit 0
else
    echo "❌ Download failed."
    exit 1
fi
