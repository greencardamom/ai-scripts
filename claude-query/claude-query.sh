#!/bin/bash
#
# claude-query.sh — Anthropic Claude driver / general-purpose CLI
#
#   A provider-specific driver for the Anthropic Messages API, written to mirror
#   the conventions of gemini-files.sh + the gemini-query.sh family so it can sit
#   behind a common dispatcher later (annotools backlog item 8) AND stand alone
#   as a general Claude query tool for other projects.
#
#   Unlike Gemini, Claude needs NO upload/URI/delete lifecycle: a document
#   (PDF/image) is sent INLINE as a base64 block, so there is no --upload /
#   --delete / --list-files. A doc is just passed to --query as a local path.
#
#   Models: https://docs.anthropic.com/en/docs/about-claude/models
#   API:    https://docs.anthropic.com/en/api/messages
#
# Usage:
#   ./claude-query.sh [options] <ACTION>
#   Defaults to help if no action is given.
#
# Action Modes & Arguments:
#   --query [doc_path]     Run a query. Optional doc_path attaches a local PDF or
#                          image (inlined as base64). Requires a prompt via
#                          -q/--prompt or -f/--query-file. Without doc_path it is
#                          a plain text query.
#   --count-tokens [doc]   Print the input token count for the would-be request
#                          WITHOUT sending it (cheap cost pre-estimate). Honors
#                          the same prompt/doc/system/session/web-search options.
#   --list-models          List models available to this API key (GET /v1/models).
#                          The Claude analogue of gemini-files.sh --list — use it
#                          to verify access + exact model ids.
#   --clear                Clear the --session history file and exit.
#
# Query Input:
#   -q, --prompt <text>    Inline prompt text. Use '-' to read the prompt from stdin.
#   -f, --query-file <path> File containing the prompt text. (Takes precedence over -q.)
#   --system <text>        System prompt (Claude's first-class system field).
#   --system-file <path>   Read the system prompt from a file.
#   <doc_path> after --query attaches a PDF/image to the user turn (base64).
#
# Conversation Memory:
#   -s, --session <name>   Persist + continue a multi-turn conversation under this
#                          name (stored in SESSION_DIR/session_<name>.json). Prior
#                          turns are sent as context; the reply is appended after.
#   --clear                Delete the named session and exit (see above).
#
# Model / Generation:
#   -m, --model <name>     Model id (Default: DEFAULT_MODEL). Verify with --list-models.
#   --max-tokens <number>  Max output tokens (REQUIRED by the API; Default: DEFAULT_MAX_TOKENS).
#   --temperature <0..1>   Sampling temperature (optional; omitted if unset).
#   --web-search           Enable Claude's server-side web_search tool (the rough
#                          analogue of Gemini's -g/--ground live search).
#   --web-search-max <n>   Max web searches per request (Default: WEB_SEARCH_MAX_USES).
#   --media-type <type>    Override the doc media type (else auto-detected from the
#                          extension: .pdf .png .jpg/.jpeg .gif .webp).
#
# Output:
#   -o, --output-file <path>     Save the extracted text to a file (else stdout).
#   -or, --output-raw <path>     Save the raw API JSON response to a file.
#   -op, --output-payload <path> Save the JSON request payload that was sent.
#   --json-output                Print the raw API JSON instead of extracted text.
#
# Connection / Auth:
#   -k, --keyfile <path>   File containing the Anthropic API key.
#                          (Overrides the environment variable if both are set.)
#   --anthropic-version <v>  Override the anthropic-version header (Default: ANTHROPIC_VERSION).
#   --beta <value>         Set an anthropic-beta header (enable a beta feature).
#   --max-retries <n>      Retries on transient errors 429/500/503/529 (Default: MAX_RETRIES).
#   -v, --verbose          Verbose informational output to stderr (incl. token usage).
#   -h, --help             Show this help message.
#
# Usage Logging (one JSONL record per --query; cost is an ESTIMATE, console is truth):
#   --log-id <id>          Tag the record's "ia_id" (e.g. the book/identifier or label).
#   --log-project <name>   Tag the record's "project" (default: annotools).
#   --log-task <token>     Filename token / operation: claude-<token>-YYYYMM.jsonl (default: citefind).
#   --log-dir <path>       Log directory (default: $CLAUDE_LLM_LOGDIR or annotools/llmlogs).
#   --no-log               Disable usage logging for this call.
#
# API Key:
#   Sourced in order: 1) -k/--keyfile <path>; 2) the ANTHROPIC_API_KEY env var.
#
# Examples:
#   ./claude-query.sh -q "What is the capital of Maryland?" -k ./api.key
#   ./claude-query.sh --query book_slice.pdf -f extract_prompt.txt -k ./api.key --json-output
#   ./claude-query.sh -q "and its population?" -s mdchat -k ./api.key      # continues a session
#   ./claude-query.sh --list-models -k ./api.key
#

