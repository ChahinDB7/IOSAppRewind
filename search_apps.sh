#!/bin/bash

# search_apps.sh — search the App Store via ipatool and pretty-print results.
#
# Usage:
#   ./search_apps.sh "cTrader"
#   ./search_apps.sh --query "FTMO"
#   ./search_apps.sh "FTMO,cTrader"           # comma-separated runs multiple searches
#   ./search_apps.sh --query "FTMO, cTrader"

# --- Argument Parsing ---
QUERY=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --query)
      QUERY="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 \"QUERY\""
      echo "       $0 --query \"QUERY\""
      echo "       $0 \"FTMO,cTrader\"   # comma-separated for multiple queries"
      exit 0
      ;;
    *)
      if [ -z "$QUERY" ]; then
        QUERY="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$QUERY" ]; then
    echo "❌ Error: Missing query."
    echo "Usage: $0 \"QUERY\"  |  $0 --query \"QUERY\"  |  $0 \"FTMO,cTrader\""
    exit 1
fi

# --- Dependency Check ---
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Error: 'jq' is required. Install with: brew install jq"
    exit 1
fi

if ! command -v ipatool >/dev/null 2>&1; then
    echo "❌ Error: 'ipatool' is required."
    exit 1
fi

# --- Auth Check ---
if ! ipatool auth info --format json >/dev/null 2>&1; then
    echo "❌ Not signed in to ipatool."
    echo "   Run: ipatool auth login --email <APPLE_ID>"
    exit 1
fi

# --- Split comma-separated queries ---
IFS=',' read -ra QUERIES <<< "$QUERY"

for q in "${QUERIES[@]}"; do
    # Trim whitespace
    q="${q#"${q%%[![:space:]]*}"}"
    q="${q%"${q##*[![:space:]]}"}"
    [ -z "$q" ] && continue

    q_lower=$(echo "$q" | tr '[:upper:]' '[:lower:]')

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "🔍 Searching for: \"$q\""
    echo "═══════════════════════════════════════════════════════════════"

    # Run ipatool search in JSON format (clean, color-free output)
    raw=$(ipatool search "$q" --format json 2>&1)

    # Extract apps array
    apps_json=$(echo "$raw" | jq -c '.apps // []' 2>/dev/null)

    if [ -z "$apps_json" ] || [ "$apps_json" = "[]" ] || [ "$apps_json" = "null" ]; then
        echo "❌ No results from ipatool."
        continue
    fi

    # Filter to entries where name OR bundleID contains the query (case-insensitive)
    matches=$(echo "$apps_json" | jq -c --arg q "$q_lower" '[
      .[] | select(
        (.name | ascii_downcase | contains($q)) or
        (.bundleID | ascii_downcase | contains($q))
      )
    ]')

    count=$(echo "$matches" | jq 'length')

    if [ "$count" = "0" ]; then
        echo "❌ No matching apps found for \"$q\"."
        continue
    fi

    echo "✅ Found $count match(es)"

    echo "$matches" | jq -c '.[]' | while read -r app; do
        id=$(echo "$app" | jq -r '.id')
        name=$(echo "$app" | jq -r '.name')
        bundle=$(echo "$app" | jq -r '.bundleID')
        version=$(echo "$app" | jq -r '.version')
        price=$(echo "$app" | jq -r '.price')

        # Enrich with iTunes Search API (description, seller, genre, rating, size)
        itunes=$(curl -s "https://itunes.apple.com/lookup?id=$id" 2>/dev/null)
        description=$(echo "$itunes" | jq -r '.results[0].description // "N/A"' 2>/dev/null)
        seller=$(echo "$itunes"      | jq -r '.results[0].sellerName // "N/A"' 2>/dev/null)
        genre=$(echo "$itunes"       | jq -r '.results[0].primaryGenreName // "N/A"' 2>/dev/null)
        rating=$(echo "$itunes"      | jq -r '.results[0].averageUserRating // "N/A"' 2>/dev/null)
        size_bytes=$(echo "$itunes"  | jq -r '.results[0].fileSizeBytes // 0' 2>/dev/null)

        if [ -n "$size_bytes" ] && [ "$size_bytes" != "null" ] && [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            size_str="$((size_bytes / 1048576)) MB"
        else
            size_str="N/A"
        fi

        # Round rating to 2 decimals (iTunes returns absurd float precision)
        if [ -n "$rating" ] && [ "$rating" != "N/A" ] && [ "$rating" != "null" ]; then
            rating=$(printf "%.2f" "$rating" 2>/dev/null || echo "$rating")
        fi

        # Truncate description for readability
        MAX_DESC=140
        if [ ${#description} -gt $MAX_DESC ]; then
            description="${description:0:$MAX_DESC}..."
        fi
        # Collapse internal newlines so multi-line descriptions stay on one row
        description=$(echo "$description" | tr '\n' ' ' | tr -s ' ')

        # Helper: print a row only if value is meaningful (skip N/A / empty / null)
        print_optional() {
            local label="$1"
            local value="$2"
            if [ -n "$value" ] && [ "$value" != "N/A" ] && [ "$value" != "null" ]; then
                printf "  %s : %s\n" "$label" "$value"
            fi
        }

        echo ""
        echo "─────────────────────────────────────────────────────────────"
        echo "📱 $name"
        echo "─────────────────────────────────────────────────────────────"
        # Required rows — always shown
        printf "  App ID      : %s\n" "$id"
        printf "  Bundle ID   : %s\n" "$bundle"
        printf "  Version     : %s\n" "$version"
        # Optional rows — only when value is present
        print_optional "Price      " "$price"
        print_optional "Genre      " "$genre"
        print_optional "Seller     " "$seller"
        print_optional "Rating     " "$rating"
        print_optional "Size       " "$size_str"
        print_optional "Description" "$description"
    done
    echo ""
done
