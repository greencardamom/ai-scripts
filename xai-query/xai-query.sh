#!/usr/bin/bash

#
# Script: xai-query.sh
# Purpose: CLI utility to query xAI Grok models (OpenAI-compatible API)
# Repo: n/a
# Created: August 2026
# Author: GreenC
# Formatting: shfmt -i 3 -ci xai-query.sh
#
# Docs: https://docs.x.ai/docs/models
#       https://docs.x.ai/docs/guides/reasoning
#
# Like liftwing-query (and unlike gemini-query), xAI speaks the OpenAI Chat
# Completions dialect: messages[] in, choices[0].message.content out, usage{} for
# tokens. Unlike LiftWing, xAI is METERED, so this script also reports cost.
#
# PRICING IS TIERED AT 200k PROMPT TOKENS -- crossing it DOUBLES both the input and
# the output rate for the whole request. A 210k-token prompt costs more than twice a
# 190k one. Bulk callers should know where their prompt sizes sit relative to 200k.
#
#   model                          ctx    in $/M (<200k / >=200k)  out $/M (<200k / >=200k)
#   grok-4.20-0309-non-reasoning    1M       1.25 / 2.50              2.50 /  5.00   <- default
#   grok-4.20-0309-reasoning        1M       1.25 / 2.50              2.50 /  5.00
#   grok-4.20-multi-agent-0309      1M       1.25 / 2.50              2.50 /  5.00
#   grok-4.3                        1M       1.25 / 2.50              2.50 /  5.00
#   grok-4.6                      500k       2.00 / 4.00              6.00 / 12.00
#   grok-4.5                      500k       2.00 / 4.00              6.00 / 12.00
#   grok-build-0.1                256k       1.00 / 2.00              2.00 /  4.00
#
# REASONING TOKENS: on grok-4.6 / grok-4.5 / grok-4.20-multi-agent, "Reasoning cannot
# be disabled" (per xAI docs) -- reasoning tokens are billed into your total and are
# reported separately from completion_tokens, so naive accounting UNDERSTATES cost.
# This script always folds reasoning_tokens into the billed output and warns when a
# model emits them unexpectedly. --reasoning-effort (low|medium|high|xhigh) is sent
# only when set; it is accepted by the reasoning models, not by the non-reasoning one.
#
# The default is deliberately the NON-reasoning model: cheapest tier, 1M context, and
# no hidden reasoning tokens to account for.
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
SCRIPT_NAME="xai-query.sh"
# Environment variable consulted when --key-file is not given
TOKEN_ENV_VAR="XAI_API_KEY"
# Secret directories searched, in order. Same rationale as liftwing-query: hosts keep
# secrets in different places, so searching a list keeps ONE script identical everywhere.
SECRET_SEARCH_DIRS=(
   "${HOME}/scripts/secrets"
   "${HOME}/.config/wikiget/secrets"
   "${HOME}/toolforge/scripts/secrets"
)
# Basename looked up inside SECRET_SEARCH_DIRS
TOKEN_BASENAME="xaiapi.key"
API_URL="https://api.x.ai/v1/chat/completions"
# Deferred mode: submit, then poll for the result. Avoids holding a connection open for the
# many minutes a large prompt takes, which is what makes --max-time fire (and, because an
# abandoned request may still be billed with no usage block returned, cost money invisibly).
DEFERRED_URL="https://api.x.ai/v1/chat/deferred-completion"
DEFAULT_DEFERRED_INTERVAL=10
DEFAULT_DEFERRED_MAX_WAIT=1800
# Default model: non-reasoning, 1M context, cheapest tier. See the header note.
DEFAULT_MODEL="grok-4.20-0309-non-reasoning"
DEFAULT_MAX_TOKENS=65536
DEFAULT_USER_AGENT="xai-query/1.0 (https://en.wikipedia.org/wiki/User:GreenC)"
DEFAULT_MAX_RETRIES=4
RETRY_BASE_DELAY=2 # seconds; exponential backoff (2,4,8,16...)
DEFAULT_TIMEOUT=500
# Prompt-token threshold at which xAI's higher price tier begins
TIER_THRESHOLD=200000

# Exit codes: 0 ok | 1 usage/local error | 2 API error | 3 rate limited (429)
EXIT_USAGE=1
EXIT_API=2
EXIT_RATELIMIT=3