# --- Default Configuration ---
API_KEY_ENV_VAR="ANTHROPIC_API_KEY"
MESSAGES_URL="https://api.anthropic.com/v1/messages"
MODELS_URL="https://api.anthropic.com/v1/models"
COUNT_TOKENS_URL="https://api.anthropic.com/v1/messages/count_tokens"
DEFAULT_MODEL="claude-sonnet-4-6"          # cost-comparable to gemini-2.5-pro; verify with --list-models
DEFAULT_MAX_TOKENS=8192
ANTHROPIC_VERSION="2023-06-01"             # stable API version header
WEB_SEARCH_TOOL_TYPE="web_search_20250305" # server tool id for --web-search
WEB_SEARCH_MAX_USES=5
SESSION_DIR="${HOME}/.claude_sessions"
MAX_RETRIES=4
RETRY_BASE_DELAY=2                         # seconds; exponential backoff (2,4,8,16...)
# Usage logging: ONE record per --query appended to LOG_DIR/claude-pages-YYYYMM.jsonl
# in annotools' OWN spend log (the unified llmview-all/monitor_llm read annotools'
# gemini-pages-* + claude-pages-* from here; other consumers keep their own logs). Cost
# is an ESTIMATE from the price table in log_usage() (the Anthropic console is the
# billing source of truth). Disable with --no-log; relocate with --log-dir /
# $CLAUDE_LLM_LOGDIR. NOTE: when called from the annotools pipeline, pass --no-log --
# the pipeline logs once per run via genmeta to avoid double-counting.
LOG_DIR="${CLAUDE_LLM_LOGDIR:-/home/greenc/projects/annotools/llmlogs}"
LOG_TASK="citefind"   # filename token = the operation: claude-<task>-YYYYMM.jsonl (override w/ --log-task)
NO_LOG=0

# --- Runtime Variables ---
MODE=""
VIA="api"                         # --via api|claudecode : API (direct PDF attach) or Claude Code (`claude -p`, agentic)
EFFORT=""                         # --effort (claudecode path): claude -p reasoning level; empty = CLI default
hard_timeout=300                  # external kill for the claudecode path (seconds); claude -p json mode can run long
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
key_file_arg=""
API_KEY=""
doc_path=""
query_file_path=""
prompt_inline=""
system_text=""
system_file=""
session_name=""
model_name=""
max_output_tokens_arg=""
temperature_arg=""
media_type_arg=""
web_search_flag=0
web_search_max_arg=""
output_file=""
output_raw=""
output_payload=""
output_json_flag=0
anthropic_version_arg=""
beta_header_arg=""
max_retries_arg=""
log_id=""
log_project=""
VERBOSE=0
TMPFILES=()

# --- Cleanup ---
cleanup() { local f; for f in "${TMPFILES[@]}"; do [ -n "$f" ] && rm -f "$f"; done; }
trap cleanup EXIT
mktmp() { local t; t="$(mktemp "${TMPDIR:-/tmp}/claude-query.XXXXXX")"; TMPFILES+=("$t"); echo "$t"; }

# --- Logging ---
log_info() { [ "$VERBOSE" -eq 1 ] && echo "INFO: $*" >&2; return 0; }
log_err()  { echo "Error: $*" >&2; }

