#!/usr/bin/bash

#
# Script: gemini-query.sh
# Purpose: CLI utility to query Gemini (Supports Context Caching & Session Memory)
# Repo: n/a
# Created: July 2025
# Modified: April 2026
# Author: GreenC + Google Gemini
# Formatting: shfmt -i 3 -ci gemini-query.sh
#

# The MIT License (MIT)
#
# Copyright (c) 2025 by User:GreenC (at en.wikipedia.org)
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
SCRIPT_NAME="gemini-query.sh"
# The name of the environment variable for the API key
API_KEY_ENV_VAR="GEMINI_API_KEY"
# The default model to use if not specified via the --model flag
DEFAULT_MODEL="gemini-2.5-pro"
SESSION_DIR="${HOME}/.gemini_sessions"
DEFAULT_SESSION="default"
# generationConfig default. Global so usage() can quote it; main() seeds TEMPERATURE from it.
TEMPERATURE_DEFAULT="0.5"
# Secret directories searched, in order, when --key-file is not given and the env var is
# unset. Hosts keep secrets in different places; searching a list keeps ONE script
# identical everywhere instead of a per-host fork.
SECRET_SEARCH_DIRS=(
   "${HOME}/scripts/secrets"
   "${HOME}/.config/wikiget/secrets"
   "${HOME}/toolforge/scripts/secrets"
)
# Basenames looked up inside SECRET_SEARCH_DIRS. Two spellings are in use across the
# fleet for the same key (verified byte-identical), so both are searched rather than
# renaming files on five hosts.
KEY_BASENAMES=(
   "googlegemini.apikey"
   "googlegemini.key"
)

# --- Function Definitions ---

#
# Displays the help message for the script.
#
show_help() {
  echo "Usage: $(basename "${SCRIPT_NAME}") [options]"
  echo ""
  echo "Sends a query to the Google Gemini API and prints the response."
  echo ""
  echo "Options:"
  echo "  -q, --query <string>      A string containing the query to send."
  echo "  -f, --file <path>         Path to a file containing the query."
  echo "  -s, --session <name>      Name of the conversation memory session (defaults to '${DEFAULT_SESSION}')."
  echo "  --clear                   Clear the history for the specified session. Exits if no"
  echo "                            query follows; otherwise clears, then runs the query."
  echo "  -c, --cache <name>        Name of the Context Cache to query (e.g. cachedContents/xxxx)."
  echo "  -g, --ground              Enable Google Search grounding for the query."
  echo "  -t, --temperature <n>     Sampling temperature. Defaults to ${TEMPERATURE_DEFAULT}."
  echo "  --json-output             Ask the model for application/json (sets responseMimeType)."
  echo "  --response-mime-type <s>  Set responseMimeType explicitly. Unset leaves it off."
  echo "  -o, --output-file <path>  Optional path to save the final text output."
  echo "  -k, --key-file <path>     Path to a file containing your Google AI API key."
  echo "                            (Overrides the ${API_KEY_ENV_VAR} environment variable if both are set)."
  echo "  -m, --model <name>        The model to use. Defaults to '${DEFAULT_MODEL}'."
  echo "  -op, --output-payload <path> Optional path to save the JSON payload sent to the API."
  echo "  -or, --output-raw <path>  Optional path to save the raw JSON response from the API."
  echo "  -v, --verbose             Enable verbose logging (outputs 'Info:' messages to stderr)."
  echo "  -tb, --thinking-budget <n> Cap reasoning tokens. 0 disables thinking, -1 is dynamic."
  echo "                            Unset leaves the model default. Thinking tokens bill at the"
  echo "                            OUTPUT rate, so an uncapped budget can dominate the invoice."
  echo "  -h, --help                Show this help message."
  echo ""
  echo "API Key:"
  echo "  The script will use the API key from the --key-file option if provided."
  echo "  Otherwise, it will look for the ${API_KEY_ENV_VAR} environment variable."
  echo "  You must provide the key via one of these two methods."
  echo ""
  echo "Examples:"
  echo "  # Standard Query"
  echo "    ${SCRIPT_NAME} -q \"What is the capital of Maryland?\" -k ./api.key"
  echo ""
  echo "  # Querying a Cache"
  echo "    Use gemini-files.sh to create a Context Cache (upload once), then query it repeatedly"
  echo "    ${SCRIPT_NAME} --cache cachedContents/abc12345 --query \"Find the connection between...\""
  echo "    ${SCRIPT_NAME} --cache cachedContents/abc12345 --query \"Find the location of...\""
  echo ""
  echo "Note: You must provide either --query or --file."
}

