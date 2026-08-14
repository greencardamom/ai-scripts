#!/usr/bin/bash

#
# Script: gemini-query.sh
# Purpose: CLI utility to query Gemini
# Repo: n/a
# Created: July 2025
# Author: GreenC + Google Gemini Advanced 2.5 Pro
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
  echo "  -o, --output-file <path>  Optional path to save the final text output."
  echo "  -k, --key-file <path>     Path to a file containing your Google AI API key."
  echo "                            (Overrides the ${API_KEY_ENV_VAR} environment variable if both are set)."
  echo "  -m, --model <name>        The model to use. Defaults to '${DEFAULT_MODEL}'."
  echo "  -op, --output-payload <path> Optional path to save the JSON payload sent to the API."
  echo "  -or, --output-raw <path>  Optional path to save the raw JSON response from the API."
  echo "  -v, --verbose             Enable verbose logging (outputs 'Info:' messages to stderr)."
  echo "  -g, --ground              Enable Google Search grounding (live web search)."
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
  echo "  ${SCRIPT_NAME} -q \"What is the capital of Maryland?\" -k ./api.key -o result.txt"
  echo "  ${SCRIPT_NAME} -q \"Tell me a joke\" -k ./api.key -m gemini-2.0-flash-latest --output-raw /tmp/joke.raw.json -v"
  echo "  export ${API_KEY_ENV_VAR}='your_api_key_here'"
  echo "  ${SCRIPT_NAME} --file ./my_question.txt"
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
          -g|--ground)
              GROUND="true"
              shift 1
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
      echo "Error: API key not found." >&2
      echo "Please provide the API key via the --key-file option or by setting the ${API_KEY_ENV_VAR} environment variable." >&2
      echo "" >&2
      show_help
      exit 1
  fi
  echo "${key}"
}

#
# Prepares the query text by reading from a file or using the direct string.
# Returns the JSON-escaped query text.
#
prepare_query() {
  local prepared_query
  if [[ -n "${QUERY_FILE}" ]]; then
    if [ ! -f "${QUERY_FILE}" ]; then
      echo "Error: File '${QUERY_FILE}' not found." >&2
      exit 1
    fi
    log_info "Reading query from file: ${QUERY_FILE}"
    # Read and escape query from file
    prepared_query=$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' < "${QUERY_FILE}")

    if [ -z "${prepared_query}" ] || [ "${prepared_query}" == '""' ]; then
      echo "Error: File '${QUERY_FILE}' is empty or contains only whitespace." >&2
      exit 1
    fi
  else # Input is a direct query string
    log_info "Input treated as direct query."
    prepared_query=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "${QUERY_STRING}")
  fi
  echo "${prepared_query}"
}

#
# Generates the JSON payload.
#
generate_payload() {
  local query_text="$1"
  # Optional Google Search grounding (live web search) when -g/--ground is set.
  # Empty when off -> just whitespace in the JSON (valid).
  local tools_json=""
  if [[ "${GROUND}" == "true" ]]; then
    tools_json='  "tools": [ { "google_search": {} } ],'
  fi
  # Optional reasoning cap when -tb/--thinking-budget is set. Thinking tokens are billed at
  # the OUTPUT rate but are reported separately (usageMetadata.thoughtsTokenCount), so an
  # uncapped budget is easy to miss in token accounting. Empty when off -> blank line, valid JSON.
  local thinking_json=""
  if [[ -n "${THINKING_BUDGET}" ]]; then
    thinking_json="    \"thinkingConfig\": { \"thinkingBudget\": ${THINKING_BUDGET} },"
  fi
  # Prepare the JSON payload for the API request using a heredoc
  cat <<EOF
{
  "contents": [
    {
      "parts": [
        { "text": ${query_text} }
      ]
    }
  ],
${tools_json}
  "generationConfig": {
${thinking_json}
    "temperature": 0.5,
    "topP": 0.95,
    "topK": 40,
    "maxOutputTokens": 65536
  }
}
EOF
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
# Processes the raw JSON response to extract the text content.
#
#
# Processes the raw JSON response to extract the text content.
#
process_response() {
   local raw_json="$1"
   # Extract the text response using Python, piping the raw JSON via stdin
   local extracted_text
   extracted_text=$(echo "${raw_json}" | python3 -c "
import json, sys
try:
    raw_text = sys.stdin.read() # <--- Reads from standard input
    if not raw_text:
        print('Error: Raw response is empty.', file=sys.stderr)
        sys.exit(1)
    data = json.loads(raw_text)
    if 'candidates' in data and data['candidates']:
        part = data['candidates'][0].get('content', {}).get('parts', [{}])[0]
        if 'text' in part:
            print(part['text'])
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
    print(f'--- Raw Response Start ---\\n{raw_text if \"raw_text\" in locals() else \"Could not read raw text\"}\\n--- Raw Response End ---', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Error processing response: {e}', file=sys.stderr)
    sys.exit(1)
")

   # Check if python script exited with an error
   if [ $? -ne 0 ]; then
       echo "Error: Failed to extract text from the response." >&2
       if [[ -n "${OUTPUT_RAW_FILE}" ]]; then
       echo "Check ${OUTPUT_RAW_FILE} for details." >&2
       fi
       exit 1
   fi

   # Return the final extracted text
   echo "$extracted_text"
}


# --- Main Execution ---

#
# Main function to orchestrate the script's execution.
#
main() {
  # Initialize variables
  local QUERY_STRING=""
  local QUERY_FILE=""
  local API_KEY_FILE=""
  local MODEL="${DEFAULT_MODEL}"
  local OUTPUT_PAYLOAD_FILE=""
  local OUTPUT_RAW_FILE=""
  local OUTPUT_FILE=""
  local VERBOSE="false"
  local GROUND="false"
  local THINKING_BUDGET=""   # empty -> omit thinkingConfig, leave the model default

  parse_arguments "$@"
  validate_input
  
  local api_key
  api_key=$(get_api_key)
  
  local query
  query=$(prepare_query)
  
  local payload
  payload=$(generate_payload "${query}")

  # Save payload to file if requested
  if [[ -n "${OUTPUT_PAYLOAD_FILE}" ]]; then
    echo "${payload}" > "${OUTPUT_PAYLOAD_FILE}"
    log_info "Payload saved to ${OUTPUT_PAYLOAD_FILE}"
  fi

  local raw_output
  raw_output=$(make_api_request "${api_key}" "${MODEL}" "${payload}")

  # Save raw output to file if requested
  if [[ -n "${OUTPUT_RAW_FILE}" ]]; then
    echo "${raw_output}" > "${OUTPUT_RAW_FILE}"
    log_info "Raw response saved to ${OUTPUT_RAW_FILE}"
  fi

  local final_text
  final_text=$(process_response "${raw_output}")

  # If process_response was successful, handle the final output
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