usage() {
   grep '^# Usage:' -A 2 "$0" | cut -c 3-
   echo; grep '^# Action Modes & Arguments:' -A 13 "$0" | cut -c 3-
   echo; grep '^# Query Input:' -A 6 "$0" | cut -c 3-
   echo; grep '^# Conversation Memory:' -A 5 "$0" | cut -c 3-
   echo; grep '^# Model / Generation:' -A 9 "$0" | cut -c 3-
   echo; grep '^# Output:' -A 5 "$0" | cut -c 3-
   echo; grep '^# Connection / Auth:' -A 7 "$0" | cut -c 3-
   echo; grep '^# Usage Logging' -A 5 "$0" | cut -c 3-
   echo; grep '^# API Key:' -A 2 "$0" | cut -c 3-
   exit 1
}

# --- Determine API key (--keyfile wins, else env var) ---
determine_api_key() {
   if [ -n "$key_file_arg" ]; then
      [ -f "$key_file_arg" ] || { log_err "key file not found: $key_file_arg"; exit 1; }
      API_KEY="$(tr -d '\n' < "$key_file_arg")"
      log_info "Using API key from file: $key_file_arg"
   elif [ -n "${!API_KEY_ENV_VAR:-}" ]; then
      API_KEY="${!API_KEY_ENV_VAR}"
      log_info "Using API key from \$$API_KEY_ENV_VAR"
   fi
   [ -n "$API_KEY" ] || { log_err "no API key (use -k/--keyfile or set \$$API_KEY_ENV_VAR)"; exit 1; }
}

# --- Guess media type from a file extension ---
detect_media_type() {
   case "${1,,}" in
      *.pdf)        echo "application/pdf" ;;
      *.png)        echo "image/png" ;;
      *.jpg|*.jpeg) echo "image/jpeg" ;;
      *.gif)        echo "image/gif" ;;
      *.webp)       echo "image/webp" ;;
      *)            echo "" ;;
   esac
}

session_file_path() { echo "${SESSION_DIR}/session_${session_name}.json"; }

# --- Build the request body (JSON) via python3; echoes JSON to stdout ---
# $1: for_count (1 => omit max_tokens, which count_tokens forbids)
build_payload() {
   local for_count="${1:-0}"
   local prompt=""
   if [ -n "$query_file_path" ]; then
      [ -f "$query_file_path" ] || { log_err "query file not found: $query_file_path"; exit 1; }
      prompt="$(cat "$query_file_path")"
   elif [ "$prompt_inline" = "-" ]; then
      prompt="$(cat)"
   else
      prompt="$prompt_inline"
   fi
   [ -n "$prompt" ] || { log_err "empty prompt (use -q/--prompt or -f/--query-file)"; exit 1; }

   local media=""
   if [ -n "$doc_path" ]; then
      [ -f "$doc_path" ] || { log_err "doc not found: $doc_path"; exit 1; }
      media="${media_type_arg:-$(detect_media_type "$doc_path")}"
      [ -n "$media" ] || { log_err "could not detect media type for $doc_path; pass --media-type"; exit 1; }
   fi

   local sfile=""; [ -n "$session_name" ] && sfile="$(session_file_path)"

   CL_MODEL="${model_name:-$DEFAULT_MODEL}" \
   CL_MAXTOK="${max_output_tokens_arg:-$DEFAULT_MAX_TOKENS}" \
   CL_TEMP="$temperature_arg" \
   CL_SYSTEM="$system_text" \
   CL_PROMPT="$prompt" \
   CL_DOC="$doc_path" \
   CL_MEDIA="$media" \
   CL_FORCOUNT="$for_count" \
   CL_SESSION="$sfile" \
   CL_WEBSEARCH="$web_search_flag" \
   CL_WSTYPE="$WEB_SEARCH_TOOL_TYPE" \
   CL_WSMAX="${web_search_max_arg:-$WEB_SEARCH_MAX_USES}" \
   python3 - <<'PY'
import os, json, base64, sys
content = []
doc, media = os.environ.get("CL_DOC",""), os.environ.get("CL_MEDIA","")
if doc:
    data = base64.standard_b64encode(open(doc,"rb").read()).decode("ascii")
    if media.startswith("image/"):
        content.append({"type":"image","source":{"type":"base64","media_type":media,"data":data}})
    else:
        content.append({"type":"document","source":{"type":"base64","media_type":media,"data":data}})
content.append({"type":"text","text": os.environ["CL_PROMPT"]})

# Multi-turn: load prior messages from the session file, if any.
messages = []
sfile = os.environ.get("CL_SESSION","")
if sfile and os.path.exists(sfile):
    try:
        messages = json.load(open(sfile)).get("messages", [])
    except Exception as e:
        sys.stderr.write("Warning: could not load session %s: %s\n" % (sfile, e))
messages.append({"role":"user","content":content})

body = {"model": os.environ["CL_MODEL"], "messages": messages}
if os.environ.get("CL_FORCOUNT") != "1":
    body["max_tokens"] = int(os.environ["CL_MAXTOK"])
if os.environ.get("CL_SYSTEM"): body["system"] = os.environ["CL_SYSTEM"]
t = os.environ.get("CL_TEMP","")
if t != "": body["temperature"] = float(t)
if os.environ.get("CL_WEBSEARCH") == "1":
    body["tools"] = [{"type": os.environ["CL_WSTYPE"], "name": "web_search",
                      "max_uses": int(os.environ["CL_WSMAX"])}]
json.dump(body, sys.stdout)
PY
}

