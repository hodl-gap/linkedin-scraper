#!/usr/bin/env bash
#
# scan-linkedin.sh — unattended LinkedIn activity reader.
#
# Drives a logged-in Chrome (via the chrome-devtools MCP) with a headless
# `claude -p` agent. For each profile it opens the person's recent-activity
# page, scrolls to load posts, reads them, and writes a dated markdown digest.
#
# This is NOT microsecond scraping — it is a slow, human-paced agent that reads
# the real logged-in page. You log in once; it does the looking.
#
# Usage:
#   ./scan-linkedin.sh                      # read profiles.txt, default 15 posts
#   ./scan-linkedin.sh -n 25                # up to 25 posts per person
#   ./scan-linkedin.sh https://www.linkedin.com/in/ghsim/   # ad-hoc URL(s)
#   ./scan-linkedin.sh -f my-list.txt       # a different profile list
#
# Prereqs (see README.md):
#   - chrome-devtools MCP configured at user scope (it is, in ~/.claude.json)
#   - You have logged into LinkedIn ONCE in that Chrome profile
#   - No other Chrome is holding the profile dir (only one at a time)
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

NPOSTS=15
PROFILES_FILE="profiles.txt"
OUTDIR="output"
URLS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NPOSTS="$2"; shift 2 ;;
    -f) PROFILES_FILE="$2"; shift 2 ;;
    -o) OUTDIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    http*) URLS+=("$1"); shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Build the profile list: explicit URLs win, else read the file (skip blanks/#).
if [[ ${#URLS[@]} -eq 0 ]]; then
  [[ -f "$PROFILES_FILE" ]] || { echo "No profiles file: $PROFILES_FILE" >&2; exit 1; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] && URLS+=("$line")
  done < "$PROFILES_FILE"
fi
[[ ${#URLS[@]} -gt 0 ]] || { echo "No profiles to scan." >&2; exit 1; }

mkdir -p "$OUTDIR"
DATE="$(date +%Y-%m-%d)"
STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
OUTFILE="$OUTDIR/linkedin-digest-$DATE.md"
PROFILE_LINES="$(printf '  - %s\n' "${URLS[@]}")"

echo ">> Scanning ${#URLS[@]} profile(s), up to $NPOSTS posts each."
echo ">> Output -> $OUTFILE"

PROMPT=$(cat <<EOF
You are reading LinkedIn on the owner's behalf using the chrome-devtools MCP
tools. The browser is already logged in. Work slowly and human-paced; do NOT
hammer the site.

For EACH of these profile URLs:
$PROFILE_LINES

Do the following, one profile at a time:
1. Normalise the URL to the activity page: take the "/in/<handle>/" part and
   navigate to "<that>/recent-activity/all/".
2. Navigate with mcp__chrome-devtools__navigate_page using a generous timeout
   (e.g. timeout: 60000). LinkedIn is heavy: navigate_page often REPORTS a
   timeout even though the page actually loaded — if that happens, ignore the
   error and just proceed.
3. Take a mcp__chrome-devtools__take_snapshot to read the page. To load more
   than the first batch, use mcp__chrome-devtools__evaluate_script to scroll
   (e.g. window.scrollTo(0, document.body.scrollHeight)) a few times with short
   pauses, taking a fresh snapshot, until about $NPOSTS posts are visible or no
   new ones load.
4. Extract each post by that person: the relative date ("3 hours ago"), the
   full verbatim text (expand "see more" content from the snapshot), reaction /
   comment / repost counts, and any article (/pulse/) or external link.
   Skip ads, "promoted", and "people you may know".

Then APPEND a section per person to the file "$OUTFILE" using the Write tool
(read it first if it already exists so you append rather than overwrite). Format:

  ## <Name> — <profile url>
  _scanned $STAMP_

  ### <relative date> — <one-line summary>
  <full verbatim post text>
  > reactions: N · comments: N · reposts: N
  > links: <urls if any>

Keep the original language of each post (do not translate). Be faithful and
verbatim; do not summarise away the post body. When done, print a one-line
summary of how many posts you captured per person.
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Read,Write" \
  2>&1 | tee "$OUTDIR/run-$DATE.log"

echo ">> Done. Digest at $OUTFILE"