# --- Function Definitions ---

#
# Echoes "<in_lo> <out_lo> <in_hi> <out_hi> <context>" for a model, or "" if unknown.
# _lo applies below TIER_THRESHOLD prompt tokens, _hi at or above it. Prices are $/1M.
# Keep in sync with https://docs.x.ai/docs/models
#
model_pricing() {
   case "$1" in
      grok-4.20-0309-non-reasoning | grok-4.20-0309-reasoning | grok-4.20-multi-agent-0309 | grok-4.3)
         echo "1.25 2.50 2.50 5.00 1000000"
         ;;
      grok-4.6 | grok-4.5)
         echo "2.00 6.00 4.00 12.00 500000"
         ;;
      grok-build-0.1)
         echo "1.00 2.00 2.00 4.00 256000"
         ;;
      *)
         echo ""
         ;;
   esac
}

#
# Displays the help message for the script.
#
show_help() {
   echo "Usage: ${SCRIPT_NAME} [options]"
   echo ""
   echo "Sends a query to the xAI Grok API and prints the response."
   echo ""
   echo "Query input (one of --query or --file is required):"
   echo "  -q, --query <string>      A string containing the query to send."
   echo "  -f, --file <path>         Path to a file containing the query."
   echo "      --system <text>       Optional system prompt."
   echo "      --system-file <path>  Read the system prompt from a file."
   echo ""
   echo "Model / generation:"
   echo "  -m, --model <name>        Model to use. Defaults to '${DEFAULT_MODEL}'."
   echo "      --max-tokens <n>      Max output tokens (Default: ${DEFAULT_MAX_TOKENS})."
   echo "      --temperature <0..2>  Sampling temperature (omitted if unset)."
   echo "      --top-p <0..1>        Nucleus sampling (omitted if unset)."
   echo "      --json                Ask for a JSON object response (response_format)."
   echo "      --reasoning-effort <low|medium|high|xhigh>"
   echo "                            Only for reasoning models; omitted if unset."
   echo ""
   echo "Known models (context; input \$/M below/at-or-above 200k; output \$/M):"
   echo "  grok-4.20-0309-non-reasoning   1M    1.25 / 2.50   2.50 /  5.00   [default]"
   echo "  grok-4.20-0309-reasoning       1M    1.25 / 2.50   2.50 /  5.00"
   echo "  grok-4.20-multi-agent-0309     1M    1.25 / 2.50   2.50 /  5.00"
   echo "  grok-4.3                       1M    1.25 / 2.50   2.50 /  5.00"
   echo "  grok-4.6                     500k    2.00 / 4.00   6.00 / 12.00   reasoning always on"
   echo "  grok-4.5                     500k    2.00 / 4.00   6.00 / 12.00   reasoning always on"
   echo "  grok-build-0.1               256k    1.00 / 2.00   2.00 /  4.00"
   echo ""
   echo "  Pricing is TIERED at ${TIER_THRESHOLD} prompt tokens: crossing it DOUBLES the rate"
   echo "  for the whole request, input and output alike."
   echo "  On grok-4.6/4.5/multi-agent, reasoning CANNOT be disabled; those reasoning"
   echo "  tokens bill as output. This script always counts them and warns when present."
   echo ""
   echo "Output:"
   echo "  -o,  --output-file <path>    Save the extracted text (else stdout)."
   echo "  -op, --output-payload <path> Save the JSON payload sent to the API."
   echo "  -or, --output-raw <path>     Save the raw JSON response from the API."
   echo "       --usage-file <path>     Save normalized token/cost JSON (for daily reports)."
   echo "       --json-output           Print the raw API JSON instead of extracted text."
   echo ""
   echo "Deferred mode (recommended for large prompts):"
   echo "      --deferred            Submit the request, then poll for the result instead of"
   echo "                            holding one long connection. Large prompts can take many"
   echo "                            minutes; a --timeout abort may still be billed and returns"
   echo "                            no usage block, so the charge is invisible. Deferred avoids"
   echo "                            that entirely. The result carries the full usage block."
   echo "      --deferred-interval <s>  Seconds between polls (Default: ${DEFAULT_DEFERRED_INTERVAL})."
   echo "      --deferred-max-wait <s>  Give up after this long (Default: ${DEFAULT_DEFERRED_MAX_WAIT})."
   echo "                            NOTE: a deferred result is retained 24h and can be fetched"
   echo "                            EXACTLY ONCE. Use -or to persist it; a result lost after"
   echo "                            retrieval is paid for and unrecoverable."
   echo ""
   echo "Connection / auth:"
   echo "  -k, --key-file <path>     File containing the xAI API key."
   echo "                            Overrides \$${TOKEN_ENV_VAR}."
   echo "      --user-agent <str>    Override the User-Agent header."
   echo "      --max-retries <n>     Retries on 429/5xx (Default: ${DEFAULT_MAX_RETRIES})."
   echo "      --timeout <seconds>   Per-request timeout (Default: ${DEFAULT_TIMEOUT})."
   echo "  -v, --verbose             Verbose logging ('Info:' messages to stderr)."
   echo "  -h, --help                Show this help message."
   echo ""
   echo "Key resolution order:"
   echo "  1) --key-file <path>  2) \$${TOKEN_ENV_VAR}  3) ${TOKEN_BASENAME} in a secret dir"
   echo ""
   echo "Secret directories searched, in order (first match wins):"
   printf '  %s\n' "${SECRET_SEARCH_DIRS[@]}"
   echo ""
   echo "Exit codes:"
   echo "  0 success | 1 usage/local error | 2 API error | 3 rate limited (429)"
   echo ""
   echo "Examples:"
   echo "  ${SCRIPT_NAME} -q \"What is the capital of Maryland?\""
   echo "  ${SCRIPT_NAME} -f prompt.txt --json -or raw.json --usage-file cost.json -v"
   echo "  ${SCRIPT_NAME} -f big.txt -m grok-4.3 --max-tokens 8192 -o out.txt"
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
         --json)
            JSON_MODE="true"
            shift 1
            ;;
         --reasoning-effort)
            REASONING_EFFORT="$2"
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
         --usage-file)
            USAGE_FILE="$2"
            shift 2
            ;;
         --json-output)
            JSON_OUTPUT="true"
            shift 1
            ;;
         --deferred)
            DEFERRED="true"
            shift 1
            ;;
         --deferred-interval)
            DEFERRED_INTERVAL="$2"
            shift 2
            ;;
         --deferred-max-wait)
            DEFERRED_MAX_WAIT="$2"
            shift 2
            ;;
         -k | --key-file)
            TOKEN_FILE="$2"
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
            show_help
            exit "${EXIT_USAGE}"
            ;;
      esac
   done
}

