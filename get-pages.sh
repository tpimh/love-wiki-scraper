#!/bin/sh

FORMAT="json"
API_BASE_URL="https://www.love2d.org/w/api.php?action=query&format=$FORMAT"
API_LIST_URL="$API_BASE_URL&list=allpages&aplimit=max"
API_CONTENT_URL="$API_BASE_URL&prop=revisions&rvprop=content"
OUT_DIR="scrap"
N=0
D=0
NEXT_CONTINUE=""
COOLDOWN=60

mkdir -p "$OUT_DIR"

while true; do
    N=$((N + 1))
    OUT_FILE="$OUT_DIR/allpages-$N.$FORMAT"
    curl -s "$API_LIST_URL$NEXT_CONTINUE" -o "$OUT_FILE"

    echo "Fetched page $N of list"
    sleep $COOLDOWN

    # Extract the next apcontinue value, if any
    NEXT_CONTINUE=$(jq -r '.continue.apcontinue // empty | @uri' "$OUT_FILE")
    if [ -z "$NEXT_CONTINUE" ]; then
        break
    fi
    NEXT_CONTINUE="&apcontinue=$NEXT_CONTINUE"
done

# Collect all page IDs from all files into one list
all_page_ids=""
for i in $(seq 1 $N); do
  file="$OUT_DIR/allpages-$i.$FORMAT"
  echo "Processing $file..."
  page_ids=$(jq .query.allpages "$file" | \
    jq -r '.[] | select(.title | test(" \\([^)]+\\)$") | not) | .pageid')
  if [ -n "$all_page_ids" ]; then
    all_page_ids="$all_page_ids
$page_ids"
  else
    all_page_ids="$page_ids"
  fi
done

# Batch the collected IDs and dump the content
batches=$(echo "$all_page_ids" | xargs -n 50 | sed 's/ /|/g' | tr '\n' ' ')

for ids in $batches; do
  D=$((D+1))
  OUT_FILE="$OUT_DIR/dump-$D.$FORMAT"
  curl -s "$API_CONTENT_URL&pageids=$ids" -o "$OUT_FILE"
  echo "Fetched batch $D of content"
  sleep $COOLDOWN
done

# Download the JSON library
mkdir -p lib
curl -s https://raw.githubusercontent.com/rxi/json.lua/refs/heads/master/json.lua -o lib/json.lua
echo "JSON library downloaded"

# Save the configuration file
cat <<EOF > "config.lua"
-- automatically generated
return {
    N_FILES = $N,
    D_FILES = $D,
    N_PREFIX = "$OUT_DIR/allpages-",
    D_PREFIX = "$OUT_DIR/dump-",
    SUFFIX = ".$FORMAT",
}
EOF