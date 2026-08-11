#!/usr/bin/bash

#
# Script: liftwing-query.sh
# Purpose: CLI utility to query Wikimedia LiftWing LLMs (OpenAI-compatible API)
# Repo: n/a
# Created: August 2026
# Author: GreenC
# Formatting: shfmt -i 3 -ci liftwing-query.sh
#
# Docs: https://wikitech.wikimedia.org/wiki/Machine_Learning/LiftWing/Large_Language_Models
#
# Unlike the other adapters in this repo, LiftWing speaks the OpenAI Chat
# Completions dialect (messages[] in, choices[0].message.content out) and is
# FREE -- so there is no cost logging here.
#
# Auth is OPTIONAL but strongly recommended:
#   anonymous          -> 100 requests/hour   (x-wmf-ratelimit-class: unauthed-bot)
#   Bearer <JWT>       -> higher tier         (x-wmf-ratelimit-class: authed-user)
# The bearer token MUST be an OAuth 2.0 access token (a JWT: three dot-separated
# base64 sections). OAuth 1.0a credentials -- the four-part consumer key/secret +
# access key/secret set -- are NOT accepted by the api.wikimedia.org gateway.
# Register an owner-only OAuth 2.0 client at:
#   https://meta.wikimedia.org/wiki/Special:OAuthConsumerRegistration/propose/oauth2
# Tick "for use only by <user>"; owner-only tokens are non-expiring, so this
# script just reads the token from a file -- there is no refresh flow.
#

# The MIT License (MIT)
#
# Copyright (c) 2026 by User:GreenC (at en.wikipedia.org)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# --- Script Configuration ---
SCRIPT_NAME="liftwing-query.sh"
# Environment variable consulted when --key-file is not given
TOKEN_ENV_VAR="LIFTWING_TOKEN"
# Secret directories searched, in order, for the default token and the tfproxy
# credentials. Hosts keep secrets in different places; searching a list keeps ONE
# script identical everywhere instead of a per-host fork.
SECRET_SEARCH_DIRS=(
   "${HOME}/.config/wikiget/secrets"
   "${HOME}/scripts/secrets"
   "${HOME}/toolforge/scripts/secrets"
)
# Basenames looked up inside SECRET_SEARCH_DIRS
TOKEN_BASENAME="greencbot.oauth2token"
TFPROXY_URL_BASENAME="tfproxy.url"
TFPROXY_HEADER_BASENAME="tfproxy.header"
TFPROXY_PASSWORD_BASENAME="tfproxy.password"
# Endpoint template; %s is replaced by the model id
API_URL_TEMPLATE="https://api.wikimedia.org/service/lw/inference/v1/models/%s/openai/v1/chat/completions"
# The default model to use if not specified via --model
DEFAULT_MODEL="llm-qwen3-14b"
DEFAULT_MAX_TOKENS=4096
# WMF policy requires a descriptive User-Agent identifying the operator
DEFAULT_USER_AGENT="liftwing-query/1.0 (https://en.wikipedia.org/wiki/User:GreenC)"
DEFAULT_MAX_RETRIES=4
RETRY_BASE_DELAY=2 # seconds; exponential backoff (2,4,8,16...)
DEFAULT_TIMEOUT=300

# Exit codes: 0 ok | 1 usage/local error | 2 API error | 3 rate limited (429)
EXIT_USAGE=1
EXIT_API=2
EXIT_RATELIMIT=3

# --- Function Definitions ---