# --- Append the assistant reply to the session file (multi-turn persistence) ---
update_session() {
   local body_file="$1" resp_file="$2" sfile="$3"
   BODY="$body_file" RESP="$resp_file" SFILE="$sfile" python3 - <<'PY'
import os, json, sys
try:
    body = json.load(open(os.environ["BODY"]))     # messages already include this turn's user msg
    resp = json.load(open(os.environ["RESP"]))
    if resp.get("type") == "error": sys.exit(0)    # don't persist a failed turn
    msgs = body.get("messages", [])
    msgs.append({"role":"assistant","content": resp.get("content", [])})
    json.dump({"messages": msgs}, open(os.environ["SFILE"], "w"))
except Exception as e:
    sys.stderr.write("Warning: could not update session: %s\n" % e)
PY
}

# --- curl POST with retry/backoff on transient errors; body -> $3 (file); sets HTTP_CODE ---
post_with_retry() {
   local url="$1" body_file="$2" out_file="$3"
   local retries="${max_retries_arg:-$MAX_RETRIES}" attempt=0 code delay
   local -a hdrs=( -H "x-api-key: $API_KEY"
                   -H "anthropic-version: ${anthropic_version_arg:-$ANTHROPIC_VERSION}"
                   -H "content-type: application/json" )
   [ -n "$beta_header_arg" ] && hdrs+=( -H "anthropic-beta: $beta_header_arg" )
   while : ; do
      code="$(curl -sS -o "$out_file" -w '%{http_code}' -X POST "$url" \
                   "${hdrs[@]}" --data-binary @"$body_file")" || { log_err "curl failed"; return 1; }
      HTTP_CODE="$code"
      case "$code" in
         2*) return 0 ;;
         429|500|503|529)
            attempt=$((attempt+1))
            [ "$attempt" -gt "$retries" ] && { log_err "HTTP $code after $retries retries"; return 1; }
            delay=$(( RETRY_BASE_DELAY * (2 ** (attempt-1)) ))
            log_info "HTTP $code (transient) — retry $attempt/$retries in ${delay}s"; sleep "$delay" ;;
         *) log_err "HTTP $code (non-retryable)"; return 1 ;;
      esac
   done
}

get_url() {
   local url="$1" out_file="$2"
   HTTP_CODE="$(curl -sS -o "$out_file" -w '%{http_code}' "$url" \
        -H "x-api-key: $API_KEY" \
        -H "anthropic-version: ${anthropic_version_arg:-$ANTHROPIC_VERSION}")" || { log_err "curl failed"; return 1; }
   case "$HTTP_CODE" in 2*) return 0 ;; *) log_err "HTTP $HTTP_CODE"; return 1 ;; esac
}