#
# Prints informational messages to stderr if VERBOSE is true.
#
log_info() {
  if [[ "${VERBOSE}" == "true" ]]; then
    echo "Info: $@" >&2
  fi
}

#
# Parses command-line arguments and sets global variables.
#
parse_arguments() {
  while [[ "$#" -gt 0 ]]; do
      case $1 in
          -q|--query)
              QUERY_STRING="$2"
              shift 2
              ;;
          -f|--file)
              QUERY_FILE="$2"
              shift 2
              ;;
          -s|--session)
              SESSION_NAME="$2"
              shift 2
              ;;
          --clear)
              CLEAR_SESSION="true"
              shift 1
              ;;
          -c|--cache)
              CACHE_NAME="$2"
              shift 2
              ;;
          -g|--ground)
              GROUND="true"
              shift 1
              ;;
          -t|--temperature)
              if ! [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                  echo "Error: --temperature requires a number (e.g. 0.2)." >&2
                  exit 1
              fi
              TEMPERATURE="$2"
              shift 2
              ;;
          --json-output)
              RESPONSE_MIME="application/json"
              shift 1
              ;;
          --response-mime-type)
              RESPONSE_MIME="$2"
              shift 2
              ;;
          -tb|--thinking-budget)
              # Validated here so it can be interpolated straight into the JSON payload.
              if ! [[ "$2" =~ ^-?[0-9]+$ ]]; then
                  echo "Error: --thinking-budget requires an integer (0 disables, -1 dynamic)." >&2
                  exit 1
              fi
              THINKING_BUDGET="$2"
              shift 2
              ;;
          -o|--output-file)
              OUTPUT_FILE="$2"
              shift 2
              ;;
          -k|--key-file)
              API_KEY_FILE="$2"
              shift 2
              ;;
          -m|--model)
              MODEL="$2"
              shift 2
              ;;
          -op|--output-payload)
              OUTPUT_PAYLOAD_FILE="$2"
              shift 2
              ;;
          -or|--output-raw)
              OUTPUT_RAW_FILE="$2"
              shift 2
              ;;
          -v|--verbose)
              VERBOSE="true"
              shift 1
              ;;
          -h|--help)
              show_help
              exit 0
              ;;
          *)
              echo "Error: Unknown parameter passed: $1" >&2
              show_help
              exit 1
              ;;
      esac
  done

  # Set default session if not provided
  if [[ -z "${SESSION_NAME}" ]]; then
      SESSION_NAME="${DEFAULT_SESSION}"
  fi
}

#
# Validates that all required inputs have been provided correctly.
#
validate_input() {
  # Check if either --query or --file is provided, but not both
  if [[ -n "${QUERY_STRING}" && -n "${QUERY_FILE}" ]]; then
      echo "Error: Please provide either --query or --file, not both." >&2
      show_help
      exit 1
  fi

  if [[ -z "${QUERY_STRING}" && -z "${QUERY_FILE}" ]]; then
      echo "Error: Missing input. Please provide either --query or --file." >&2
      show_help
      exit 1
  fi
}

