#!/usr/bin/env bash
#
# scan-linkedin.sh — significance-filtered LinkedIn monitor + engagement + grow.
#
#   CAPTURE -> JUDGE -> (ENGAGE) -> PERSIST + REPORT -> GROW people-db
#
# Watchlist == people-db (policy D): with no args, scans every person in
# people-db that has a LinkedIn id (status active|dormant|unknown). Discovered
# reshared authors are written back to people-db.
#
# Engagement OFF unless --engage; --dry-run logs intended like/follow without
# clicking. people-db is grown every run (independent of engagement).
#
# Usage:
#   ./scan-linkedin.sh                                    # watchlist from people-db
#   ./scan-linkedin.sh https://www.linkedin.com/in/ghsim/ # ad-hoc profile override
#   ./scan-linkedin.sh --engage --dry-run                 # log intended like/follow
#   ./scan-linkedin.sh --engage                           # LIVE like/follow on SIG
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

NPOSTS=15; PROFILES_FILE="profiles.txt"
PEOPLE_DB="${PEOPLE_DB:-$DIR/../people-db/people.json}"
RUBRIC="${RUBRIC:-$DIR/../people-db/judge_prompt.md}"
PDB_DIR="$(dirname "$PEOPLE_DB")"
LIST_TOOL="$PDB_DIR/tools/list_watchlist.py"; UPDATE_TOOL="$PDB_DIR/tools/update_people_db.py"
STORE_DIR="$DIR/store/raw"; ACT_DIR="$DIR/store/actions"; DISC_DIR="$DIR/store/discoveries"; DIGEST_DIR="$DIR/digests"
ENGAGE=0; DRYRUN=0; MAXL=25; MAXF=12
PROFILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NPOSTS="$2"; shift 2 ;;
    -f) PROFILES_FILE="$2"; shift 2 ;;
    --engage) ENGAGE=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --max-likes) MAXL="$2"; shift 2 ;;
    --max-follows) MAXF="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    http*) PROFILES+=("$1"); shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Watchlist: explicit args win; else derive from people-db (id -> profile URL); else profiles.txt.