#
# Displays the help message for the script.
#
show_help() {
   echo "Usage: ${SCRIPT_NAME} [options]"
   echo ""
   echo "Sends a query to a Wikimedia LiftWing LLM and prints the response."
   echo ""
   echo "Query input (one of --query or --file is required):"
   echo "  -q, --query <string>      A string containing the query to send."
   echo "  -f, --file <path>         Path to a file containing the query."
   echo "      --system <text>       Optional system prompt."
   echo "      --system-file <path>  Read the system prompt from a file."
   echo ""
   echo "Model / generation:"
   echo "  -m, --model <name>        Model to use. Defaults to '${DEFAULT_MODEL}'."
   echo "                            Known: llm-qwen3-14b (16k ctx), llm-qwen36-27b (32k ctx)."
   echo "      --max-tokens <n>      Max output tokens (Default: ${DEFAULT_MAX_TOKENS})."
   echo "      --temperature <0..2>  Sampling temperature (omitted if unset)."
   echo "      --top-p <0..1>        Nucleus sampling (omitted if unset)."
   echo ""
   echo "Output:"
   echo "  -o,  --output-file <path>    Save the extracted text (else stdout)."
   echo "  -op, --output-payload <path> Save the JSON payload sent to the API."
   echo "  -or, --output-raw <path>     Save the raw JSON response from the API."
   echo "       --json-output           Print the raw API JSON instead of extracted text."
   echo ""
   echo "Connection / auth:"
   echo "      --via <direct|tfproxy> How to reach LiftWing (Default: direct)."
   echo "                            direct  = straight to api.wikimedia.org. Subject to the"
   echo "                                      100 req/hour cap shared across ALL llm-* models,"
   echo "                                      which a token does NOT raise (see below)."
   echo "                            tfproxy = through a Toolforge proxy. Toolforge is a"
   echo "                                      'known network' = effectively unlimited. No token"
   echo "                                      is sent; the tier comes from the request origin."
   echo "  -k, --key-file <path>     File containing an OAuth 2.0 access token (JWT)."
   echo "                            Overrides \$${TOKEN_ENV_VAR}. Omit for anonymous"
   echo "                            access (capped at 100 requests/hour)."
   echo "      --anon                Force anonymous; ignore any token or default keyfile."
   echo "      --user-agent <str>    Override the User-Agent header."
   echo "      --max-retries <n>     Retries on 429/5xx (Default: ${DEFAULT_MAX_RETRIES})."
   echo "      --timeout <seconds>   Per-request timeout (Default: ${DEFAULT_TIMEOUT})."
   echo "  -v, --verbose             Verbose logging ('Info:' messages to stderr)."
   echo "  -h, --help                Show this help message."
   echo ""
   echo "Token resolution order (--via direct only):"
   echo "  1) --key-file <path>  2) \$${TOKEN_ENV_VAR}  3) ${TOKEN_BASENAME} in a secret dir"
   echo "  4) anonymous (no Authorization header)"
   echo "  The token must be an OAuth 2.0 JWT, not OAuth 1.0a consumer credentials."
   echo ""
   echo "Secret directories searched, in order (first match wins):"
   printf '  %s\n' "${SECRET_SEARCH_DIRS[@]}"
   echo ""
   echo "Rate limits (LiftWing defines three tiers):"
   echo "  anonymous / authenticated : 100 req/hour, SHARED across all llm-* models."
   echo "                              An OAuth 2.0 JWT does NOT raise this -- it only"
   echo "                              changes the gateway's ratelimit class."
   echo "  known network (Toolforge) : effectively unlimited -> use --via tfproxy"
   echo "  approved bot              : effectively unlimited -> request from the ML team"
   echo "                              (phabricator #Machine-Learning-Team, ml@wikimedia.org)"
   echo ""
   echo "Exit codes:"
   echo "  0 success | 1 usage/local error | 2 API error | 3 rate limited (429)"
   echo ""
   echo "Examples:"
   echo "  ${SCRIPT_NAME} -q \"What is the capital of Maryland?\""
   echo "  ${SCRIPT_NAME} -f prompt.txt -m llm-qwen36-27b -o out.txt -v"
   echo "  ${SCRIPT_NAME} --via tfproxy --system-file cite-system.txt --temperature 0 \\"
   echo "     --max-tokens 512 -q \"<the citation>\"      # bulk/agentic use"
}

#
# Echoes the path of the first SECRET_SEARCH_DIRS entry containing $1, else "".
#
find_secret() {
   local base="$1" dir
   for dir in "${SECRET_SEARCH_DIRS[@]}"; do
      if [[ -f "${dir}/${base}" ]]; then
         echo "${dir}/${base}"
         return 0
      fi
   done
   return 0
}

#
# Reads a secret file, stripping surrounding whitespace/newlines.
#
read_secret() {
   tr -d '[:space:]' <"$1"
}

#
# Prints informational messages to stderr if VERBOSE is true.
#
log_info() {
   if [[ "${VERBOSE}" == "true" ]]; then
      echo "Info: $*" >&2
   fi
}