# --- Emit response: raw or extracted text, to stdout or --output-file ---
# NB: write to stdout via cat / sys.stdout (NOT `cp .. /dev/stdout` or open("/dev/stdout")),
# which reopen the fd O_TRUNC and corrupt output when stdout is redirected to a file.
emit_response() {
   local resp_file="$1"
   if [ "$output_json_flag" -eq 1 ]; then
      if [ -n "$output_file" ]; then cp "$resp_file" "$output_file"; else cat "$resp_file"; echo; fi
      return 0
   fi
   RESP="$resp_file" VERBOSE="$VERBOSE" OUTFILE="$output_file" python3 - <<'PY'
import os, json, sys
d = json.load(open(os.environ["RESP"]))
if d.get("type") == "error":
    sys.stderr.write("API error: %s\n" % json.dumps(d.get("error", d))); sys.exit(2)
txt = "".join(b.get("text","") for b in d.get("content",[]) if b.get("type")=="text")
txt = txt + ("" if txt.endswith("\n") else "\n")
out = os.environ.get("OUTFILE", "")
if out:
    with open(out, "w") as f: f.write(txt)
else:
    sys.stdout.write(txt)
if os.environ.get("VERBOSE") == "1":
    u = d.get("usage", {})
    sys.stderr.write("INFO: stop_reason=%s in=%s out=%s\n" %
        (d.get("stop_reason"), u.get("input_tokens"), u.get("output_tokens")))
PY
}

# --- Usage logging: append one JSONL record per --query (cost is an ESTIMATE) ---
log_usage() {
   local resp_file="$1"
   [ "$NO_LOG" -eq 1 ] && return 0
   mkdir -p "$LOG_DIR" 2>/dev/null || { log_info "cannot create log dir $LOG_DIR; skipping usage log"; return 0; }
   CL_RESP="$resp_file" CL_LOGDIR="$LOG_DIR" CL_PROJECT="$log_project" CL_ID="$log_id" \
   CL_TASK="$LOG_TASK" CL_MODEL_REQ="${model_name:-$DEFAULT_MODEL}" python3 - <<'PY'
import os, json, time
# USD per 1M tokens (input, output). *** VERIFY against current Anthropic pricing. ***
PRICES = {
    "claude-opus":   (15.0, 75.0),
    "claude-sonnet": (3.0, 15.0),
    "claude-haiku":  (1.0, 5.0),
    "claude-fable":  (5.0, 25.0),   # estimate
}
def rate(model):
    for k, v in PRICES.items():
        if model.startswith(k): return v
    return (3.0, 15.0)
try:
    d = json.load(open(os.environ["CL_RESP"]))
except Exception:
    d = {}
is_err = d.get("type") == "error"
model = d.get("model") or os.environ["CL_MODEL_REQ"]
u = d.get("usage", {}) or {}
itok = u.get("input_tokens", 0) or 0
otok = u.get("output_tokens", 0) or 0
cread = u.get("cache_read_input_tokens", 0) or 0
ccreate = u.get("cache_creation_input_tokens", 0) or 0
ri, ro = rate(model)
cost = (itok*ri + otok*ro + cread*ri*0.1 + ccreate*ri*1.25) / 1_000_000.0
rec = {
    "provider": "anthropic",
    "project": os.environ.get("CL_PROJECT","") or "annotools",
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "model": model,
    "input_tokens": itok,
    "output_tokens": otok,
    "cost_usd": round(cost, 8),
    "ia_id": os.environ.get("CL_ID","") or "",
    "success": (not is_err) and bool(d.get("content")),
}
path = os.path.join(os.environ["CL_LOGDIR"], "claude-%s-%s.jsonl" % (os.environ.get("CL_TASK","citefind"), time.strftime("%Y%m", time.gmtime())))
try:
    with open(path, "a") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")   # compact, matches gemini-pages format
except Exception as e:
    import sys; sys.stderr.write("INFO: usage log write failed: %s\n" % e)
PY
}

# --- Actions ---
do_messages_request() {   # shared by --query and --count-tokens
   local url="$1" for_count="$2"
   determine_api_key
   local body resp sfile=""
   body="$(mktmp)"; resp="$(mktmp)"
   build_payload "$for_count" > "$body"
   [ -n "$output_payload" ] && cp "$body" "$output_payload"
   log_info "POST $url model=${model_name:-$DEFAULT_MODEL} doc=${doc_path:-none} session=${session_name:-none}"
   if ! post_with_retry "$url" "$body" "$resp"; then
      [ "$for_count" = "0" ] && log_usage "$resp"   # log the failed query (success:false)
      cat "$resp" >&2; exit 1
   fi
   [ -n "$output_raw" ] && cp "$resp" "$output_raw"
   if [ "$for_count" = "1" ]; then
      if [ "$output_json_flag" -eq 1 ]; then cat "$resp"; echo; else
         python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('input_tokens'))" "$resp"
      fi
      return 0
   fi
   log_usage "$resp"                                # log the successful query
   emit_response "$resp"
   if [ -n "$session_name" ]; then update_session "$body" "$resp" "$(session_file_path)"; fi
   return 0
}

