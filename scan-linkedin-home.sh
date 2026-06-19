#!/usr/bin/env bash
#
# scan-linkedin-home.sh — read your LinkedIn HOME feed as a source (vector C).
#
#   CAPTURE (home feed) -> JUDGE -> (ENGAGE) -> DISCOVER -> PERSIST + REPORT -> GROW
#
# Sibling of scan-twitter-home.sh. REPORT significant feed posts, ENGAGE them, and
# DISCOVER untracked authors — added to people-db ONLY if (post is SIG) AND (author
# reads as a genuine AI person/operator from their headline).
#
# Engagement: LIKE/React any SIG post; FOLLOW only AI-person authors being added.
# OFF unless --engage; --dry-run logs intent. people-db grows (working copy) anyway.
#
# BOUNDED: -n posts (30), --max-new people (10), --max-likes/--max-follows.
#
# Usage:
#   ./scan-linkedin-home.sh
#   ./scan-linkedin-home.sh --engage --dry-run
#   ./scan-linkedin-home.sh -n 40 --max-new 8
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

NPOSTS=30; MAXNEW=10; MAXL=25; MAXF=12; ENGAGE=0; DRYRUN=0
PEOPLE_DB="${PEOPLE_DB:-$DIR/../people-db/people.json}"
RUBRIC="${RUBRIC:-$DIR/../people-db/judge_prompt.md}"
PDB_DIR="$(dirname "$PEOPLE_DB")"; UPDATE_TOOL="$PDB_DIR/tools/update_people_db.py"
STORE_DIR="$DIR/store/raw"; ACT_DIR="$DIR/store/actions"; DISC_DIR="$DIR/store/discoveries"; DIGEST_DIR="$DIR/digests"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NPOSTS="$2"; shift 2 ;;
    --max-new) MAXNEW="$2"; shift 2 ;;
    --max-likes) MAXL="$2"; shift 2 ;;
    --max-follows) MAXF="$2"; shift 2 ;;
    --engage) ENGAGE=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$STORE_DIR" "$ACT_DIR" "$DISC_DIR" "$DIGEST_DIR"
[[ -f "$RUBRIC" ]] || { echo "Missing rubric: $RUBRIC" >&2; exit 1; }

DATE="$(date +%Y-%m-%d)"; RUNID="$(date +%Y%m%d-%H%M%S)"; STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
RAWFILE="$STORE_DIR/linkedin-home-$RUNID.jsonl"
DIGEST="$DIGEST_DIR/linkedin-home-$DATE.md"
SEEN="$STORE_DIR/.seen_ids.txt"
ACTFILE="$ACT_DIR/linkedin-home-$RUNID.jsonl"
DISCFILE="$DISC_DIR/linkedin-home-$RUNID.jsonl"

if   [[ $ENGAGE -eq 0 ]]; then ENGAGE_DESC="OFF"
elif [[ $DRYRUN -eq 1 ]]; then ENGAGE_DESC="DRY-RUN (record intent, NO clicks)"
else ENGAGE_DESC="LIVE"; fi

python3 - "$STORE_DIR" > "$SEEN" <<'PY'
import sys, glob, json, os
seen=set()
for fp in glob.glob(os.path.join(sys.argv[1],"linkedin*.jsonl")):
    for line in open(fp,encoding="utf-8"):
        line=line.strip()
        if not line: continue
        try: seen.add(json.loads(line)["id"])
        except Exception: pass
print("\n".join(sorted(seen)))
PY
SEEN_COUNT=$(grep -c . "$SEEN" || true)
echo ">> Reading LinkedIn home feed: up to $NPOSTS posts; add up to $MAXNEW new AI-people; engagement: $ENGAGE_DESC; $SEEN_COUNT seen."

PROMPT=$(cat <<EOF
You are reading the LinkedIn HOME feed (vector C) via chrome-devtools MCP (logged in).
Goal: surface what AI leaders are doing/thinking AND discover new AI people the feed
shows you. Stages: CAPTURE -> JUDGE -> ENGAGE -> DISCOVER -> REPORT. Work human-paced
and BOUNDED — do not endlessly scroll.

Read first (Read tool):
- Rubric: $RUBRIC   (apply exactly)
- People/entity context: $PEOPLE_DB  (entity-context AND already-tracked linkedin ids)
- Already-seen post ids (DO NOT re-report): $SEEN

== CAPTURE (bounded) ==
Navigate https://www.linkedin.com/feed/ (timeout 60000; ignore a false timeout).
Read newest downward and STOP after ~$NPOSTS posts — do NOT keep scrolling past that.
Expand "see more". Skip promoted/ads and "people you may know". For each post
capture: id (activity urn), author name + their /in/ id + one-line headline if
visible, date, type, verbatim text, reaction/comment counts, and (if a reshare) the
original author. Skip already-seen ids.

== JUDGE ==
Apply the rubric -> SIG | INSIG | SKIP (+ <=12-word reason), using entity-context.

== ENGAGE (mode: $ENGAGE_DESC) ==
Only for SIG posts. Caps: max $MAXL likes, max $MAXF follows.
- LIKE/React the SIG post. Skip if already reacted.
- FOLLOW the author ONLY if that author is being ADDED as a new AI-person below.
  Skip if already following.
- If mode OFF: do nothing. If DRY-RUN: record intent, do not click.
- Log each action to "$ACTFILE": {"action":"like"|"follow","post_id":"...","target":"<profile/name>","author":"...","dry_run":$( [[ $DRYRUN -eq 1 ]] && echo true || echo false ),"ts":"$STAMP"}

== DISCOVER (bounded: add at most $MAXNEW new people this run) ==
For a SIG post whose author's /in/ id is NOT among already-tracked ids: judge from
their headline/role whether they are a GENUINE AI person/operator (founder/researcher/
builder/exec in AI) — NOT a generic influencer or non-AI account. Only if YES, append
to "$DISCFILE":
  {"platform":"linkedin","id":"<their /in/ id>","name":"<name>","kind":"person","role_org":"<their headline/role>"}
Stop adding once $MAXNEW recorded (note it). One record per new id.

== PERSIST + REPORT ==
A) Write ALL captured posts to "$RAWFILE" as JSONL (keys: id, platform "linkedin",
   profile, author, date, type, text, links[], engagement{}, label, reason, source
   "home", scraped_at "$STAMP").
B) Write "$DIGEST": "# LinkedIn home digest — $DATE" + counts; a "## From your feed"
   section grouping SIG posts by author with 1-2 line gists; a "## New AI people
   discovered" list (id — role). Footer: posts read, significant, engaged, new people
   (and if a cap was hit).

Finally print one line: posts read / significant / engaged / new-people.
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__click,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Read,Write" \
  2>&1 | tee "$DIGEST_DIR/run-home-$RUNID.log"

if [[ -f "$PEOPLE_DB" && -f "$UPDATE_TOOL" ]]; then
  echo ">> Adding discovered AI-people to people-db..."
  python3 "$UPDATE_TOOL" --people "$PEOPLE_DB" --platform linkedin --today "$DATE" --raw "$RAWFILE" --disc "$DISCFILE" || echo "WARN: people-db update failed" >&2
fi
echo ">> Done. Digest: $DIGEST  Raw: $RAWFILE  (engagement: $ENGAGE_DESC)"