#
# Removes temporary working files on exit.
#
cleanup() {
   [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
}

#
# Parses command-line arguments and sets global variables.
#
parse_arguments() {
   while [[ "$#" -gt 0 ]]; do
      case $1 in
         -q | --query)
            QUERY_STRING="$2"
            shift 2
            ;;
         -f | --file)
            QUERY_FILE="$2"
            shift 2
            ;;
         --system)
            SYSTEM_STRING="$2"
            shift 2
            ;;
         --system-file)
            SYSTEM_FILE="$2"
            shift 2
            ;;
         -m | --model)
            MODEL="$2"
            shift 2
            ;;
         --max-tokens)
            MAX_TOKENS="$2"
            shift 2
            ;;
         --temperature)
            TEMPERATURE="$2"
            shift 2
            ;;
         --top-p)
            TOP_P="$2"
            shift 2
            ;;
         -o | --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
         -op | --output-payload)
            OUTPUT_PAYLOAD_FILE="$2"
            shift 2
            ;;
         -or | --output-raw)
            OUTPUT_RAW_FILE="$2"
            shift 2
            ;;
         --json-output)
            JSON_OUTPUT="true"
            shift 1
            ;;
         -k | --key-file)
            TOKEN_FILE="$2"
            shift 2
            ;;
         --anon)
            ANON="true"
            shift 1
            ;;
         --via)
            VIA="$2"
            shift 2
            ;;
         --user-agent)
            USER_AGENT="$2"
            shift 2
            ;;
         --max-retries)
            MAX_RETRIES="$2"
            shift 2
            ;;
         --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
         -v | --verbose)
            VERBOSE="true"
            shift 1
            ;;
         -h | --help)
            show_help
            exit 0
            ;;
         *)
            echo "Error: Unknown parameter passed: $1" >&2
            show_help >&2
            exit "${EXIT_USAGE}"
            ;;
      esac
   done
}

#
# Validates that all required inputs have been provided correctly.
#
validate_input() {
   if [[ -n "${QUERY_STRING}" && -n "${QUERY_FILE}" ]]; then
      echo "Error: Please provide either --query or --file, not both." >&2
      exit "${EXIT_USAGE}"
   fi
   if [[ -z "${QUERY_STRING}" && -z "${QUERY_FILE}" ]]; then
      echo "Error: Missing input. Please provide either --query or --file." >&2
      show_help >&2
      exit "${EXIT_USAGE}"
   fi
   if [[ -n "${SYSTEM_STRING}" && -n "${SYSTEM_FILE}" ]]; then
      echo "Error: Please provide either --system or --system-file, not both." >&2
      exit "${EXIT_USAGE}"
   fi
   if [[ ! "${MAX_TOKENS}" =~ ^[0-9]+$ ]]; then
      echo "Error: --max-tokens must be a positive integer." >&2
      exit "${EXIT_USAGE}"
   fi
   if [[ ! "${MAX_RETRIES}" =~ ^[0-9]+$ ]]; then
      echo "Error: --max-retries must be a non-negative integer." >&2
      exit "${EXIT_USAGE}"
   fi
   if [[ "${VIA}" != "direct" && "${VIA}" != "tfproxy" ]]; then
      echo "Error: --via must be 'direct' or 'tfproxy' (got '${VIA}')." >&2
      exit "${EXIT_USAGE}"
   fi
}

#
# Loads the tfproxy URL / auth header / secret into globals. Only called for
# --via tfproxy.
#
load_tfproxy_config() {
   local url_file header_file password_file
   url_file=$(find_secret "${TFPROXY_URL_BASENAME}")
   header_file=$(find_secret "${TFPROXY_HEADER_BASENAME}")
   password_file=$(find_secret "${TFPROXY_PASSWORD_BASENAME}")

   if [[ -z "${url_file}" || -z "${header_file}" || -z "${password_file}" ]]; then
      echo "Error: --via tfproxy needs ${TFPROXY_URL_BASENAME}, ${TFPROXY_HEADER_BASENAME}" >&2
      echo "       and ${TFPROXY_PASSWORD_BASENAME} in one of:" >&2
      printf '         %s\n' "${SECRET_SEARCH_DIRS[@]}" >&2
      exit "${EXIT_USAGE}"
   fi

   TFPROXY_URL=$(read_secret "${url_file}")
   TFPROXY_AUTH_HEADER=$(read_secret "${header_file}")
   TFPROXY_SECRET=$(read_secret "${password_file}")

   # The stored URL already ends in "?target=". Tolerate either form rather than
   # silently building "?target=?target=..." -- PHP then hands cURL a malformed
   # URL and the proxy returns an opaque 502.
   if [[ "${TFPROXY_URL}" != *"?target=" ]]; then
      if [[ "${TFPROXY_URL}" == *"?"* ]]; then
         TFPROXY_URL="${TFPROXY_URL}&target="
      else
         TFPROXY_URL="${TFPROXY_URL}?target="
      fi
   fi

   log_info "Routing via Toolforge proxy (found config in $(dirname "${url_file}"))"
}

