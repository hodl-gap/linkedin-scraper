#!/usr/bin/env bash
#
# scan-linkedin.sh — significance-filtered LinkedIn monitor (Milestone 1).
#
# LinkedIn sibling of twitter-scraper-chrome-devtools/scan-twitter.sh. Same
# CAPTURE -> JUDGE -> REPORT pipeline, shared rubric + people-db.
#
#   CAPTURE  -> for each profile, fetch recent-activity posts NEW since last run
#               (incremental), expand "see more" + multi-part posts, store verbatim.
#   JUDGE    -> label each new post SIG/INSIG/SKIP via the shared rubric +
#               entity-context from people-db.
#   REPORT   -> one synthesized summary PER PERSON who had >=1 new significant
#               post, with source refs. (Per-person, not per-post.)
#
# Artifacts:
#   store/raw/linkedin-<runid>.jsonl  — every post seen this run (+ label/reason).
#   digests/linkedin-<date>.md        — the human deliverable (per-person summaries).
#
# Engagement (like/follow) is NOT here yet — Milestone 2.
#
# Usage:
#   ./scan-linkedin.sh                                  # profiles.txt
#   ./scan-linkedin.sh https://www.linkedin.com/in/ghsim/   # ad-hoc profile(s)
#   ./scan-linkedin.sh -n 15                            # cap new posts/profile
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

NPOSTS=15
PROFILES_FILE="profiles.txt"
PEOPLE_DB="${PEOPLE_DB:-$DIR/../people-db/people.json}"
RUBRIC="${RUBRIC:-$DIR/../people-db/judge_prompt.md}"
STORE_DIR="$DIR/store/raw"
DIGEST_DIR="$DIR/digests"
PROFILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NPOSTS="$2"; shift 2 ;;
    -f) PROFILES_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    http*) PROFILES+=("$1"); shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ${#PROFILES[@]} -eq 0 ]]; then
  [[ -f "$PROFILES_FILE" ]] || { echo "No profiles file: $PROFILES_FILE" >&2; exit 1; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] && PROFILES+=("$line")
  done < "$PROFILES_FILE"
fi
[[ ${#PROFILES[@]} -gt 0 ]] || { echo "No profiles to scan." >&2; exit 1; }

mkdir -p "$STORE_DIR" "$DIGEST_DIR"
[[ -f "$RUBRIC" ]] || { echo "Missing rubric: $RUBRIC" >&2; exit 1; }
[[ -f "$PEOPLE_DB" ]] || echo "WARN: people-db not found at $PEOPLE_DB (entity-context degraded)" >&2

DATE="$(date +%Y-%m-%d)"
RUNID="$(date +%Y%m%d-%H%M%S)"
STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
RAWFILE="$STORE_DIR/linkedin-$RUNID.jsonl"
DIGEST="$DIGEST_DIR/linkedin-$DATE.md"
SEEN="$STORE_DIR/.seen_ids.txt"

python3 - "$STORE_DIR" > "$SEEN" <<'PY'
import sys, glob, json, os
seen = set()
for fp in glob.glob(os.path.join(sys.argv[1], "linkedin-*.jsonl")):
    with open(fp, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: seen.add(json.loads(line)["id"])
            except Exception: pass
print("\n".join(sorted(seen)))
PY
SEEN_COUNT=$(grep -c . "$SEEN" || true)

PROFILE_LINES="$(printf '  - %s\n' "${PROFILES[@]}")"
echo ">> Scanning ${#PROFILES[@]} profile(s); up to $NPOSTS new posts each; $SEEN_COUNT ids already seen."
echo ">> Raw -> $RAWFILE   Digest -> $DIGEST"

PROMPT=$(cat <<EOF
You are an unattended LinkedIn intelligence agent using the chrome-devtools MCP
tools (browser already logged in). Goal: surface what AI leaders are doing/thinking.
Work human-paced. Run three stages in order: CAPTURE -> JUDGE -> REPORT.

First read these (use the Read tool):
- Significance rubric: $RUBRIC  (apply it exactly, including the edge-case tie-breakers)
- Entity / people context: $PEOPLE_DB  (match each profile by its linkedin id for role_org + notes; use as entity-context)
- Already-seen post ids (one per line; DO NOT re-capture these): $SEEN

Profiles to scan:
$PROFILE_LINES

== STAGE 1: CAPTURE (incremental) ==
For each profile URL, take its "/in/<id>/" part and navigate to
"<that>/recent-activity/all/" (navigate_page timeout 60000; if it reports a
timeout, ignore it and snapshot anyway).
- Scroll and read posts from newest downward. STOP for that profile once you reach
  posts whose id is in the already-seen list, or after ~$NPOSTS new posts.
- Expand "see more" so text is complete. If a post is an article, note the
  article title/link (you may open the link only if needed to judge significance;
  if it is unreadable, mark SKIP).
- For each new post capture: stable id (the activity urn, e.g. urn:li:activity:...,
  from the post permalink; else synthesize "<id>:<date>:<first40chars>"),
  author, date, type (original|reshare|article), verbatim text, links, and
  reaction/comment/repost counts. Skip promoted/ads and "people you may know".

== STAGE 2: JUDGE ==
For every newly captured post, look up the author in the people context
(by linkedin id) for role_org + notes (entity-context), then apply the rubric to
assign label = SIG | INSIG | SKIP and a <=12-word reason.

== STAGE 3: PERSIST + REPORT ==
A) Write ALL newly captured posts (every label) to "$RAWFILE" as JSONL — one JSON
   object per line, no array wrapper. Keys: id, platform ("linkedin"), profile
   (the /in/<id>), author, date, type, text, links (array), engagement (object),
   label, reason, scraped_at ("$STAMP").
B) Write the human digest to "$DIGEST" (Markdown):
   - Title "# LinkedIn digest — $DATE" and a one-line header with counts
     (new posts captured, significant count, people covered).
   - ONE section PER PERSON who had >=1 new SIG post:
       "## <Author>"
       a synthesized 2-4 sentence summary of *what that person is doing/thinking*
       right now, rolled up across their significant posts (NOT one blurb per post),
       then a line "_sources: <dates/refs>_".
     Omit people with no new significant posts.
   - Footer: people scanned with nothing significant; any empty/blocked profiles.

When done, print a one-line summary: per profile, how many new posts captured and
how many were significant.
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__click,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Read,Write" \
  2>&1 | tee "$DIGEST_DIR/run-$RUNID.log"

echo ">> Done. Digest: $DIGEST   Raw: $RAWFILE"