#
# Validates mutually-required / mutually-exclusive options.
#
validate_input() {
   if [[ -z "${QUERY_STRING}" && -z "${QUERY_FILE}" ]]; then
      echo "Error: you must provide either --query or --file." >&2
      show_help
      exit "${EXIT_USAGE}"
   fi
   if [[ -n "${QUERY_STRING}" && -n "${QUERY_FILE}" ]]; then
      echo "Error: --query and --file are mutually exclusive." >&2
      exit "${EXIT_USAGE}"
   fi
   if [[ -n "${SYSTEM_STRING}" && -n "${SYSTEM_FILE}" ]]; then
      echo "Error: --system and --system-file are mutually exclusive." >&2
      exit "${EXIT_USAGE}"
   fi
   if ! [[ "${MAX_TOKENS}" =~ ^[0-9]+$ ]]; then
      echo "Error: --max-tokens requires a positive integer." >&2
      exit "${EXIT_USAGE}"
   fi
   if [[ -n "${REASONING_EFFORT}" ]]; then
      case "${REASONING_EFFORT}" in
         low | medium | high | xhigh) ;;
         *)
            echo "Error: --reasoning-effort must be low, medium, high, or xhigh." >&2
            exit "${EXIT_USAGE}"
            ;;
      esac
      if [[ "${MODEL}" == *non-reasoning* ]]; then
         echo "Warning: --reasoning-effort has no effect on a non-reasoning model." >&2
      fi
   fi
   # Unknown models still run (xAI ships new ids faster than this table is updated),
   # but cost cannot be computed for them, so say so once rather than report $0.00.
   if [[ -z "$(model_pricing "${MODEL}")" ]]; then
      echo "Warning: no pricing table entry for model '${MODEL}'; cost will be reported as null." >&2
      echo "         Check https://docs.x.ai/docs/models and update model_pricing()." >&2
   fi
}