#
# Resolves the bearer token into the global TOKEN ("" = anonymous).
# Sets a global rather than echoing: a command substitution would run this in a
# subshell, where a fatal `exit` would be swallowed and a bad token would
# silently degrade to an anonymous request.
#
get_token() {
   local token=""
   TOKEN=""

   # Toolforge egress is a "known network", which is LiftWing's unlimited tier by
   # ORIGIN -- a JWT adds nothing there, so don't put the secret on the wire.
   if [[ "${VIA}" == "tfproxy" ]]; then
      log_info "Proxy mode: no bearer token needed (Toolforge is a known network)."
      return 0
   fi

   if [[ "${ANON}" == "true" ]]; then
      log_info "Anonymous mode forced (--anon); 100 requests/hour cap applies."
      return 0
   fi

   if [[ -n "${TOKEN_FILE}" ]]; then
      if [[ ! -f "${TOKEN_FILE}" ]]; then
         echo "Error: token file '${TOKEN_FILE}' not found." >&2
         exit "${EXIT_USAGE}"
      fi
      token=$(tr -d '[:space:]' <"${TOKEN_FILE}")
      log_info "Using token from file: ${TOKEN_FILE}"
   elif [[ -n "${!TOKEN_ENV_VAR}" ]]; then
      token="${!TOKEN_ENV_VAR}"
      token="${token//[[:space:]]/}"
      log_info "Using token from \$${TOKEN_ENV_VAR}."
   elif [[ -n "$(find_secret "${TOKEN_BASENAME}")" ]]; then
      local found
      found=$(find_secret "${TOKEN_BASENAME}")
      token=$(read_secret "${found}")
      log_info "Using token from default keyfile: ${found}"
   else
      log_info "No token found; proceeding anonymously (100 requests/hour cap)."
      return 0
   fi

   # An OAuth 2.0 access token is a JWT: header.payload.signature. Catch the
   # common mistake of pointing -k at an OAuth 1.0a key/secret file, which the
   # gateway rejects with an opaque 401.
   if [[ -n "${token}" && "${token}" != *.*.* ]]; then
      echo "Error: token does not look like a JWT (expected three dot-separated sections)." >&2
      echo "       LiftWing needs an OAuth 2.0 access token, not OAuth 1.0a credentials." >&2
      echo "       Register one at: https://meta.wikimedia.org/wiki/Special:OAuthConsumerRegistration/propose/oauth2" >&2
      exit "${EXIT_USAGE}"
   fi

   TOKEN="${token}"
}

#
# Reads prompt text from a file or uses the direct string, into the variable
# named by $1. Assigns via nameref for the same reason get_token() does.
#
read_text_input() {
   local -n _dest="$1"
   local direct="$2" path="$3" label="$4"
   local text

   if [[ -n "${path}" ]]; then
      if [[ ! -f "${path}" ]]; then
         echo "Error: ${label} file '${path}' not found." >&2
         exit "${EXIT_USAGE}"
      fi
      text=$(<"${path}")
      if [[ -z "${text//[[:space:]]/}" ]]; then
         echo "Error: ${label} file '${path}' is empty or whitespace only." >&2
         exit "${EXIT_USAGE}"
      fi
   else
      text="${direct}"
   fi

   _dest="${text}"
}

