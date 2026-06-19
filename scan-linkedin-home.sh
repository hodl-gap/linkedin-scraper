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

CAPS ARE CEILINGS, NOT TARGETS: stop as soon as you are caught up (you hit a run
of already-seen posts) or run out of genuinely new material — whichever comes
before the cap. Never scroll past already-seen content to reach the cap; an empty
or near-empty run is correct when little is new. The new-people cap is likewise a
ceiling — only add people who genuinely qualify, never to "fill" it.

Read first (Read tool):
- Rubric: $RUBRIC   (apply exactly)
- People/entity context: $PEOPLE_DB  (entity-context AND already-tracked linkedin ids)
- Already-seen post ids (DO NOT re-report): $SEEN

== CAPTURE (bounded, STRICTLY READ-ONLY) ==
Navigate https://www.linkedin.com/feed/ (timeout 60000; ignore a false timeout).
Extract posts ENTIRELY from take_snapshot (+ read-only evaluate_script). To load
more, scroll via evaluate_script (window.scrollTo(0, document.body.scrollHeight))
then re-snapshot. STOP at ~$NPOSTS posts or when caught up (ceiling rule above).
Skip promoted/ads and "people you may know".
NEVER click Like / Comment / Repost / Follow / Connect or any control during capture
— this stage is read-only. (The ENGAGE stage is the ONLY place anything is clicked,
and only when enabled.) Do NOT click a Comment button to surface an id.
Per post, from the snapshot: id = the activity urn taken from the post's permalink
href (the "urn:li:activity:NNNN" inside its link); if none is visible, synthesize
"<author-id>:<date>:<first40chars>". Also capture author name + their /in/ id (from
the actor link), one-line headline, date, type, verbatim text (read what's shown; you
may toggle only the post's own "…more" text expander, nothing else), reaction/comment
counts, and (if a reshare) the original author. Skip already-seen ids.

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
A candidate = the author of a SIG post whose /in/ id is NOT among already-tracked ids.
Process newest-first; STOP once $MAXNEW are added (don't evaluate many more — bound cost).
For each candidate:
  1. Their in-feed HEADLINE is usually enough — if it clearly shows an AI person/operator
     (founder / researcher / builder / exec in AI), decide from it. If AMBIGUOUS, open
     their profile (https://www.linkedin.com/in/<id>/) and read their About + recent
     activity. (Profile visits are READ-ONLY — do not react/follow/connect there.)
  2. DECIDE: a GENUINE AI person/operator — NOT a generic influencer or non-AI account?
  3. If YES, append to "$DISCFILE":
     {"platform":"linkedin","id":"<their /in/ id>","name":"<name>","kind":"person","role_org":"<their headline/role>"}
One record per new id. A SIG author judged NOT an AI-person is reported but not added
(and not followed).

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