#
# Resolves the API key into the global TOKEN. Unlike LiftWing there is no
# anonymous tier -- xAI requires a key, so a miss here is fatal.
#
get_token() {
   local token=""

   if [[ -n "${TOKEN_FILE}" ]]; then
      if [[ ! -f "${TOKEN_FILE}" ]]; then
         echo "Error: key file '${TOKEN_FILE}' not found." >&2
         exit "${EXIT_USAGE}"
      fi
      token=$(read_secret "${TOKEN_FILE}")
      log_info "Using key from file: ${TOKEN_FILE}"
   elif [[ -n "${!TOKEN_ENV_VAR}" ]]; then
      token="${!TOKEN_ENV_VAR}"
      token="${token//[[:space:]]/}"
      log_info "Using key from \$${TOKEN_ENV_VAR}."
   else
      local found
      found=$(find_secret "${TOKEN_BASENAME}")
      if [[ -n "${found}" ]]; then
         token=$(read_secret "${found}")
         log_info "Using key from default keyfile: ${found}"
      fi
   fi

   if [[ -z "${token}" ]]; then
      echo "Error: no xAI API key found." >&2
      echo "       Supply -k <path>, set \$${TOKEN_ENV_VAR}, or place ${TOKEN_BASENAME} in:" >&2
      printf '         %s\n' "${SECRET_SEARCH_DIRS[@]}" >&2
      exit "${EXIT_USAGE}"
   fi

   TOKEN="${token}"
}

#
# Reads prompt text from a file or uses the direct string, into the variable
# named by $1.
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
   # Prompt goes via FILE, not the environment: Linux caps a single env var at
   # MAX_ARG_STRLEN (131072 bytes), so anything over ~50k tokens of OCR silently
   # fails with "Argument list too long" and posts an empty body.
   local pfile="${TMP_DIR}/prompt.in" sfile="${TMP_DIR}/system.in"
   printf '%s' "$1" >"${pfile}"
   printf '%s' "$2" >"${sfile}"
   XQ_PROMPT_FILE="${pfile}" \
      XQ_SYSTEM_FILE="${sfile}" \
      XQ_MODEL="${MODEL}" \
      XQ_MAX_TOKENS="${MAX_TOKENS}" \
      XQ_TEMPERATURE="${TEMPERATURE}" \
      XQ_TOP_P="${TOP_P}" \
      XQ_JSON_MODE="${JSON_MODE}" \
      XQ_REASONING="${REASONING_EFFORT}" \
      XQ_DEFERRED="${DEFERRED}" \
      python3 -c '
import json, os, sys

def _read(var):
    path = os.environ.get(var, "")
    if not path or not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        return fh.read()

messages = []
system = _read("XQ_SYSTEM_FILE")
if system:
    messages.append({"role": "system", "content": system})
messages.append({"role": "user", "content": _read("XQ_PROMPT_FILE")})

payload = {
    "model": os.environ["XQ_MODEL"],
    "messages": messages,
    "max_tokens": int(os.environ["XQ_MAX_TOKENS"]),
}
temperature = os.environ.get("XQ_TEMPERATURE", "")
if temperature:
    payload["temperature"] = float(temperature)
top_p = os.environ.get("XQ_TOP_P", "")
if top_p:
    payload["top_p"] = float(top_p)
if os.environ.get("XQ_JSON_MODE") == "true":
    payload["response_format"] = {"type": "json_object"}
# Only send reasoning_effort when asked: the non-reasoning model rejects unknown
# knobs, and omitting it leaves each model on its own documented default.
reasoning = os.environ.get("XQ_REASONING", "")
if reasoning:
    payload["reasoning_effort"] = reasoning
if os.environ.get("XQ_DEFERRED") == "true":
    payload["deferred"] = True