#
# Retrieves the API key from the file or environment variable.
# Returns the API key.
#
#
# Echoes the path of the first KEY_BASENAMES file found in SECRET_SEARCH_DIRS, else "".
#
find_secret() {
  local dir base
  for dir in "${SECRET_SEARCH_DIRS[@]}"; do
      for base in "${KEY_BASENAMES[@]}"; do
          if [[ -f "${dir}/${base}" ]]; then
              echo "${dir}/${base}"
              return 0
          fi
      done
  done
  return 0
}

#
# Reads a secret file, stripping surrounding whitespace/newlines.
#
read_secret() {
  tr -d '[:space:]' <"$1"
}

get_api_key() {
  local key
  # Prioritize API key from file
  if [[ -n "${API_KEY_FILE}" ]]; then
      if [ ! -f "${API_KEY_FILE}" ]; then
          echo "Error: API key file ${API_KEY_FILE} not found." >&2
          exit 1
      fi
      key=$(cat "${API_KEY_FILE}" | tr -d '\n')
      log_info "Using API key from file: ${API_KEY_FILE}"
  # Fallback to environment variable using indirect expansion
  elif [[ -n "${!API_KEY_ENV_VAR}" ]]; then
      key="${!API_KEY_ENV_VAR}"
      log_info "Using API key from ${API_KEY_ENV_VAR} environment variable."
  else
      # Last resort: look for a known keyfile in the standard secret dirs.
      local found
      found=$(find_secret)
      if [[ -n "${found}" ]]; then
          key=$(read_secret "${found}")
          log_info "Using API key from default keyfile: ${found}"
      fi
  fi

  if [[ -z "${key}" ]]; then
      echo "Error: API key not found." >&2
      echo "Supply --key-file <path>, set ${API_KEY_ENV_VAR}, or place one of:" >&2
      printf '  %s\n' "${KEY_BASENAMES[@]}" >&2
      echo "in one of:" >&2
      printf '  %s\n' "${SECRET_SEARCH_DIRS[@]}" >&2
      exit 1
  fi
  # Set a global rather than echoing: the caller used to do api_key=$(get_api_key), and an
  # exit inside that command substitution only killed the subshell -- the script carried on
  # with an empty key and failed later at the API instead of here.
  API_KEY="${key}"
}

#
# Reads query from file or variable safely.
#
get_raw_query() {
  if [[ -n "${QUERY_FILE}" ]]; then
    if [ ! -f "${QUERY_FILE}" ]; then
      echo "Error: File '${QUERY_FILE}' not found." >&2
      exit 1
    fi
    cat "${QUERY_FILE}"
  else
    printf "%s" "${QUERY_STRING}"
  fi
}

