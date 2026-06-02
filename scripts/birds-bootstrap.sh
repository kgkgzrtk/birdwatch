#!/usr/bin/env bash
# Download CC-licensed bird recordings from Wikimedia Commons,
# trim/normalize to short WAV samples used by dispatch.sh.
#
# Output: <plugin>/assets/birds/samples/<slug>.wav  (mono, 44.1kHz, ~1.5s, normalized)
#         <plugin>/assets/birds/ATTRIBUTIONS.md     (per-sample attribution)
#         <plugin>/assets/birds/species.json        (slug → metadata, ordered list)
#
# Usage: bash birds-bootstrap.sh           # download missing samples
#        FORCE=1 bash birds-bootstrap.sh   # re-download all
set -u

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/assets/birds"
SAMP_DIR="$ROOT/samples"
RAW_DIR="$ROOT/raw"
ATTR="$ROOT/ATTRIBUTIONS.md"
SPECIES_JSON="$ROOT/species.json"
mkdir -p "$SAMP_DIR" "$RAW_DIR"

# Wikimedia requires a descriptive User-Agent; anonymous requests without one
# can be rate-limited or rejected with HTML error pages.
UA='ClaudeCode-SpatialAudio/1.0 (https://github.com/anthropics/claude-code; bird-samples)'

# Species list: slug | Latin name | common name | preferred Commons file (optional, blank = auto-pick)
# Order matters: project hash → species index (stable for as long as this list grows).
read -r -d '' SPECIES <<'EOF' || true
robin|Erithacus rubecula|European Robin|Erithacus rubecula - European Robin - XC114615.ogg
blackbird|Turdus merula|Common Blackbird|
cuckoo|Cuculus canorus|Common Cuckoo|
greattit|Parus major|Great Tit|
wren|Troglodytes troglodytes|Eurasian Wren|
nightingale|Luscinia megarhynchos|Common Nightingale|
woodpecker|Dendrocopos major|Great Spotted Woodpecker|
tawnyowl|Strix aluco|Tawny Owl|
magpie|Pica pica|Eurasian Magpie|
raven|Corvus corax|Common Raven|
skylark|Alauda arvensis|Eurasian Skylark|
chiffchaff|Phylloscopus collybita|Common Chiffchaff|
blackcap|Sylvia atricapilla|Eurasian Blackcap|
goldfinch|Carduelis carduelis|European Goldfinch|
sparrow|Passer domesticus|House Sparrow|
swallow|Hirundo rustica|Barn Swallow|
collareddove|Streptopelia decaocto|Eurasian Collared Dove|
kestrel|Falco tinnunculus|Common Kestrel|
mallard|Anas platyrhynchos|Mallard|
crow|Corvus brachyrhynchos|American Crow|
cardinal|Cardinalis cardinalis|Northern Cardinal|
mourningdove|Zenaida macroura|Mourning Dove|
loon|Gavia immer|Common Loon|
eagleowl|Bubo bubo|Eurasian Eagle-Owl|
uguisu|Horornis diphone|Japanese Bush Warbler|
swift|Apus apus|Common Swift|
pheasant|Phasianus colchicus|Common Pheasant|
chickadee|Poecile atricapillus|Black-capped Chickadee|
EOF