do_list_models() {
   determine_api_key
   local resp; resp="$(mktmp)"
   get_url "$MODELS_URL" "$resp" || { cat "$resp" >&2; exit 1; }
   [ -n "$output_raw" ] && cp "$resp" "$output_raw"
   if [ "$output_json_flag" -eq 1 ]; then cat "$resp"; echo; else
      python3 -c "import json,sys
for m in json.load(open(sys.argv[1])).get('data',[]): print(m.get('id'),'\t',m.get('display_name',''))" "$resp"
   fi
}

do_clear_session() {
   [ -n "$session_name" ] || { log_err "--clear requires -s/--session <name>"; exit 1; }
   local f; f="$(session_file_path)"
   [ -f "$f" ] && { rm -f "$f"; log_info "cleared session: $session_name"; } || log_info "no session to clear: $session_name"
}

# --- Argument parsing ---
[ $# -eq 0 ] && usage
while [ $# -gt 0 ]; do
   case "$1" in
      --query)         MODE="query";  [ $# -ge 2 ] && [[ "$2" != -* ]] && { doc_path="$2"; shift; } ;;
      --count-tokens)  MODE="count";  [ $# -ge 2 ] && [[ "$2" != -* ]] && { doc_path="$2"; shift; } ;;
      --list-models)   MODE="list-models" ;;
      --clear)         MODE="clear" ;;
      -q|--prompt)         prompt_inline="$2";   shift ;;
      -f|--query-file)     query_file_path="$2"; shift ;;
      --system)            system_text="$2";     shift ;;
      --system-file)       system_file="$2";     shift ;;
      -s|--session)        session_name="$2";    shift ;;
      -m|--model)          model_name="$2";      shift ;;
      --via)               VIA="${2,,}";         shift ;;   # api | claudecode
      --effort)            EFFORT="$2";          shift ;;   # claudecode path: claude -p --effort (low|medium|high|xhigh|max)
      --hard-timeout)      hard_timeout="$2";    shift ;;   # claudecode path external kill (s)
      --max-tokens)        max_output_tokens_arg="$2"; shift ;;
      --temperature)       temperature_arg="$2"; shift ;;
      --web-search)        web_search_flag=1 ;;
      --web-search-max)    web_search_max_arg="$2"; shift ;;
      --media-type)        media_type_arg="$2";  shift ;;
      -o|--output-file)    output_file="$2";     shift ;;
      -or|--output-raw)    output_raw="$2";      shift ;;
      -op|--output-payload) output_payload="$2"; shift ;;
      --json-output)       output_json_flag=1 ;;
      -k|--keyfile)        key_file_arg="$2";    shift ;;
      --anthropic-version) anthropic_version_arg="$2"; shift ;;
      --beta)              beta_header_arg="$2"; shift ;;
      --max-retries)       max_retries_arg="$2"; shift ;;
      --log-id)            log_id="$2";          shift ;;
      --log-project)       log_project="$2";     shift ;;
      --log-task)          LOG_TASK="$2";        shift ;;
      --log-dir)           LOG_DIR="$2";         shift ;;
      --no-log)            NO_LOG=1 ;;
      -v|--verbose)        VERBOSE=1 ;;
      -h|--help)           usage ;;
      *) log_err "unknown option: $1"; usage ;;
   esac
   shift
done

if [ -n "$session_name" ]; then mkdir -p "$SESSION_DIR"; fi
if [ -n "$system_file" ]; then
   [ -f "$system_file" ] || { log_err "system file not found: $system_file"; exit 1; }
   system_text="$(cat "$system_file")"
fi