#
# Generates the OpenAI-format JSON payload. Values are passed through the
# environment so no shell quoting can corrupt them.
#
generate_payload() {
   LWQ_PROMPT="$1" \
      LWQ_SYSTEM="$2" \
      LWQ_MODEL="${MODEL}" \
      LWQ_MAX_TOKENS="${MAX_TOKENS}" \
      LWQ_TEMPERATURE="${TEMPERATURE}" \
      LWQ_TOP_P="${TOP_P}" \
      python3 -c '
import json, os, sys

messages = []
system = os.environ.get("LWQ_SYSTEM", "")
if system:
    messages.append({"role": "system", "content": system})
messages.append({"role": "user", "content": os.environ["LWQ_PROMPT"]})

payload = {
    "model": os.environ["LWQ_MODEL"],
    "messages": messages,
    "max_tokens": int(os.environ["LWQ_MAX_TOKENS"]),
}
temperature = os.environ.get("LWQ_TEMPERATURE", "")
if temperature:
    payload["temperature"] = float(temperature)
top_p = os.environ.get("LWQ_TOP_P", "")
if top_p:
    payload["top_p"] = float(top_p)

json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
'
}

#
# POSTs the payload, retrying on 429 and 5xx. Sets the global RAW_OUTPUT.
# Sets a global rather than echoing so the EXIT_RATELIMIT / EXIT_API exits below
# terminate the script instead of just a command-substitution subshell.
#
make_api_request() {
   local payload="$1"
   local url target attempt=0 http_code retry_after delay
   local body_file="${TMP_DIR}/body.json"
   local head_file="${TMP_DIR}/headers.txt"
   local cookie_jar="${TMP_DIR}/cookies.txt"

   printf -v target "${API_URL_TEMPLATE}" "${MODEL}"
   if [[ "${VIA}" == "tfproxy" ]]; then
      # The proxy takes the destination in ?target=, URL-encoded exactly once.
      local encoded
      encoded=$(LWQ_TARGET="${target}" python3 -c \
         'import os, urllib.parse, sys; sys.stdout.write(urllib.parse.quote(os.environ["LWQ_TARGET"], safe=""))')
      url="${TFPROXY_URL}${encoded}"
      log_info "POST ${target} (via Toolforge proxy)"
   else
      url="${target}"
      log_info "POST ${url}"
   fi
   log_info "Model: ${MODEL}, max_tokens: ${MAX_TOKENS}"

   while :; do
      attempt=$((attempt + 1))

      # Owner-only OAuth 2.0 tokens are rate-limited more aggressively unless the
      # client returns the gateway's session cookies, so carry a per-run jar.
      local -a curl_args=(
         -sS -X POST "${url}"
         -H "Content-Type: application/json"
         -H "User-Agent: ${USER_AGENT}"
         -c "${cookie_jar}" -b "${cookie_jar}"
         -D "${head_file}" -o "${body_file}"
         -w '%{http_code}'
         --max-time "${TIMEOUT}"
         -d @-
      )
      if [[ -n "${TOKEN}" ]]; then
         curl_args+=(-H "Authorization: Bearer ${TOKEN}")
      fi
      if [[ "${VIA}" == "tfproxy" ]]; then
         curl_args+=(-H "${TFPROXY_AUTH_HEADER}: ${TFPROXY_SECRET}")
      fi

      http_code=$(printf '%s' "${payload}" | curl "${curl_args[@]}" 2>"${TMP_DIR}/curl.err")

      if [[ -z "${http_code}" || "${http_code}" == "000" ]]; then
         log_info "Attempt ${attempt}: connection failed: $(<"${TMP_DIR}/curl.err")"
         if ((attempt > MAX_RETRIES)); then
            echo "Error: curl failed after ${attempt} attempt(s)." >&2
            [[ -s "${TMP_DIR}/curl.err" ]] && cat "${TMP_DIR}/curl.err" >&2
            exit "${EXIT_API}"
         fi
         delay=$((RETRY_BASE_DELAY ** attempt))
         log_info "Retrying in ${delay}s..."
         sleep "${delay}"
         continue
      fi

      log_info "Attempt ${attempt}: HTTP ${http_code} (ratelimit-class: $(get_header "${head_file}" 'x-wmf-ratelimit-class'))"

      case "${http_code}" in
         2*)
            RAW_OUTPUT=$(<"${body_file}")
            return 0
            ;;
         429)
            if ((attempt > MAX_RETRIES)); then
               echo "Error: rate limited (HTTP 429) after ${attempt} attempt(s)." >&2
               if [[ -z "${TOKEN}" ]]; then
                  echo "       Running anonymously (100 req/hr). Supply an OAuth 2.0 token with -k for a higher tier." >&2
               fi
               exit "${EXIT_RATELIMIT}"
            fi
            retry_after=$(get_header "${head_file}" 'retry-after')
            if [[ "${retry_after}" =~ ^[0-9]+$ ]]; then
               delay="${retry_after}"
               log_info "Rate limited; honoring Retry-After: ${delay}s"
            else
               delay=$((RETRY_BASE_DELAY ** attempt))
               log_info "Rate limited; backing off ${delay}s"
            fi
            sleep "${delay}"
            ;;
         5*)
            if ((attempt > MAX_RETRIES)); then
               echo "Error: server error (HTTP ${http_code}) after ${attempt} attempt(s)." >&2
               [[ -s "${body_file}" ]] && head -c 500 "${body_file}" >&2 && echo >&2
               if [[ "${VIA}" == "tfproxy" && "${http_code}" == "502" ]]; then
                  echo "       A 502 from the proxy means its server-side cURL failed -- most likely the" >&2
                  echo "       25s upstream timeout. Lower --max-tokens (a citation needs ~512, not 4096)." >&2
               fi
               exit "${EXIT_API}"
            fi
            delay=$((RETRY_BASE_DELAY ** attempt))
            log_info "Server error; retrying in ${delay}s..."
            sleep "${delay}"
            ;;
         404)
            echo "Error: model '${MODEL}' not found at the LiftWing endpoint (HTTP 404)." >&2
            echo "       Known public models: llm-qwen3-14b, llm-qwen36-27b" >&2
            exit "${EXIT_API}"
            ;;
         401 | 403)
            echo "Error: authentication failed (HTTP ${http_code})." >&2
            [[ -s "${body_file}" ]] && head -c 500 "${body_file}" >&2 && echo >&2
            if [[ "${VIA}" == "tfproxy" ]]; then
               echo "       In proxy mode a 403 is the PROXY rejecting the shared secret," >&2
               echo "       not LiftWing. Check ${TFPROXY_PASSWORD_BASENAME} against the value" >&2
               echo "       that the proxy expects." >&2
            else
               echo "       The token must be an OAuth 2.0 access token (JWT). Use --anon to query without one." >&2
            fi
            exit "${EXIT_API}"
            ;;
         *)
            echo "Error: unexpected HTTP ${http_code}." >&2
            [[ -s "${body_file}" ]] && head -c 500 "${body_file}" >&2 && echo >&2
            exit "${EXIT_API}"
            ;;
      esac
   done
}