# Look up a usable .ogg file in "Audio files of <Latin>" Commons category.
# Heuristics: prefer file size between 50KB and 4MB, with "XC" (xeno-canto) in name
# for quality, otherwise first reasonable one. Returns title only.
pick_file() {
  local latin="$1"
  local cat resp pick
  # Try several category-name variants; Commons is inconsistent.
  for cat in \
    "Audio files of ${latin}" \
    "Sound recordings of ${latin}" \
    "${latin}" \
    "Songs of ${latin}" \
    "Calls of ${latin}" ; do
    resp=$(curl -sS --max-time 15 -A "$UA" \
      --data-urlencode "action=query" \
      --data-urlencode "format=json" \
      --data-urlencode "list=categorymembers" \
      --data-urlencode "cmtitle=Category:${cat}" \
      --data-urlencode "cmlimit=80" \
      --data-urlencode "cmtype=file" \
      -G 'https://commons.wikimedia.org/w/api.php')
    pick=$(echo "$resp" | jq -r --arg latin "$latin" '
      .query.categorymembers // [] |
      map(.title) |
      map(select(test("\\.(ogg|oga|mp3|wav|flac)$"; "i"))) |
      sort_by(
        (if test($latin; "i") then 0 else 1 end),
        (if test("XC[0-9]+"; "i") then 0 else 1 end),
        (if test("\\.mp3$"; "i") then 1 else 0 end),
        length
      ) | .[0] // empty' 2>/dev/null)
    if [[ -n "$pick" ]]; then
      echo "$pick"
      return 0
    fi
  done
  # Last resort: search Commons for filename containing the Latin name.
  resp=$(curl -sS --max-time 15 -A "$UA" \
    --data-urlencode "action=query" \
    --data-urlencode "format=json" \
    --data-urlencode "list=search" \
    --data-urlencode "srsearch=${latin} filetype:audio" \
    --data-urlencode "srnamespace=6" \
    --data-urlencode "srlimit=20" \
    -G 'https://commons.wikimedia.org/w/api.php')
  echo "$resp" | jq -r --arg latin "$latin" '
    .query.search // [] | map(.title) |
    map(select(test("\\.(ogg|oga|mp3|wav|flac)$"; "i"))) |
    sort_by(
      (if test($latin; "i") then 0 else 1 end),
      length
    ) | .[0] // empty' 2>/dev/null
}

# Get direct URL + license metadata for a File: title.
file_meta() {
  local title="$1"
  curl -sS --max-time 15 -A "$UA" \
    --data-urlencode "action=query" \
    --data-urlencode "format=json" \
    --data-urlencode "prop=imageinfo" \
    --data-urlencode "titles=${title}" \
    --data-urlencode "iiprop=url|size|extmetadata" \
    -G 'https://commons.wikimedia.org/w/api.php'
}

# Render one species: download (if needed), process to WAV.
process_one() {
  local slug="$1" latin="$2" common="$3" preferred="$4"
  local out="$SAMP_DIR/$slug.wav"
  if [[ -f "$out" && -z "${FORCE:-}" ]]; then
    echo "[skip] $slug ($common) — already have $(basename "$out")"
    # Preserve prior attribution so the rebuilt species.json stays complete.
    if [[ -f "$SPECIES_JSON" ]]; then
      jq -r --arg slug "$slug" '
        map(select(.slug == $slug)) | .[0] |
        select(. != null) |
        [.slug, .latin, .common, .license, .artist, .source] | @tsv
      ' "$SPECIES_JSON" >> "$ROOT/.attr.tsv" 2>/dev/null
    fi
    return 0
  fi

  local title="${preferred}"
  if [[ -z "$title" ]]; then
    title=$(pick_file "$latin")
  fi
  if [[ -z "$title" ]]; then
    echo "[fail] $slug ($latin): no .ogg file in Commons category" >&2
    return 1
  fi
  # Strip optional "File:" prefix from preferred title (API returns File:...)
  title="${title#File:}"

  local meta url size license artist
  meta=$(file_meta "File:$title")
  url=$(    echo "$meta" | jq -r '.query.pages[] | .imageinfo[0].url // empty' 2>/dev/null)
  size=$(   echo "$meta" | jq -r '.query.pages[] | .imageinfo[0].size // 0'    2>/dev/null)
  license=$(echo "$meta" | jq -r '.query.pages[] | .imageinfo[0].extmetadata.LicenseShortName.value // "unknown"' 2>/dev/null)
  artist=$( echo "$meta" | jq -r '.query.pages[] | .imageinfo[0].extmetadata.Artist.value // "unknown"' 2>/dev/null \
              | sed -E 's/<[^>]+>//g' | tr -s ' ' | sed -E 's/^ //;s/ $//')

  if [[ -z "$url" ]]; then
    echo "[fail] $slug: could not resolve URL for $title" >&2
    return 1
  fi

  # Skip mass uploads / probable junk
  if (( size < 8000 )); then
    echo "[fail] $slug: file too small ($size bytes)" >&2
    return 1
  fi

  # Preserve source extension so sox picks the right codec.
  local ext
  ext=$(printf '%s' "$title" | awk -F. '{print tolower($NF)}')
  case "$ext" in ogg|oga|mp3|wav|flac) : ;; *) ext=ogg ;; esac
  local raw="$RAW_DIR/$slug.$ext"
  if ! curl -fsSL --max-time 60 -A "$UA" "$url" -o "$raw"; then
    echo "[fail] $slug: download failed for $url" >&2
    return 1
  fi

  # Clean + extract just the call:
  #   highpass 400 / lowpass 11000     — keep bird-call frequency band (~500Hz-10kHz),
  #                                      cut wind rumble / room hum and tape hiss
  #   compand …                        — noise gate: anything below ~-45 dB is suppressed
  #                                      (kills inter-call ambient hiss/birds)
  #   silence 1 0.05 2% reverse … reverse — trim leading + trailing silence aggressively
  #   trim 0 1.5                       — cap at 1.5s
  #   fade t 0.01 0 0.05               — soft edges so trims don't click
  #   norm -1                          — peak to -1 dBFS, uniform loudness across species
  local prof="$RAW_DIR/$slug.noise.prof"
  # Profile noise from the first 0.15s (assumed pre-call ambient).
  # If the recording starts mid-call this profile will be wrong; we use a gentle
  # subtraction strength (0.18) so the worst case is mild attenuation, not artifacts.
  sox "$raw" -n trim 0 0.15 noiseprof "$prof" 2>/dev/null

  process_with_filters() {
    local trim_thresh="$1"  # silence threshold (e.g. 2%)
    if [[ -s "$prof" ]]; then
      sox "$raw" -r 44100 -c 1 "$out" \
          noisered "$prof" 0.18 \
          highpass 400 lowpass 11000 \
          compand 0.01,0.10 -70,-70,-45,-45,-15,-3 0 -90 0.05 \
          silence 1 0.05 "$trim_thresh" reverse silence 1 0.15 "$trim_thresh" reverse \
          trim 0 1.5 \
          fade t 0.01 0 0.05 \
          norm -1 2>/dev/null
    else
      sox "$raw" -r 44100 -c 1 "$out" \
          highpass 400 lowpass 11000 \
          compand 0.01,0.10 -70,-70,-45,-45,-15,-3 0 -90 0.05 \
          silence 1 0.05 "$trim_thresh" reverse silence 1 0.15 "$trim_thresh" reverse \
          trim 0 1.5 \
          fade t 0.01 0 0.05 \
          norm -1 2>/dev/null
    fi
  }

  if ! process_with_filters "2%"; then
    # Either sox errored or aggressive silence trim ate the whole recording.
    # Retry with a looser threshold.
    if ! process_with_filters "0.5%"; then
      # Last resort: simple decode with mild cleanup so we still get a sample.
      if ! sox "$raw" -r 44100 -c 1 "$out" \
            highpass 300 trim 0.2 1.5 norm -1 2>/dev/null; then
        echo "[fail] $slug: sox processing failed" >&2
        rm -f "$prof"
        return 1
      fi
    fi
  fi
  rm -f "$prof"

  # Verify output is not empty / sane length.
  local len
  len=$(sox "$out" -n stat 2>&1 | awk '/Length \(seconds\)/ {print $3}')
  if [[ -z "$len" || $(awk -v l="$len" 'BEGIN{print (l<0.5)}') == "1" ]]; then
    echo "[fail] $slug: output too short (${len}s)" >&2
    rm -f "$out"
    return 1
  fi

  echo "[ ok ] $slug ($common): ${len}s — $license — $artist"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$slug" "$latin" "$common" "$license" "$artist" "$title" \
    >> "$ROOT/.attr.tsv"
}