# --- Claude Code (agentic) path: drive `claude -p` instead of the API. The model
# reads the PDF via its own tools (agentic, like agy), drawing the Claude Code seat's
# flat-rate quota rather than per-token API billing. Output may be prose-wrapped;
# extract_llm.py / the worker parser already tolerate that. The Claude Code env of the
# parent session is cleared so the child doesn't try to attach/resume this session. ---
do_claudecode_query() {
   [ -n "$doc_path" ] || { log_err "--via claudecode needs --query <doc.pdf>"; exit 1; }
   [ -f "$doc_path" ] || { log_err "doc not found: $doc_path"; exit 1; }
   local prompt adddir errf out rc err
   if [ -n "$query_file_path" ]; then
      [ -f "$query_file_path" ] || { log_err "query file not found: $query_file_path"; exit 1; }
      prompt="Read the PDF file ${doc_path} and carefully follow the instructions below. Output ONLY the requested JSON object and nothing else.

$(cat "$query_file_path")"
   else
      prompt="Read the PDF file ${doc_path}. ${prompt_inline}"
   fi
   adddir="$(dirname "$doc_path")"
   errf="$(mktemp "${TMPDIR:-/tmp}/ccq-err.XXXXXX")"
   local effort_args=(); [ -n "$EFFORT" ] && effort_args=(--effort "$EFFORT")
   [ "${VERBOSE:-0}" = 1 ] && log_err "claude -p  model='${model_name:-sonnet}'  effort='${EFFORT:-default}'  add-dir='$adddir'  doc='$doc_path'"
   # --output-format json so the envelope carries token usage + Claude Code's own cost
   # estimate; we extract .result for stdout (downstream unchanged) and log .usage. The
   # inherited CLAUDE_EFFORT is cleared so the child doesn't pick up THIS session's level;
   # --effort (if given) sets it explicitly for the child run.
   out="$(env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
              -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT \
          timeout "$hard_timeout" "$CLAUDE_BIN" -p "$prompt" --add-dir "$adddir" \
          --dangerously-skip-permissions --model "${model_name:-sonnet}" \
          "${effort_args[@]}" --output-format json 2>"$errf")"
   rc=$?
   err="$(cat "$errf" 2>/dev/null)"; rm -f "$errf"
   if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      log_err "TIMEOUT: claude -p exceeded ${hard_timeout}s"; exit 1
   fi
   if [ "$rc" -ne 0 ]; then log_err "claude -p failed (rc=$rc): ${err:0:300}"; exit 1; fi

   # Usage log (per query, gated by --no-log). Cost is Claude Code's OWN estimate at API
   # rates incl. its system-prompt overhead -- NOT the flat-rate seat draw, which is
   # unknown; logged (not reported) as a reference only. -> claudecode-<task>-YYYYMM.jsonl
   if [ "${NO_LOG:-0}" != 1 ] && command -v jq >/dev/null 2>&1; then
      mkdir -p "$LOG_DIR" 2>/dev/null && \
      printf '%s' "$out" | jq -c --arg model "${model_name:-sonnet}" --arg doc "$(basename "$doc_path")" \
         --arg task "$LOG_TASK" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '{provider:"claudecode", via:"claudecode", task:$task, timestamp:$ts, model:$model, doc:$doc,
           input_tokens:(.usage.input_tokens//0), output_tokens:(.usage.output_tokens//0),
           cache_creation:(.usage.cache_creation_input_tokens//0), cache_read:(.usage.cache_read_input_tokens//0),
           cost_usd_estimate:.total_cost_usd, duration_ms:.duration_ms, stop_reason:.stop_reason}' \
         >> "$LOG_DIR/claudecode-${LOG_TASK}-$(date -u +%Y%m).jsonl" 2>/dev/null || true
   fi

   # extract the model text; fall back to raw envelope if jq/.result unavailable
   if command -v jq >/dev/null 2>&1; then
      local text; text="$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)"
      [ -n "$text" ] && { printf '%s\n' "$text"; return 0; }
      log_err "claudecode: no .result in JSON envelope; emitting raw"
   fi
   printf '%s\n' "$out"
}

case "$MODE" in
   query)        if [ "$VIA" = "claudecode" ]; then do_claudecode_query
                 else do_messages_request "$MESSAGES_URL" 0; fi ;;
   count)        do_messages_request "$COUNT_TOKENS_URL" 1 ;;
   list-models)  do_list_models ;;
   clear)        do_clear_session ;;
   *)            usage ;;
esac