#
# Echoes the value of a response header (case-insensitive) from a header dump.
#
get_header() {
   local file="$1" name="$2"
   [[ -f "${file}" ]] || return 0
   grep -i "^${name}:" "${file}" | tail -n1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'
}

#
# Extracts the assistant text from the raw JSON, stripping <think> blocks.
#
process_response() {
   local raw_json="$1"

   printf '%s' "${raw_json}" | LWQ_VERBOSE="${VERBOSE}" python3 -c '
import json, os, re, sys

verbose = os.environ.get("LWQ_VERBOSE") == "true"

def warn(msg):
    print("Info: " + msg, file=sys.stderr)

raw = sys.stdin.read()
if not raw.strip():
    print("Error: empty response from API.", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("Error: failed to decode JSON from API response.", file=sys.stderr)
    print("--- Raw Response Start ---", file=sys.stderr)
    print(raw[:2000], file=sys.stderr)
    print("--- Raw Response End ---", file=sys.stderr)
    sys.exit(1)

# OpenAI-style error, and the api.wikimedia.org gateway shape.
if isinstance(data, dict) and "error" in data:
    err = data["error"]
    msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
    print("Error: API returned an error: " + msg, file=sys.stderr)
    sys.exit(1)
if isinstance(data, dict) and "httpCode" in data and "choices" not in data:
    print("Error: gateway returned %s: %s"
          % (data.get("httpCode"), data.get("httpReason", "")), file=sys.stderr)
    sys.exit(1)

choices = data.get("choices") or []
if not choices:
    print("Error: no choices in response.", file=sys.stderr)
    sys.exit(1)

choice = choices[0]
message = choice.get("message") or {}
content = message.get("content") or ""

# Reasoning models may return a separate field; it stays in --output-raw only.
if message.get("reasoning") and verbose:
    warn("response carried a separate reasoning field (kept in raw output only)")

# Strip <think>...</think> reasoning blocks. Qwen3 on LiftWing currently has
# thinking disabled, but the docs warn it can appear, so handle it defensively:
# closed pairs, a trailing unclosed block (truncated output), and a stray
# leading close tag with no opener.
before = content
content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL)
content = re.sub(r"<think>.*\Z", "", content, flags=re.DOTALL)
if "</think>" in content:
    content = content.split("</think>")[-1]
if content != before and verbose:
    warn("stripped <think> reasoning block(s) from the response")

content = content.strip()

if choice.get("finish_reason") == "length" and verbose:
    warn("output truncated (finish_reason=length); raise --max-tokens")

usage = data.get("usage") or {}
if usage and verbose:
    warn("tokens: prompt=%s completion=%s total=%s"
         % (usage.get("prompt_tokens"), usage.get("completion_tokens"),
            usage.get("total_tokens")))

if not content:
    if "<think>" in before:
        print("Error: response was entirely an unterminated <think> block -- the answer "
              "was cut off mid-reasoning. Raise --max-tokens.", file=sys.stderr)
    else:
        print("Error: response contained no text content.", file=sys.stderr)
    sys.exit(1)

print(content)
'
}

