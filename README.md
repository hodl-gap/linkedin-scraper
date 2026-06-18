# linkedin-scraper

An **unattended LinkedIn activity reader**. You log into LinkedIn once; an
agent does the scrolling and reading for you — no sitting at the computer.

It is not a fast/parallel scraper. It drives a **real, logged-in Chrome** via
the [`chrome-devtools` MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp)
with a headless `claude -p` agent that navigates each person's recent-activity
page, scrolls, reads the posts, and writes a dated markdown digest.

## How it differs from a classic Playwright scraper

Same underlying machinery (a browser driven over the Chrome DevTools Protocol,
riding your logged-in cookies), different driver:

| | Classic Playwright scraper | This (chrome-devtools MCP) |
|---|---|---|
| Driver | Hardcoded Python + selectors / JSON parsing | LLM agent reading the page live |
| Output | Deterministic CSV | Markdown digest |
| Robustness | Breaks on layout change | Adapts to whatever's on the page |
| Speed / cost | Fast, no AI | Slower, token-priced |

The agent approach is more resilient to LinkedIn's anti-bot layout churn, at the
cost of being slower — which is fine when the goal is "don't make me scroll".

## Prerequisites

- **WSL2 + Linux Google Chrome** at `/usr/bin/google-chrome-stable`, rendered
  via WSLg. The `--ozone-platform=wayland` flag is **mandatory** (headed Chrome
  crashes with SIGTRAP on the X11 path). This is already encoded in `.mcp.json`.
- **Claude Code CLI** (`claude`) on PATH.
- **One-time LinkedIn login.** Open the chrome-devtools Chrome once, log into
  LinkedIn. The session persists in the profile dir
  (`~/.cache/chrome-devtools-mcp/chrome-profile`) across runs.
- Only **one Chrome at a time** may hold that profile dir. Don't run this while
  another Claude session is actively driving the same browser (it'll fight over
  the profile lock). Close the other one first, or `pkill -f '/opt/google/chrome/chrome'`.

## Usage

```bash
./scan-linkedin.sh                       # read profiles.txt, up to 15 posts each
./scan-linkedin.sh -n 25                 # up to 25 posts per person
./scan-linkedin.sh https://www.linkedin.com/in/ghsim/   # ad-hoc URL(s)
./scan-linkedin.sh -f my-list.txt        # a different profile list
```

Edit `profiles.txt` to set who to watch (one URL per line; `#` comments OK).
Output lands in `output/linkedin-digest-YYYY-MM-DD.md` (git-ignored), with a
run log alongside it.

## Scheduling (optional, fully hands-off)

Once you trust a manual run, schedule it — e.g. every weekday morning:

```cron
30 8 * * 1-5  cd /path/to/linkedin-scraper && ./scan-linkedin.sh >> output/cron.log 2>&1
```

Caveat: if LinkedIn logs you out or throws a security checkpoint mid-run, an
unattended run has no human to clear it and will fail — just re-login and it
resumes working. Keep the cadence gentle to avoid tripping anti-automation.

## Notes / gotchas (learned the hard way)

- `navigate_page` often **reports a timeout even though the page loaded** —
  the agent is told to ignore that and snapshot anyway.
- Do **not** pass `--viewport` to the MCP; on maximized WSLg windows it drops
  the connection. Window size is set via `--chromeArg=--window-size` instead.
- Respect LinkedIn's Terms of Service. This reads pages you can already see when
  logged in; use it for personal research, at a human pace.