json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
'
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
# Deferred mode. Submit once, then poll. Each HTTP call is short, so no long-held connection
# can time out mid-generation. Sets the global RAW_OUTPUT.
#
# The result is retained 24h and retrievable EXACTLY ONCE, so the body is written to
# OUTPUT_RAW_FILE the moment it arrives -- before any parsing that could fail. A result lost
# after retrieval has been paid for and cannot be fetched again.
#
run_deferred() {
   local payload="$1"
   local body_file="${TMP_DIR}/body.json"
   local req_id waited=0 http_code

   http_code=$(printf '%s' "${payload}" | curl -sS -X POST "${API_URL}" \
      -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
      -H "User-Agent: ${USER_AGENT}" -o "${body_file}" -w '%{http_code}' \
      --max-time 120 -d @- 2>"${TMP_DIR}/curl.err")

   if [[ "${http_code}" != 2* ]]; then
      echo "Error: deferred submit failed (HTTP ${http_code})." >&2
      [[ -s "${body_file}" ]] && head -c 500 "${body_file}" >&2 && echo >&2
      exit "${EXIT_API}"
   fi

   req_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("request_id",""))' \
      "${body_file}" 2>/dev/null)
   if [[ -z "${req_id}" ]]; then
      echo "Error: deferred submit returned no request_id." >&2
      [[ -s "${body_file}" ]] && head -c 500 "${body_file}" >&2 && echo >&2
      exit "${EXIT_API}"
   fi
   log_info "Deferred request_id: ${req_id} (polling every ${DEFERRED_INTERVAL}s, max ${DEFERRED_MAX_WAIT}s)"

   while :; do
      sleep "${DEFERRED_INTERVAL}"
      waited=$((waited + DEFERRED_INTERVAL))

      http_code=$(curl -sS -X GET "${DEFERRED_URL}/${req_id}" \
         -H "Authorization: Bearer ${TOKEN}" -H "User-Agent: ${USER_AGENT}" \
         -o "${body_file}" -w '%{http_code}' --max-time 120 2>"${TMP_DIR}/curl.err")

      case "${http_code}" in
         200)
            # Persist FIRST: this result can never be fetched again.
            if [[ -n "${OUTPUT_RAW_FILE}" ]]; then
               cp "${body_file}" "${OUTPUT_RAW_FILE}"
               log_info "Raw response saved to ${OUTPUT_RAW_FILE} (${waited}s)"
            else
               echo "Warning: deferred result retrieved without --output-raw; it cannot be" >&2
               echo "         fetched again. Use -or to persist what you paid for." >&2
            fi
            RAW_OUTPUT=$(<"${body_file}")
            log_info "Deferred result ready after ${waited}s"
            return 0
            ;;
         202)
            log_info "Still processing (${waited}s elapsed)..."
            ;;
         404)
            echo "Error: request_id ${req_id} not found (already retrieved, or expired)." >&2
            echo "       Deferred results are single-use and kept 24h." >&2
            exit "${EXIT_API}"
            ;;
         429)
            log_info "Rate limited while polling; backing off"
            sleep "$((DEFERRED_INTERVAL * 2))"
            waited=$((waited + DEFERRED_INTERVAL * 2))
            ;;
         *)
            log_info "Poll returned HTTP ${http_code}; continuing"
            ;;
      esac

      if ((waited >= DEFERRED_MAX_WAIT)); then
         echo "Error: deferred result not ready after ${waited}s." >&2
         echo "       The work is still queued and will be billed. Retrieve it within 24h with:" >&2
         echo "       curl -H \"Authorization: Bearer \$KEY\" ${DEFERRED_URL}/${req_id}" >&2
         exit "${EXIT_API}"
      fi
   done
}