# --- Main Execution ---

#
# Main function to orchestrate the script's execution.
#
main() {
   QUERY_STRING=""
   QUERY_FILE=""
   SYSTEM_STRING=""
   SYSTEM_FILE=""
   MODEL="${DEFAULT_MODEL}"
   MAX_TOKENS="${DEFAULT_MAX_TOKENS}"
   TEMPERATURE=""
   TOP_P=""
   OUTPUT_FILE=""
   OUTPUT_PAYLOAD_FILE=""
   OUTPUT_RAW_FILE=""
   JSON_OUTPUT="false"
   TOKEN_FILE=""
   TOKEN=""
   RAW_OUTPUT=""
   ANON="false"
   VIA="direct"
   TFPROXY_URL=""
   TFPROXY_AUTH_HEADER=""
   TFPROXY_SECRET=""
   USER_AGENT="${DEFAULT_USER_AGENT}"
   MAX_RETRIES="${DEFAULT_MAX_RETRIES}"
   TIMEOUT="${DEFAULT_TIMEOUT}"
   VERBOSE="false"
   TMP_DIR=""

   parse_arguments "$@"
   validate_input

   if [[ "${VIA}" == "tfproxy" ]]; then
      load_tfproxy_config
   fi

   TMP_DIR=$(mktemp -d -t liftwing-query.XXXXXX) || {
      echo "Error: could not create temporary directory." >&2
      exit "${EXIT_USAGE}"
   }
   trap cleanup EXIT

   get_token

   local prompt="" system_prompt=""
   read_text_input prompt "${QUERY_STRING}" "${QUERY_FILE}" "query"
   read_text_input system_prompt "${SYSTEM_STRING}" "${SYSTEM_FILE}" "system prompt"

   local payload
   payload=$(generate_payload "${prompt}" "${system_prompt}")

   if [[ -n "${OUTPUT_PAYLOAD_FILE}" ]]; then
      printf '%s\n' "${payload}" >"${OUTPUT_PAYLOAD_FILE}"
      log_info "Payload saved to ${OUTPUT_PAYLOAD_FILE}"
   fi

   make_api_request "${payload}"

   if [[ -n "${OUTPUT_RAW_FILE}" ]]; then
      printf '%s\n' "${RAW_OUTPUT}" >"${OUTPUT_RAW_FILE}"
      log_info "Raw response saved to ${OUTPUT_RAW_FILE}"
   fi

   local final_text
   if [[ "${JSON_OUTPUT}" == "true" ]]; then
      final_text="${RAW_OUTPUT}"
   else
      final_text=$(process_response "${RAW_OUTPUT}") || {
         echo "Error: failed to extract text from the response." >&2
         [[ -n "${OUTPUT_RAW_FILE}" ]] && echo "Check ${OUTPUT_RAW_FILE} for details." >&2
         exit "${EXIT_API}"
      }
   fi

   if [[ -n "${OUTPUT_FILE}" ]]; then
      printf '%s\n' "${final_text}" >"${OUTPUT_FILE}"
      log_info "Final output saved to ${OUTPUT_FILE}"
   else
      printf '%s\n' "${final_text}"
   fi
}

main "$@"
