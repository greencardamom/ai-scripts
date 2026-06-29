#!/bin/bash
#
# antigravity-query.sh — FLAT-RATE LLM query backend via the Antigravity CLI (`agy -p`).
#
# Mirrors the gemini-files.sh / claude-query.sh query contract so annomain can route to
# it as a provider driver. There is NO API key: AG authenticates via the user's
# subscription, and "cost" is QUOTA (refreshes ~every 5h), not dollars. The driver runs
# one headless agent query that READS the slice PDF and returns the requested JSON.
#
# Usage:
#   antigravity-query.sh --query <doc.pdf> --query-file <prompt.txt>
#                        [--model "<name>"] [--add-dir <dir>] [--timeout <dur>]
#                        [--json-output] [-v]
#
#   --query <doc.pdf>     the slice PDF the agent should read (required)
#   --query-file <path>   file with the extraction prompt (required)
#   --model "<name>"      AG model display name (default: "Gemini 3.1 Pro (High)";
#                         see `agy models` -- also Claude Sonnet 4.6 etc., flat-rate)
#   --add-dir <dir>       workspace dir the agent may read (default: the PDF's dir).
#                         Keep this MINIMAL -- with --dangerously-skip-permissions the
#                         agent auto-approves tool use, so don't expose the whole project.
#   --timeout <dur>       --print-timeout passed to agy (default 5m)
#   --json-output         accepted for interface parity (AG already prints the text/JSON)
#   -v                    verbose (to stderr)
#
# Output: agy's response (the model's JSON, usually ```json-fenced) on stdout, for
# extract_llm.py. AG returns no usage envelope (flat-rate) -> genmeta records no $ cost.
# Exit codes: 0 = ok; 1 = other error/timeout;
#   3 = QUOTA_5H     -- the rolling 5-hour window is exhausted (refreshes in <=5h);
#   4 = QUOTA_WEEKLY -- the per-bucket WEEKLY ceiling is hit (refreshes in days).
# IMPORTANT: Google emits the SAME error string for both ("Individual quota reached.
# Contact your administrator to enable overages."); the ONLY differentiator is the
# "Resets in <H>h<M>m<S>s" countdown the CLI appends. H<=5 => 5h window (exit 3);
# H>5 (e.g. 167h) or a day unit => weekly ceiling (exit 4). Each bucket (Gemini |
# Claude+GPT) has its OWN weekly limit, so a weekly lockout on one may leave the other
# usable. The reset string is echoed to stderr so the caller can schedule the retry.

AGY="${AGY_BIN:-agy}"
doc=""; query_file=""; model="Gemini 3.1 Pro (High)"; timeout_dur="5m"; add_dir=""; VERBOSE=0; hard_timeout=180

while [ $# -gt 0 ]; do
   case "$1" in
      --query)               doc="$2"; shift ;;
      --query-file)          query_file="$2"; shift ;;
      --model)               model="$2"; shift ;;
      --add-dir)             add_dir="$2"; shift ;;
      --timeout|--print-timeout) timeout_dur="$2"; shift ;;
      --hard-timeout)        hard_timeout="$2"; shift ;;   # external kill (s); agy's own timeout is unreliable
      --json-output)         : ;;                 # parity no-op
      -v|--verbose)          VERBOSE=1 ;;
      *) echo "antigravity-query.sh: unknown option: $1" >&2; exit 1 ;;
   esac
   shift
done

[ -f "$doc" ]        || { echo "Error: doc not found: $doc" >&2; exit 1; }
[ -f "$query_file" ] || { echo "Error: query file not found: $query_file" >&2; exit 1; }
[ -n "$add_dir" ]    || add_dir="$(dirname "$doc")"

# Prepend a read-the-file instruction; the extraction prompt (citefind/quote) follows.
prompt="Read the PDF file ${doc} and carefully follow the instructions below. Output ONLY the requested JSON object and nothing else.

$(cat "$query_file")"

[ "$VERBOSE" -eq 1 ] && echo "INFO: agy -p  model='$model'  add-dir='$add_dir'  doc='$doc'" >&2

errf="$(mktemp "${TMPDIR:-/tmp}/agq-err.XXXXXX")"
out="$(timeout "${hard_timeout}" "$AGY" -p "$prompt" --add-dir "$add_dir" --dangerously-skip-permissions \
       --model "$model" --print-timeout "$timeout_dur" 2>"$errf")"
rc=$?
err="$(cat "$errf" 2>/dev/null)"; rm -f "$errf"

# Hard external kill: agy's --print-timeout does NOT reliably bound runaway agentic loops
# (observed a 13min+ hang on one slice). `timeout` rc 124 (TERM) / 137 (KILL) -> treat as
# failure so the caller retries or falls back to the API backend.
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
   echo "TIMEOUT: agy exceeded ${hard_timeout}s (runaway agentic loop) -- treat as failure" >&2
   exit 1
fi

# Quota-exhaustion detection. The error STRING is identical for the 5h rolling window
# and the WEEKLY ceiling; the only signal is the appended "Resets in <H>h<M>m<S>s"
# countdown. H<=5 => 5h window (exit 3, short pause/API fallback then resume); H>5 or
# a day unit => weekly ceiling (exit 4, days-long lockout -> switch bucket / API).
quota_line="$(printf '%s\n%s\n' "$out" "$err" | grep -iE "individual quota reached|exceeded your current quota" | head -1)"
if [ -n "$quota_line" ]; then
   reset="$(printf '%s' "$quota_line" | grep -oiE "resets in[^.]*" | head -1)"
   rh="$(printf '%s' "$reset" | grep -oiE "[0-9]+h" | head -1 | tr -dc '0-9')"
   [ -z "$rh" ] && rh=0
   if printf '%s' "$reset" | grep -qiE "[0-9]+d" || [ "$rh" -gt 5 ]; then
      echo "QUOTA_WEEKLY: Antigravity weekly ceiling hit (${reset:-reset unknown}) -- bucket locked for days; switch bucket or fall back to API" >&2
      exit 4
   fi
   echo "QUOTA_5H: Antigravity 5h rolling quota hit (${reset:-reset unknown}) -- fall back to API or wait for refresh" >&2
   exit 3
fi
if [ "$rc" -ne 0 ]; then
   echo "$err" >&2
   exit 1
fi
printf '%s\n' "$out"