#
# POSTs the payload, retrying on 429 and 5xx. Sets the global RAW_OUTPUT.
# Sets a global rather than echoing so the EXIT_* exits below terminate the
# script instead of just a command-substitution subshell.
#
make_api_request() {
   local payload="$1"

   if [[ "${DEFERRED}" == "true" ]]; then
      run_deferred "${payload}"
      return 0
   fi
   local attempt=0 http_code retry_after delay
   local body_file="${TMP_DIR}/body.json"
   local head_file="${TMP_DIR}/headers.txt"

   log_info "POST ${API_URL}"
   log_info "Model: ${MODEL}, max_tokens: ${MAX_TOKENS}"

   while :; do
      attempt=$((attempt + 1))

      local -a curl_args=(
         -sS -X POST "${API_URL}"
         -H "Content-Type: application/json"
         -H "Authorization: Bearer ${TOKEN}"
         -H "User-Agent: ${USER_AGENT}"
         -D "${head_file}" -o "${body_file}"
         -w '%{http_code}'
         --max-time "${TIMEOUT}"
         -d @-
      )

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

      log_info "Attempt ${attempt}: HTTP ${http_code}"

      case "${http_code}" in
         2*)
            RAW_OUTPUT=$(<"${body_file}")
            return 0
            ;;
         429)
            if ((attempt > MAX_RETRIES)); then
               echo "Error: rate limited (HTTP 429) after ${attempt} attempt(s)." >&2
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
               exit "${EXIT_API}"
            fi
            delay=$((RETRY_BASE_DELAY ** attempt))
            log_info "Server error; retrying in ${delay}s..."
            sleep "${delay}"
            ;;
         400)
            echo "Error: bad request (HTTP 400)." >&2
            [[ -s "${body_file}" ]] && head -c 500 "${body_file}" >&2 && echo >&2
            echo "       A prompt above the model's context window reports here." >&2
            echo "       ${MODEL} context: $(model_pricing "${MODEL}" | awk '{print $5}') tokens." >&2
            exit "${EXIT_API}"
            ;;
         401 | 403)
            echo "Error: authentication failed (HTTP ${http_code})." >&2
            [[ -s "${body_file}" ]] && head -c 500 "${body_file}" >&2 && echo >&2
            echo "       Check the API key (${TOKEN_BASENAME}) and that it is still active." >&2
            exit "${EXIT_API}"
            ;;
         404)
            echo "Error: model '${MODEL}' not found (HTTP 404)." >&2
            echo "       Check https://docs.x.ai/docs/models for current model ids." >&2
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
# Computes cost from the usage block and (optionally) writes normalized JSON to
# USAGE_FILE. Reasoning tokens are billed at the OUTPUT rate but are reported
# OUTSIDE completion_tokens by some providers, so they are added explicitly --
# this is the exact accounting bug that understated the Gemini bill ~8.7x.
#
emit_usage() {
   local raw_json="$1"
   local prices
   prices=$(model_pricing "${MODEL}")

   printf '%s' "${raw_json}" | XQ_PRICES="${prices}" XQ_MODEL="${MODEL}" \
      XQ_TIER="${TIER_THRESHOLD}" XQ_USAGE_FILE="${USAGE_FILE}" \
      XQ_VERBOSE="${VERBOSE}" python3 -c '
import json, os, sys

verbose = os.environ.get("XQ_VERBOSE") == "true"
def warn(msg): print("Info: " + msg, file=sys.stderr)

try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)                      # response already reported elsewhere

u = data.get("usage") or {}
if not u:
    sys.exit(0)

prompt_t = int(u.get("prompt_tokens") or 0)
completion_t = int(u.get("completion_tokens") or 0)
details = u.get("completion_tokens_details") or {}
reasoning_t = int(details.get("reasoning_tokens") or u.get("reasoning_tokens") or 0)
pdetails = u.get("prompt_tokens_details") or {}
cached_t = int(pdetails.get("cached_tokens") or 0)

# Providers differ on whether reasoning is already inside completion_tokens.
# total_tokens is the arbiter: if it exceeds prompt+completion, reasoning is extra.
total_t = int(u.get("total_tokens") or 0)
reasoning_extra = reasoning_t if (total_t and total_t > prompt_t + completion_t) else 0
billed_out = completion_t + reasoning_extra

tier_at = int(os.environ["XQ_TIER"])
high = prompt_t >= tier_at

# AUTHORITATIVE cost: xAI returns the exact amount charged for this request as
# cost_in_usd_ticks, where 1 USD = 1e10 ticks. Always prefer it. A locally derived
# figure cannot see cache discounts, promotional rates, or a stale price table --
# exactly how a Gemini cost model here ended up ~30x wrong for months.
ticks = u.get("cost_in_usd_ticks")
cost_provider = (int(ticks) / 1e10) if ticks is not None else None

# Table estimate is kept only as a cross-check so price-table drift gets noticed.
cost_table = None
prices = os.environ.get("XQ_PRICES", "").split()
if len(prices) == 5:
    in_lo, out_lo, in_hi, out_hi = (float(x) for x in prices[:4])
    rin, rout = (in_hi, out_hi) if high else (in_lo, out_lo)
    cost_table = prompt_t * rin / 1e6 + billed_out * rout / 1e6