if [[ ${#PROFILES[@]} -eq 0 ]]; then
  if [[ -f "$PEOPLE_DB" && -f "$LIST_TOOL" ]]; then
    while IFS= read -r id; do [[ -n "$id" ]] && PROFILES+=("https://www.linkedin.com/in/$id/"); done \
      < <(python3 "$LIST_TOOL" --people "$PEOPLE_DB" --platform linkedin)
    echo ">> Watchlist from people-db: ${#PROFILES[@]} profile(s)."
  elif [[ -f "$PROFILES_FILE" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | xargs)"
      [[ -n "$line" ]] && PROFILES+=("$line")
    done < "$PROFILES_FILE"
  fi
fi
[[ ${#PROFILES[@]} -gt 0 ]] || { echo "No profiles to scan." >&2; exit 1; }

mkdir -p "$STORE_DIR" "$ACT_DIR" "$DISC_DIR" "$DIGEST_DIR"
[[ -f "$RUBRIC" ]] || { echo "Missing rubric: $RUBRIC" >&2; exit 1; }
[[ -f "$PEOPLE_DB" ]] || echo "WARN: people-db not found at $PEOPLE_DB (entity-context degraded)" >&2

DATE="$(date +%Y-%m-%d)"; RUNID="$(date +%Y%m%d-%H%M%S)"; STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
RAWFILE="$STORE_DIR/linkedin-$RUNID.jsonl"
DIGEST="$DIGEST_DIR/linkedin-$DATE.md"
SEEN="$STORE_DIR/.seen_ids.txt"
ACTFILE="$ACT_DIR/linkedin-$RUNID.jsonl"
DISCFILE="$DISC_DIR/linkedin-$RUNID.jsonl"

if   [[ $ENGAGE -eq 0 ]]; then ENGAGE_DESC="OFF"
elif [[ $DRYRUN -eq 1 ]]; then ENGAGE_DESC="DRY-RUN (record intended actions only, NO clicks)"
else ENGAGE_DESC="LIVE (actually like + follow)"; fi

python3 - "$STORE_DIR" > "$SEEN" <<'PY'
import sys, glob, json, os
seen=set()
for fp in glob.glob(os.path.join(sys.argv[1],"linkedin-*.jsonl")):
    for line in open(fp,encoding="utf-8"):
        line=line.strip()
        if not line: continue
        try: seen.add(json.loads(line)["id"])
        except Exception: pass
print("\n".join(sorted(seen)))
PY
SEEN_COUNT=$(grep -c . "$SEEN" || true)
PROFILE_LINES="$(printf '  - %s\n' "${PROFILES[@]}")"
echo ">> Scanning ${#PROFILES[@]} profile(s); $NPOSTS new/profile; $SEEN_COUNT seen; engagement: $ENGAGE_DESC"
echo ">> Raw: $RAWFILE  Digest: $DIGEST  Disc: $DISCFILE"

PROMPT=$(cat <<EOF
You are an unattended LinkedIn intelligence agent using the chrome-devtools MCP
tools (browser already logged in). Goal: surface what AI leaders are doing/thinking.
Work human-paced. Stages: CAPTURE -> JUDGE -> ENGAGE (inline) -> PERSIST + REPORT.

Read first (Read tool):
- Rubric: $RUBRIC  (apply exactly, incl. edge-case tie-breakers)
- People/entity context: $PEOPLE_DB  (match each profile by linkedin id for role_org + notes)
- Already-seen ids (DO NOT re-capture): $SEEN

Profiles:
$PROFILE_LINES

== CAPTURE (incremental) ==
For each profile URL, take its "/in/<id>/" part and navigate to
"<that>/recent-activity/all/" (timeout 60000; a reported timeout is usually false
— snapshot anyway). Read newest downward; STOP at a seen id or after ~$NPOSTS new
posts. Expand "see more"; for an article note title/link (open only if needed;
unreadable -> SKIP). Capture per post: stable id (activity urn; else
"<id>:<date>:<first40>"), author, date, type (original|reshare|article), verbatim
text, links, reaction/comment/repost counts, and — if a reshare — the ORIGINAL
author's name + their /in/<id>. Skip promoted/ads and "people you may know".

== JUDGE ==
For each new post, use the entity-context, then apply the rubric -> label
(SIG|INSIG|SKIP) + <=12-word reason.

== ENGAGE (mode: $ENGAGE_DESC) ==
Inline — act the moment you judge a post SIG. Caps: max $MAXL likes, max $MAXF follows.
- If mode is OFF: do nothing here.
- Else for each SIG post: LIKE/React (skip if already reacted); FOLLOW its author if
  not already following, and if it reshares a DIFFERENT person, also FOLLOW that
  original author if new. Respect caps. If DRY-RUN: record only, do NOT click.
  Append each action to "$ACTFILE" as JSONL:
  {"action":"like"|"follow","post_id":"...","target":"<profile/name>","author":"...","dry_run":$( [[ $DRYRUN -eq 1 ]] && echo true || echo false ),"ts":"$STAMP"}
  Never like/follow INSIG or SKIP.

== PERSIST + REPORT + DISCOVER ==
A) Write ALL new posts (every label) to "$RAWFILE" as JSONL, keys: id, platform
   ("linkedin"), profile, author, date, type, text, links[], engagement{}, label,
   reason, scraped_at ("$STAMP").
B) DISCOVERIES (always, regardless of engagement): for each SIG post that reshares
   a person NOT among the scanned profiles, append to "$DISCFILE" a JSONL record:
   {"platform":"linkedin","id":"<their /in/ id>","name":"<display name>","kind":"person"|"organization","role_org":"<short affiliation if visible>"}
   Mark company pages as kind "organization".
C) Write digest to "$DIGEST": "# LinkedIn digest — $DATE" + one-line counts; then
   one "## <Author>" section PER PERSON with >=1 new SIG post — a synthesized 2-4
   sentence summary (rolled up, NOT per-post) + "_sources: ..._". Omit people with
   nothing significant. Footer: nothing-significant people, empty/blocked profiles,
   engagement summary, and discovered authors.

Finally print one line per profile: new captured / significant / engaged counts.
EOF
)

claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --mcp-config "$DIR/.mcp.json" \
  --allowedTools "mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__take_snapshot,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__click,mcp__chrome-devtools__list_pages,mcp__chrome-devtools__new_page,Read,Write" \
  2>&1 | tee "$DIGEST_DIR/run-$RUNID.log"

if [[ -f "$PEOPLE_DB" && -f "$UPDATE_TOOL" ]]; then
  echo ">> Updating people-db..."
  python3 "$UPDATE_TOOL" --people "$PEOPLE_DB" --platform linkedin --today "$DATE" --raw "$RAWFILE" --disc "$DISCFILE" || echo "WARN: people-db update failed" >&2
fi

echo ">> Done. Digest: $DIGEST  Raw: $RAWFILE  Actions: $ACTFILE (engagement: $ENGAGE_DESC)"