#
# Generates the JSON payload using Python, managing the session history file.
#
generate_payload() {
  local session_file="$1"
  local raw_query
  raw_query=$(get_raw_query)

  local cache_field=""
  if [[ -n "${CACHE_NAME}" ]]; then
      log_info "Using Context Cache: ${CACHE_NAME}"
      cache_field="\"cachedContent\": \"${CACHE_NAME}\","
  fi

  # Google Search grounding. Kept from the pre-merge gemini-query.sh, where it injected
  # this same tools key into a bash heredoc; callers are annomain.awk -g, genmeta.py
  # --ground, clustermerge.py and monitor_gemini-api.awk.
  local tools_field=""
  if [[ "${GROUND}" == "true" ]]; then
      log_info "Enabling Google Search grounding"
      tools_field="\"tools\": [ { \"google_search\": {} } ],"
  fi

  printf "%s" "${raw_query}" | python3 -c '
import json, sys, os

session_file = sys.argv[1]
cache_string = sys.argv[2]
query = sys.stdin.read()

messages = []
if os.path.exists(session_file):
    try:
        with open(session_file, "r") as f:
            messages = json.load(f)
    except Exception as e:
        print(f"Warning: Failed to load previous session memory: {e}", file=sys.stderr)

if query.strip():
    messages.append({"role": "user", "parts": [{"text": query}]})
    try:
        with open(session_file, "w") as f:
            json.dump(messages, f)
    except Exception as e:
        print(f"Warning: Failed to write to session memory: {e}", file=sys.stderr)

# Optional reasoning cap. Thinking tokens bill at the OUTPUT rate but are reported
# separately (usageMetadata.thoughtsTokenCount), so an uncapped budget is easy to miss
# in token accounting. Empty -> omit thinkingConfig, leave the model default.
tb = sys.argv[3] if len(sys.argv) > 3 else ""
thinking = f"\"thinkingConfig\": {{ \"thinkingBudget\": {int(tb)} }}, " if tb.strip() else ""

# tools (grounding), temperature and responseMimeType are caller-controlled. The two
# pre-merge scripts disagreed on the last two - gemini-query.sh used 0.5 and no mime
# type, the pre-merge fork used 0.2 and forced application/json - so neither is
# hardcoded now: the defaults below match gemini-query.sh and a caller passes flags.
tools_string = sys.argv[4] if len(sys.argv) > 4 else ""
temperature  = sys.argv[5] if len(sys.argv) > 5 else "0.5"
mime         = sys.argv[6] if len(sys.argv) > 6 else ""
resp_mime = f"\"responseMimeType\": \"{mime}\", " if mime.strip() else ""

payload_str = f"{{ {cache_string}{tools_string} \"contents\": {json.dumps(messages)}, \"generationConfig\": {{ {thinking}{resp_mime}\"temperature\": {float(temperature)}, \"topP\": 0.95, \"topK\": 40, \"maxOutputTokens\": 65536 }} }}"
print(payload_str)
' "${session_file}" "${cache_field}" "${THINKING_BUDGET}" "${tools_field}" "${TEMPERATURE}" "${RESPONSE_MIME}"
}

#
# Executes the curl command to call the Gemini API.
#
make_api_request() {
  local api_key="$1"
  local model_name="$2"
  local payload_data="$3"
   
  log_info "Sending request to model: ${model_name}"
  # Perform the API request, sending payload data via stdin
  local output
  output=$(echo "${payload_data}" | curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/${model_name}:generateContent?key=${api_key}" \
    -H 'Content-Type: application/json' \
    -d @-
  )

  # Check for curl errors or empty output
  if [ $? -ne 0 ]; then
      echo "Error: curl command failed." >&2
      exit 1
  fi
  if [ -z "$output" ]; then
      echo "Error: Received empty response from API." >&2
      exit 1
  fi

  echo "${output}"
}