# Reset attribution staging.
rm -f "$ROOT/.attr.tsv"

# Process all species.
i=0
while IFS='|' read -r slug latin common preferred; do
  [[ -z "$slug" || "$slug" == \#* ]] && continue
  process_one "$slug" "$latin" "$common" "$preferred" || true
  i=$((i+1))
  # be nice to Wikimedia
  sleep 0.3
done <<<"$SPECIES"

# Build ATTRIBUTIONS.md from staging.
{
  echo "# Bird sample attributions"
  echo ""
  echo "All samples sourced from Wikimedia Commons. License terms apply per recording."
  echo "Generated by scripts/birds-bootstrap.sh."
  echo ""
  echo "| Slug | Species | Common name | License | Recordist | Source file |"
  echo "|------|---------|-------------|---------|-----------|-------------|"
  if [[ -f "$ROOT/.attr.tsv" ]]; then
    while IFS=$'\t' read -r slug latin common license artist title; do
      printf '| %s | _%s_ | %s | %s | %s | [%s](https://commons.wikimedia.org/wiki/File:%s) |\n' \
        "$slug" "$latin" "$common" "$license" "$artist" "$title" \
        "$(printf '%s' "$title" | sed 's/ /_/g')"
    done < "$ROOT/.attr.tsv"
  fi
} > "$ATTR"

# Build species.json — stable ordered list dispatch.sh uses for hash→species mapping.
if [[ -f "$ROOT/.attr.tsv" ]]; then
  jq -Rn '
    [inputs | split("\t") |
      {slug: .[0], latin: .[1], common: .[2], license: .[3], artist: .[4], source: .[5]}]
    ' < "$ROOT/.attr.tsv" > "$SPECIES_JSON"
fi

rm -f "$ROOT/.attr.tsv"

count=$(jq 'length' "$SPECIES_JSON" 2>/dev/null || echo 0)
echo ""
echo "Done. $count species available in $SAMP_DIR"
echo "Attributions: $ATTR"