cost = cost_provider if cost_provider is not None else cost_table

rec = {
    "model": os.environ["XQ_MODEL"],
    "prompt_tokens": prompt_t,
    "cached_tokens": cached_t,
    "completion_tokens": completion_t,
    "reasoning_tokens": reasoning_t,
    "billed_output_tokens": billed_out,
    "total_tokens": total_t,
    "tier": "high" if high else "low",
    "tier_threshold": tier_at,
    "cost_usd": cost,
    "cost_source": "provider" if cost_provider is not None else "table",
    "cost_in_usd_ticks": int(ticks) if ticks is not None else None,
    "cost_usd_table_estimate": cost_table,
}

if reasoning_t and verbose:
    warn("model emitted %d reasoning tokens%s -- these bill at the OUTPUT rate"
         % (reasoning_t, " (counted on top of completion_tokens)" if reasoning_extra
            else " (already inside completion_tokens)"))
if verbose:
    warn("tokens: prompt=%d (cached=%d) completion=%d reasoning=%d billed_out=%d tier=%s"
         % (prompt_t, cached_t, completion_t, reasoning_t, billed_out, rec["tier"]))
    warn("cost: %s [%s]" % ("$%.8f" % cost if cost is not None else "unknown", rec["cost_source"]))
    # Flag drift so a stale table is caught early rather than trusted silently.
    if cost_provider is not None and cost_table:
        ratio = cost_table / cost_provider if cost_provider else 0
        if ratio and (ratio > 1.25 or ratio < 0.8):
            warn("price-table estimate $%.8f is %.2fx the amount actually charged -- "
                 "table is stale or misses a discount (cached_tokens=%d)"
                 % (cost_table, ratio, cached_t))
    if cost_provider is None:
        warn("no cost_in_usd_ticks in response; fell back to the local price table")
    if high:
        warn("prompt crossed the %d-token tier -- rates are DOUBLE for this request" % tier_at)

path = os.environ.get("XQ_USAGE_FILE", "")
if path:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
        f.write("\n")
'
}

#
# Extracts the assistant text from the raw JSON, stripping <think> blocks.
#
process_response() {
   local raw_json="$1"

   printf '%s' "${raw_json}" | XQ_VERBOSE="${VERBOSE}" python3 -c '
import json, os, re, sys

verbose = os.environ.get("XQ_VERBOSE") == "true"
def warn(msg): print("Info: " + msg, file=sys.stderr)

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

if isinstance(data, dict) and "error" in data:
    err = data["error"]
    msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
    print("Error: API returned an error: " + msg, file=sys.stderr)
    sys.exit(1)

choices = data.get("choices") or []
if not choices:
    print("Error: no choices in response.", file=sys.stderr)
    sys.exit(1)

choice = choices[0]
message = choice.get("message") or {}
content = message.get("content") or ""

# Reasoning models may return the chain separately; it stays in --output-raw only.
if message.get("reasoning_content") and verbose:
    warn("response carried a separate reasoning_content field (kept in raw output only)")

# Strip <think>...</think> blocks defensively: closed pairs, a trailing unclosed
# block (truncated output), and a stray leading close tag with no opener.
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
   JSON_MODE="false"
   REASONING_EFFORT=""
   OUTPUT_FILE=""
   OUTPUT_PAYLOAD_FILE=""
   OUTPUT_RAW_FILE=""
   USAGE_FILE=""
   JSON_OUTPUT="false"
   DEFERRED="false"
   DEFERRED_INTERVAL="${DEFAULT_DEFERRED_INTERVAL}"
   DEFERRED_MAX_WAIT="${DEFAULT_DEFERRED_MAX_WAIT}"
   TOKEN_FILE=""
   TOKEN=""
   RAW_OUTPUT=""
   USER_AGENT="${DEFAULT_USER_AGENT}"
   MAX_RETRIES="${DEFAULT_MAX_RETRIES}"
   TIMEOUT="${DEFAULT_TIMEOUT}"
   VERBOSE="false"
   TMP_DIR=""

   parse_arguments "$@"
   validate_input

   TMP_DIR=$(mktemp -d -t xai-query.XXXXXX) || {
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

   # Usage/cost before text extraction, so a malformed body still reports what it cost.
   emit_usage "${RAW_OUTPUT}"

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