#
# Processes the raw JSON response and updates the session history.
#
process_response() {
  local raw_json="$1"
  local session_file="$2"
  
  local extracted_text
  extracted_text=$(python3 -c "
import json, sys, os

raw_text = sys.argv[1]
session_file = sys.argv[2]

try:
    if not raw_text:
        print('Error: Raw response is empty.', file=sys.stderr)
        sys.exit(1)
        
    data = json.loads(raw_text)
    
    if 'candidates' in data and data['candidates']:
        part = data['candidates'][0].get('content', {}).get('parts', [{}])[0]
        if 'text' in part:
            assistant_text = part['text']
            
            if os.path.exists(session_file):
                try:
                    with open(session_file, 'r') as f:
                        messages = json.load(f)
                    messages.append({'role': 'model', 'parts': [{'text': assistant_text}]})
                    with open(session_file, 'w') as f:
                        json.dump(messages, f)
                except Exception as e:
                    print(f'Warning: Could not save assistant response to memory: {e}', file=sys.stderr)
                    
            print(assistant_text)
        else:
            print('Error: Text part not found in response.', file=sys.stderr)
            sys.exit(1)
    elif 'error' in data:
        print(f\"Error: API returned an error: {data['error'].get('message', 'Unknown error')}\", file=sys.stderr)
        sys.exit(1)
    else:
        print('Error: Unexpected JSON structure in response.', file=sys.stderr)
        sys.exit(1)
        
except json.JSONDecodeError:
    print('Error: Failed to decode JSON from API response.', file=sys.stderr)
    print(f'--- Raw Response Start ---\n{raw_text}\n--- Raw Response End ---', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Error processing response: {e}', file=sys.stderr)
    sys.exit(1)
" "${raw_json}" "${session_file}")

  if [ $? -ne 0 ]; then
      echo "Error: Failed to extract text from the response." >&2
      if [[ -n "${OUTPUT_RAW_FILE}" ]]; then
        echo "Check ${OUTPUT_RAW_FILE} for details." >&2
      fi
      exit 1
  fi

  echo "$extracted_text"
}

# --- Main Execution ---

main() {
  # Initialize variables
  local QUERY_STRING=""
  local QUERY_FILE=""
  local CACHE_NAME=""
  local SESSION_NAME=""
  local CLEAR_SESSION="false"
  local GROUND="false"
  # generationConfig defaults match the pre-merge gemini-query.sh so its existing callers
  # (SSTS) are unaffected. a caller wants -t 0.2 --json-output to match what
  # the pre-merge fork hardcoded.
  local TEMPERATURE="${TEMPERATURE_DEFAULT}"
  local RESPONSE_MIME=""
  # Empty -> omit thinkingConfig, leave the model default. Do NOT default this to 0: some
  # models reject it outright ("Budget 0 is invalid. This model only works in thinking
  # mode."). Callers wanting thinking off pass -tb 0, as one caller does -- its
  # prompt says "DO NOT use any reasoning, scratchpad, or thought processes", the model
  # ignored that advisory instruction and billed ~19.6k thinking tokens/call at the OUTPUT
  # rate, and thinkingConfig enforces it for real. Set -tb -1 for dynamic.
  local THINKING_BUDGET=""
  local API_KEY_FILE=""
  local MODEL="${DEFAULT_MODEL}"
  local OUTPUT_PAYLOAD_FILE=""
  local OUTPUT_RAW_FILE=""
  local OUTPUT_FILE=""
  local VERBOSE="false"

  parse_arguments "$@"

  # Ensure session directory exists
  mkdir -p "${SESSION_DIR}"
  local session_file_path="${SESSION_DIR}/session_${SESSION_NAME}.json"

  # Handle memory clearing
  if [[ "${CLEAR_SESSION}" == "true" ]]; then
      if [ -f "${session_file_path}" ]; then
          rm "${session_file_path}"
          log_info "Cleared session memory: ${SESSION_NAME}"
      fi
      # If no query was provided along with --clear, just exit cleanly
      if [[ -z "${QUERY_STRING}" && -z "${QUERY_FILE}" ]]; then
          echo "Session '${SESSION_NAME}' has been cleared."
          exit 0
      fi
  fi

  validate_input
   
  local api_key
  get_api_key                 # sets API_KEY; exits here if no key can be resolved
  api_key="${API_KEY}"
   
  local payload
  payload=$(generate_payload "${session_file_path}")

  if [[ -n "${OUTPUT_PAYLOAD_FILE}" ]]; then
    echo "${payload}" > "${OUTPUT_PAYLOAD_FILE}"
    log_info "Payload saved to ${OUTPUT_PAYLOAD_FILE}"
  fi

  local raw_output
  raw_output=$(make_api_request "${api_key}" "${MODEL}" "${payload}")

  if [[ -n "${OUTPUT_RAW_FILE}" ]]; then
    echo "${raw_output}" > "${OUTPUT_RAW_FILE}"
    log_info "Raw response saved to ${OUTPUT_RAW_FILE}"
  fi

  local final_text
  final_text=$(process_response "${raw_output}" "${session_file_path}")

  if [ $? -eq 0 ]; then
    if [[ -n "${OUTPUT_FILE}" ]]; then
      echo "${final_text}" > "${OUTPUT_FILE}"
      log_info "Final output saved to ${OUTPUT_FILE}"
    else
      echo "${final_text}"
    fi
  fi
}

# Run the main function with all script arguments
main "$@"
