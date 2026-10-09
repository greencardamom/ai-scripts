#!/usr/bin/env bash

#
# Script: gemini-files.sh
# Purpose: CLI utility to List, Delete, Upload, or Query files using the Google Gemini File API & Generative API
# Repo: https://github.com/greencardamom/Gemini-files
# Created: April 21, 2025
# Author: GreenC + Google Gemini Advanced 2.5 Pro
# Formatting: shfmt -i 3 -ci gemini-files.sh
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

#
# List, Delete, Upload, or Query files using the Google Gemini File API & Generative API
#
# Docs:
#   File API: https://ai.google.dev/gemini-api/docs/files
#   Generate Content: https://ai.google.dev/gemini-api/docs/api-overview#generate-content
#   Models: https://ai.google.dev/gemini-api/docs/models
#
# Usage:
#   ./gemini-files.sh [options] <ACTION> [action_args...]
#   Requires one action mode to be specified. Defaults to help if no action given.
#
# Action Modes & Arguments:
#   --list [id1 id2 ...]     List files. If specific file IDs (e.g., files/xxxx)
#                            are provided, only those files are listed.
#                            If no IDs are provided, all files are listed.
#   --delete [id1 id2 ...]   Delete files. If specific file IDs are provided,
#                            only those are targeted. If no IDs are provided,
#                            all files are targeted after confirmation.
#   --upload <fp1> [fp2 ...] Upload one or more specified files. Verifies status after upload.
#   --query <id_or_uri>      Query the specified file (requires --query-file).
#                            ID can be 'files/xxx' or just 'xxx'. URI is the full https link.
#
# Other Options:
#   --query-file <path>    Path to the file containing the text query (used with --query).
#   --model <name>         Model to use for --query (e.g., gemini-1.5-pro-latest).
#                          (Default: See DEFAULT_MODEL in config).
#   --max-tokens <number>  Max output tokens for --query (Default: See DEFAULT_MAX_TOKENS).
#   --thinking-level <l>   Gemini 3+ thinking for --query: minimal, low, medium or high (levels vary
#                          by model). Unset leaves the model default. Ignored, with a warning, on 2.x.
#   --json-output          For --query mode, output the raw API JSON response instead of just extracted text.
#   --keyfile <path>       Path to the file containing the Google API Key.
#                          (Overrides environment variable if both are set).
#   -v, --verbose          Enable verbose informational output to stderr.
#   -h, --help             Show this help message.
#
# API Key:
#   The script requires a Google API Key. It will be sourced in the following order:
#   1. From the file specified using the --keyfile <path> argument.
#   2. From the environment variable defined in API_KEY_ENV_VAR below.
#
# File API Limits (as of last check):
#   Max 20 GB total storage per project. Max 2 GB per file. Files stored for 48 hours.
#

# --- Default Configuration ---
# (Global - Accessed by functions)
MODE=""
API_KEY_ENV_VAR="GEMINI_API_KEY"
# Secret directories searched, in order, when --keyfile is not given and the env var is
# unset. Hosts keep secrets in different places; searching a list keeps ONE script
# identical everywhere instead of a per-host fork.
SECRET_SEARCH_DIRS=(
   "${HOME}/scripts/secrets"
   "${HOME}/.config/wikiget/secrets"
   "${HOME}/toolforge/scripts/secrets"
)
# Basenames looked up inside SECRET_SEARCH_DIRS. Two spellings of the same key are in use
# across the fleet (verified byte-identical), so both are searched.
KEY_BASENAMES=(
   "googlegemini.apikey"
   "googlegemini.key"
)
LIST_BASE_URL="https://generativelanguage.googleapis.com/v1beta/files"
API_ROOT_URL="https://generativelanguage.googleapis.com/v1beta"
UPLOAD_BASE_URL="https://generativelanguage.googleapis.com/upload/v1beta/files"
GENERATE_CONTENT_URL_TEMPLATE="https://generativelanguage.googleapis.com/v1beta/models/\${MODEL}:generateContent"
DEFAULT_MODEL="gemini-3.8-flash"
DEFAULT_MAX_TOKENS=8192 # Default for query mode
PAGE_SIZE=100
DELETE_DELAY=0.5
VERBOSE=0
DEFAULT_MIME_TYPE="application/octet-stream"
VERIFY_DELAYS=(5 10 20 60)

# --- Runtime Variables ---
# (Global - Set by argument parsing or functions)
key_file_arg=""
API_KEY=""
files_to_list_args=()
files_to_delete_args=()
files_to_upload_args=()
file_to_query=""
query_file_path=""
model_name=""
thinking_level=""
max_output_tokens_arg="" # Store value from --max-tokens
output_json_flag=0
grounding_flag=0
accumulator_json=""
query_payload_tmpfile=""

# --- Helper Function: Show Usage ---
#
# Function: usage
# Purpose: Prints help text derived from script comments and exits.
#
usage() {
   grep '^# Usage:' -A 2 "$0" | cut -c 3-
   echo # Add blank line
   grep '^# Action Modes & Arguments:' -A 9 "$0" | cut -c 3-
   echo                                           # Add blank line
   grep '^# Other Options:' -A 8 "$0" | cut -c 3- # Increased line count
   echo                                           # Add blank line
   grep '^# API Key:' -A 3 "$0" | cut -c 3-
   echo # Add blank line
   grep '^# File API Limits:' -A 1 "$0" | cut -c 3-
   exit 1
}

# --- Function: Determine API Key ---
#
# Function: determine_api_key
# Purpose: Echoes the path of the first KEY_BASENAMES file found in SECRET_SEARCH_DIRS,
#          else "".
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
# Purpose: Sets the global API_KEY variable from --keyfile, the env var, or a secret dir.
# Returns 0 on success, 1 on error.
#
determine_api_key() {
   if [[ -n "$key_file_arg" ]]; then
      if [[ ! -f "$key_file_arg" ]]; then
         echo "Error: Keyfile not found: $key_file_arg" >&2
         return 1
      fi
      API_KEY=$(tr -d '[:space:]' <"$key_file_arg")
      if [[ -z "$API_KEY" ]]; then
         echo "Error: Keyfile is empty: $key_file_arg" >&2
         return 1
      fi
      [[ "$VERBOSE" -eq 1 ]] && echo "Using API key from file: $key_file_arg" >&2
   elif [[ -v "${API_KEY_ENV_VAR}" && -n "${!API_KEY_ENV_VAR}" ]]; then
      API_KEY=$(printf '%s' "${!API_KEY_ENV_VAR}" | tr -d '[:space:]')
      [[ "$VERBOSE" -eq 1 ]] && echo "Using API key from env var: $API_KEY_ENV_VAR" >&2
   else
      local found
      found=$(find_secret)
      if [[ -n "$found" ]]; then
         API_KEY=$(tr -d '[:space:]' <"$found")
         [[ "$VERBOSE" -eq 1 ]] && echo "Using API key from default keyfile: $found" >&2
      else
         echo "Error: API Key not found. Use --keyfile, set ${API_KEY_ENV_VAR}, or place one of:" >&2
         printf '  %s\n' "${KEY_BASENAMES[@]}" >&2
         echo "in one of:" >&2
         printf '  %s\n' "${SECRET_SEARCH_DIRS[@]}" >&2
         return 1
      fi
   fi
   if [[ -z "$API_KEY" ]]; then
      echo "Error: API Key is empty." >&2
      return 1
   fi
   return 0
}

# --- Function: Fetch All Files List ---
#
# Function: fetch_all_files
# Purpose: Populates the global 'accumulator_json' variable with all files.
# Returns 0 on success, 1 on error.
#
fetch_all_files() {
   [[ "$VERBOSE" -eq 1 ]] && echo "Fetching file list from API..." >&2
   local page_token="" fetch_status=0 request_url response curl_exit_code jq_exit_code next_page_token new_accumulator
   accumulator_json=$(jq -n '{files: []}')
   while true; do
      request_url="${LIST_BASE_URL}?key=${API_KEY}&pageSize=${PAGE_SIZE}"
      if [[ -n "$page_token" ]]; then request_url="${request_url}&pageToken=${page_token}"; fi
      response=$(curl -sfS --connect-timeout 15 --max-time 60 "${request_url}")
      curl_exit_code=$?
      if [[ $curl_exit_code -ne 0 ]]; then
         echo "Error: curl failed (code $curl_exit_code) fetching list." >&2
         echo "URL: ${request_url%key=*}key=***" >&2
         fetch_status=1
         break
      fi
      if ! echo "$response" | jq -e . >/dev/null 2>&1; then
         echo "Error: Invalid JSON response fetching list." >&2
         echo "$response" >&2
         fetch_status=1
         break
      fi
      new_accumulator=$(jq --argjson current_response "$response" '.files += ($current_response.files // [])' <<<"$accumulator_json")
      jq_exit_code=$?
      if [[ $jq_exit_code -ne 0 ]]; then
         echo "Error: jq failed (code $jq_exit_code) merging files." >&2
         fetch_status=1
         break
      fi
      accumulator_json="$new_accumulator"
      next_page_token=$(echo "$response" | jq -r '.nextPageToken // empty')
      if [[ -z "$next_page_token" ]]; then break; else
         page_token="$next_page_token"
         sleep 0.1
      fi
   done
   [[ "$fetch_status" -eq 0 && "$VERBOSE" -eq 1 ]] && echo "File list fetched successfully." >&2
   return $fetch_status
}

# --- Function: Get Single File Status ---
#
# Function: get_file_status
# Purpose: Gets the status of a single file by name.
# Arg $1: file_name (e.g., files/xxx)
# Outputs status string ("ACTIVE", "PROCESSING", "FAILED", "ERROR: reason") to stdout
# Returns 0 if status determined, 1 on curl/API error or missing state
#
get_file_status() {
   local file_name="$1" metadata_url status curl_exit_code metadata_response state error_details
   metadata_url="${API_ROOT_URL}/${file_name}?key=${API_KEY}"
   metadata_response=$(curl -sfS --connect-timeout 10 --max-time 30 "$metadata_url")
   curl_exit_code=$?
   if [[ $curl_exit_code -ne 0 ]]; then
      error_details=$(echo "$metadata_response" | jq -r '.error.message // empty')
      if [[ -n "$error_details" ]]; then 
         echo "ERROR: Curl Error ($curl_exit_code), API Message: $error_details"
      else 
         echo "ERROR: Curl Error ($curl_exit_code)"
      fi
      return 1
   fi
   error_details=$(echo "$metadata_response" | jq -r '.error.message // empty')
   if [[ -n "$error_details" ]]; then
      echo "ERROR: API Error: $error_details"
      return 1
   fi
   state=$(echo "$metadata_response" | jq -r '.state // empty')
   if [[ -n "$state" ]]; then
      echo "$state"
      return 0
   else
      echo "ERROR: State field missing in metadata"
      [[ "$VERBOSE" -eq 1 ]] && echo "  Response for $file_name: $metadata_response" >&2
      return 1
   fi
}

# --- Function: Perform Deletions ---
#
# Function: perform_deletions
# Purpose: Loops through 'files_to_process' array and deletes each file.
# Reads file list from global 'files_to_process' array.
# Returns 0 if all succeed (or no errors encountered), 1 if any errors.
#
perform_deletions() {
   [[ "$VERBOSE" -eq 1 ]] && echo "Starting deletion..." >&2
   local deleted_count=0 error_count=0 total_count=${#files_to_process[@]} i file_name progress DELETE_URL DEL_RESPONSE DEL_CURL_EXIT_CODE error_details
   for i in "${!files_to_process[@]}"; do
      file_name="${files_to_process[$i]}"
      progress=$((i + 1))
      [[ "$VERBOSE" -eq 1 ]] && echo -n "Deleting ${file_name} (${progress}/${total_count})... " >&2
      DELETE_URL="${API_ROOT_URL}/${file_name}?key=${API_KEY}"
      DEL_RESPONSE=$(curl -sfS --connect-timeout 10 --max-time 30 -X DELETE "${DELETE_URL}")
      DEL_CURL_EXIT_CODE=$?
      if [[ $DEL_CURL_EXIT_CODE -eq 0 ]]; then
         if [[ -z "$DEL_RESPONSE" ]] || [[ "$DEL_RESPONSE" == "{}" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "OK" >&2
            ((deleted_count++))
         else
            [[ "$VERBOSE" -ne 1 ]] && echo
            echo "Warning: Delete OK for ${file_name} but resp: ${DEL_RESPONSE}" >&2
            ((deleted_count++))
         fi
      else
         [[ "$VERBOSE" -ne 1 ]] && echo
         echo "Error deleting ${file_name} (curl code ${DEL_CURL_EXIT_CODE})" >&2
         error_details=$(echo "$DEL_RESPONSE" | jq -r '.error | "\(.code // "?") \(.status // "?"): \(.message // "?")" ' 2>/dev/null)
         if [[ -n "$error_details" && "$error_details" != "? ?: ?" ]]; then echo "  API Error: ${error_details}" >&2; elif [[ -n "$DEL_RESPONSE" ]]; then echo "  Response: ${DEL_RESPONSE}" >&2; fi
         ((error_count++))
      fi
      sleep ${DELETE_DELAY}
   done
   echo "-----------------------------------------" >&2
   echo "Deletion complete."
   echo "Successfully deleted: ${deleted_count}"
   echo "Errors encountered: ${error_count}" >&2
   echo "-----------------------------------------" >&2
   if [[ $error_count -gt 0 ]]; then return 1; else return 0; fi
}

# --- Function: Verify Uploads ---
#
# Function: verify_uploads
# Purpose: Checks status of uploaded files with retries until ACTIVE/FAILED/Timeout.
# Args: List of file names (files/xxx) that were successfully initiated.
# Prints verified names to stdout. Returns 0 if all verified, 1 if any failed/timed out.
#
verify_uploads() {
   local -a names_to_verify=("$@")
   local overall_verification_status=0
   if [[ ${#names_to_verify[@]} -eq 0 ]]; then return 0; fi
   [[ "$VERBOSE" -eq 1 ]] && echo "--- Starting Verification Phase for ${#names_to_verify[@]} files ---" >&2
   local -A verification_status
   local -a successful_verification=() failed_verification=()
   local pending_count=${#names_to_verify[@]} file_name delay attempt status_output get_status_ret final_status
   for name in "${names_to_verify[@]}"; do verification_status["$name"]="pending"; done
   attempt=0
   for delay in "${VERIFY_DELAYS[@]}"; do
      ((attempt++))
      if [[ $pending_count -eq 0 ]]; then break; fi
      if [[ $attempt -gt 1 ]]; then
         [[ "$VERBOSE" -eq 1 ]] && echo "Waiting ${delay}s before check #${attempt} for ${pending_count} pending..." >&2
         sleep "$delay"
      elif [[ "$VERBOSE" -eq 1 ]]; then echo "Initial check (attempt #${attempt}) for ${pending_count} pending..." >&2; fi
      local -a current_pending_keys=("${!verification_status[@]}")
      for file_name in "${current_pending_keys[@]}"; do
         [[ "${verification_status["$file_name"]}" != "pending"* ]] && continue
         [[ "$VERBOSE" -eq 1 ]] && echo -n "  Check #${attempt} for ${file_name}... " >&2
         status_output=$(get_file_status "$file_name")
         get_status_ret=$?
         if [[ $get_status_ret -ne 0 || "$status_output" == ERROR:* ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "Error Status" >&2
            verification_status["$file_name"]="error:${status_output#ERROR: }"
            ((pending_count--))
         elif [[ "$status_output" == "ACTIVE" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "ACTIVE" >&2
            verification_status["$file_name"]="active"
            ((pending_count--))
         elif [[ "$status_output" == "FAILED" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "FAILED (API)" >&2
            verification_status["$file_name"]="failed"
            ((pending_count--))
         else
            [[ "$VERBOSE" -eq 1 ]] && echo "Pending ($status_output)" >&2
            verification_status["$file_name"]="pending:$status_output"
         fi
      done
   done
   [[ "$VERBOSE" -eq 1 ]] && echo "--- Verification Phase Complete ---" >&2
   echo "-----------------------------------------" >&2
   echo "Verification Summary:" >&2
   for file_name in "${!verification_status[@]}"; do
      final_status="${verification_status["$file_name"]}"
      [[ "$VERBOSE" -eq 1 ]] && echo "DEBUG verify_uploads: Final categorization for $file_name -> $final_status" >&2
      if [[ "$final_status" == "active" ]]; then
         successful_verification+=("$file_name")
      elif [[ "$final_status" == "pending"* ]]; then
         failed_verification+=("$file_name (Timed Out - Last: ${final_status#pending:})")
         overall_verification_status=1
      else
         failed_verification+=("$file_name (${final_status})")
         overall_verification_status=1
      fi
   done
   if [[ ${#failed_verification[@]} -gt 0 ]]; then
      echo " Files that failed verification:" >&2
      printf "  - %s\n" "${failed_verification[@]}" >&2
   fi
   if [[ ${#successful_verification[@]} -gt 0 ]]; then
      [[ "$VERBOSE" -eq 1 ]] && {
         echo "DEBUG verify_uploads: successful_verification size = ${#successful_verification[@]}" >&2
         declare -p successful_verification >&2
      }
      echo " Files successfully verified as ACTIVE:" >&2
      printf "  - %s\n" "${successful_verification[@]}" >&2
      printf "%s\n" "${successful_verification[@]}"
   else echo " No files were successfully verified." >&2; fi
   echo "-----------------------------------------" >&2
   return $overall_verification_status
}

# --- Mode Execution Functions ---

#
# Function: run_mode_list
# Purpose: Handles the --list action.
#
run_mode_list() {
   [[ "$VERBOSE" -eq 1 ]] && echo "Mode: List" >&2
   fetch_all_files
   local fetch_exit_status=$?
   if [[ $fetch_exit_status -ne 0 ]]; then
      echo "Aborting list due to fetch errors." >&2
      return $fetch_exit_status
   fi

   if [[ ${#files_to_list_args[@]} -gt 0 ]]; then
      [[ "$VERBOSE" -eq 1 ]] && echo "Filtering for specific files specified..." >&2
      local -a requested_unique missing_files
      local -A found_map
      local requested_names_json jq_filter_script filtered_files_json found_names_output line req_id found_files_count output_json
      mapfile -t requested_unique < <(printf "%s\n" "${files_to_list_args[@]}" | sort -u)
      if [[ ${#requested_unique[@]} -eq 0 ]]; then
         echo "Error: No valid file IDs provided." >&2
         return 1
      fi
      requested_names_json=$(printf "%s\n" "${requested_unique[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
      if [[ $? -ne 0 || -z "$requested_names_json" ]]; then
         echo "Error: Failed creating JSON array of names." >&2
         return 1
      fi
      jq_filter_script=' .files | map(select(.name as $n | $requested_names | index($n))) '
      filtered_files_json=$(echo "$accumulator_json" | jq --argjson requested_names "$requested_names_json" "$jq_filter_script")
      if [[ $? -ne 0 ]]; then
         echo "Error: jq filter operation failed." >&2
         return 1
      fi
      missing_files=()
      declare -A found_map
      found_names_output=$(echo "$filtered_files_json" | jq -r '.[]?.name // empty')
      if [[ $? -ne 0 ]]; then
         echo "Error: jq failed extracting found names." >&2
         return 1
      fi
      while IFS= read -r line; do if [[ -n "$line" ]]; then found_map["$line"]=1; fi; done <<<"$found_names_output"
      for req_id in "${requested_unique[@]}"; do if ! [[ -v found_map["$req_id"] ]]; then missing_files+=("$req_id"); fi; done
      if [[ ${#missing_files[@]} -gt 0 ]]; then
         echo "Warning: Requested file IDs not found:" >&2
         printf " -- %s\n" "${missing_files[@]}" >&2
      fi
      found_files_count=$(echo "$filtered_files_json" | jq 'length')
      if [[ $? -ne 0 ]]; then
         echo "Error: jq failed counting files." >&2
         return 1
      fi
      [[ "$VERBOSE" -eq 1 ]] && echo "Found $found_files_count matching files out of ${#requested_unique[@]} unique IDs requested." >&2
      output_json=$(jq -n --argjson f "$filtered_files_json" '{files: $f}')
      if [[ $? -ne 0 ]]; then
         echo "Error: jq failed constructing output JSON." >&2
         return 1
      fi
      echo "$output_json"
   else
      [[ "$VERBOSE" -eq 1 ]] && echo "Listing all files..." >&2
      echo "$accumulator_json"
   fi
   return 0
}

#
# Function: run_mode_delete
# Purpose: Handles the --delete action.
#
run_mode_delete() {
   [[ "$VERBOSE" -eq 1 ]] && echo "Mode: Delete" >&2
   fetch_all_files
   local fetch_exit_status=$?
   if [[ $fetch_exit_status -ne 0 ]]; then
      echo "Aborting delete due to list errors." >&2
      return $fetch_exit_status
   fi
   declare -g -a files_to_process
   files_to_process=()
   local file_count=0
   local -a all_api_files=() invalid_files_requested=()
   while IFS= read -r line; do if [[ -n "$line" ]]; then all_api_files+=("$line"); fi; done < <(echo "$accumulator_json" | jq -r '.files[].name // empty')
   if [[ ${#files_to_delete_args[@]} -gt 0 ]]; then
      [[ "$VERBOSE" -eq 1 ]] && echo "(Specific Files Requested)" >&2
      local validated_files_to_delete=()
      local -A available_files_map
      for api_file in "${all_api_files[@]}"; do available_files_map["$api_file"]=1; done
      local -a unique_requested_files
      mapfile -t unique_requested_files < <(printf "%s\n" "${files_to_delete_args[@]}" | sort -u)
      for requested_file in "${unique_requested_files[@]}"; do if [[ -v available_files_map["$requested_file"] ]]; then validated_files_to_delete+=("$requested_file"); else invalid_files_requested+=("$requested_file"); fi; done
      if [[ ${#invalid_files_requested[@]} -gt 0 ]]; then
         echo "Error: Requested file IDs not found:" >&2
         printf " - %s\n" "${invalid_files_requested[@]}" >&2
      fi
      files_to_process=("${validated_files_to_delete[@]}")
      file_count=${#files_to_process[@]}
      if [[ $file_count -eq 0 ]]; then
         echo "No valid files specified or found." >&2
         return 0
      fi
   else
      [[ "$VERBOSE" -eq 1 ]] && echo "(All Files)" >&2
      files_to_process=("${all_api_files[@]}")
      file_count=${#files_to_process[@]}
      if [[ $file_count -eq 0 ]]; then
         [[ "$VERBOSE" -eq 1 ]] && echo "No files found to delete." >&2
         return 0
      fi
   fi
   echo "-----------------------------------------" >&2
   echo "Targeting ${file_count} files for deletion." >&2
   [[ "$VERBOSE" -eq 1 ]] && {
      echo "Files to be deleted:" >&2
      printf " - %s\n" "${files_to_process[@]}" >&2
   }
   echo "-----------------------------------------" >&2
   local confirm confirm_lc
   read -p "Proceed with deletion? (Type 'yes' to confirm): " confirm
   confirm_lc=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
   if [[ "$confirm_lc" != "yes" && "$confirm_lc" != "y" ]]; then
      echo "Deletion aborted." >&2
      return 0
   fi
   perform_deletions
   local delete_status=$?
   [[ "$VERBOSE" -eq 1 ]] && echo "DEBUG: perform_deletions returned status: $delete_status" >&2
   return $delete_status
}

#
# Function: run_mode_upload
# Purpose: Handles the --upload action including verification.
#
run_mode_upload() {
   [[ "$VERBOSE" -eq 1 ]] && echo "Mode: Upload" >&2
   local -a uploaded_file_names=() failed_initial_uploads=()
   local initial_upload_exit_status=0 verify_exit_status=0
   local file_to_upload_path display_name mime_type detected_mime metadata_json upload_response curl_exit_code uploaded_file_name error_details jq_exit_code
   [[ "$VERBOSE" -eq 1 ]] && echo "--- Starting Initial Upload Phase ---" >&2
   for file_to_upload_path in "${files_to_upload_args[@]}"; do
      [[ "$VERBOSE" -eq 1 ]] && echo "Processing file: $file_to_upload_path" >&2
      if [[ ! -f "$file_to_upload_path" ]]; then
         echo "Error: File not found: $file_to_upload_path" >&2
         failed_initial_uploads+=("$file_to_upload_path (Not Found)")
         initial_upload_exit_status=1
         continue
      fi
      display_name=$(basename "$file_to_upload_path")
      mime_type="$DEFAULT_MIME_TYPE"
      if command -v file >/dev/null; then
         detected_mime=$(file --brief --mime-type "$file_to_upload_path")
         if [[ $? -eq 0 && -n "$detected_mime" && "$detected_mime" == */* ]]; then mime_type="$detected_mime"; elif [[ "$VERBOSE" -eq 1 ]]; then echo "Warn: 'file' check failed for '$file_to_upload_path'. Using default: $mime_type" >&2; fi
      elif [[ "$VERBOSE" -eq 1 ]]; then echo "Warn: 'file' cmd not found. Using default: $mime_type" >&2; fi
      metadata_json=$(jq -nc --arg dn "$display_name" '{"file": {"displayName": $dn}}')
      jq_exit_code=$?
      if [[ $jq_exit_code -ne 0 || -z "$metadata_json" ]]; then
         echo "Error: Metadata creation failed for $file_to_upload_path." >&2
         failed_initial_uploads+=("$file_to_upload_path (Meta Error)")
         initial_upload_exit_status=1
         continue
      fi
      [[ "$VERBOSE" -eq 1 ]] && echo -n "  Uploading $file_to_upload_path (Display: $display_name, Type: $mime_type)... " >&2
      upload_response=$(curl -sfS --connect-timeout 15 --max-time 600 -X POST "${UPLOAD_BASE_URL}?key=${API_KEY}" -H "X-Goog-Upload-Protocol: multipart" -F "metadata=${metadata_json};type=application/json" -F "file=@${file_to_upload_path};type=${mime_type}")
      curl_exit_code=$?
      if [[ $curl_exit_code -eq 0 ]]; then
         uploaded_file_name=$(echo "$upload_response" | jq -r '.file.name // empty')
         jq_exit_code=$?
         if [[ $jq_exit_code -ne 0 ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "FAILED (jq parse error)"
            failed_initial_uploads+=("$file_to_upload_path (Response Parse Error)")
            initial_upload_exit_status=1
            continue
         fi
         if [[ -n "$uploaded_file_name" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "OK ($uploaded_file_name)" >&2
            uploaded_file_names+=("$uploaded_file_name")
         else
            [[ "$VERBOSE" -eq 1 ]] && echo "FAILED (API Error)"
            echo "Error: Upload OK for $file_to_upload_path but API response error." >&2
            error_details=$(echo "$upload_response" | jq -r '.error.message // empty')
            if [[ -n "$error_details" ]]; then echo "  API Error: ${error_details}" >&2; else echo "  Resp: ${upload_response}" >&2; fi
            failed_initial_uploads+=("$file_to_upload_path (API Error)")
            initial_upload_exit_status=1
         fi
      else
         [[ "$VERBOSE" -eq 1 ]] && echo "FAILED (Curl Error $curl_exit_code)" >&2
         echo "Error: Upload failed for $file_to_upload_path (curl code ${curl_exit_code})." >&2
         error_details=$(echo "$upload_response" | jq -r '.error.message // empty')
         if [[ -n "$error_details" ]]; then echo "  API Error: ${error_details}" >&2; elif [[ -n "$upload_response" ]]; then echo "  Resp: ${upload_response}" >&2; fi
         failed_initial_uploads+=("$file_to_upload_path (Curl Error $curl_exit_code)")
         initial_upload_exit_status=1
      fi
   done
   [[ "$VERBOSE" -eq 1 ]] && echo "--- Initial Upload Phase Complete ---" >&2
   if [[ ${#failed_initial_uploads[@]} -gt 0 ]]; then
      echo "-----------------------------------------" >&2
      echo "Initial Upload Failures:" >&2
      printf "  - %s\n" "${failed_initial_uploads[@]}" >&2
      echo "-----------------------------------------" >&2
   fi
   verify_uploads "${uploaded_file_names[@]}"
   verify_exit_status=$?
   if [[ $initial_upload_exit_status -ne 0 || $verify_exit_status -ne 0 ]]; then return 1; else return 0; fi
}

#
# Function: run_mode_query
# Purpose: Handles the --query action using a temporary file for the payload.
#
run_mode_query() {
   [[ "$VERBOSE" -eq 1 ]] && echo "Mode: Query" >&2
   local query_model="${model_name:-$DEFAULT_MODEL}"
   [[ "$VERBOSE" -eq 1 ]] && echo "Using model: $query_model" >&2

   local query_file_name="$file_to_query"
   [[ "$VERBOSE" -eq 1 ]] && echo "Query target file name: $query_file_name" >&2

   [[ "$VERBOSE" -eq 1 ]] && echo "Fetching metadata for $query_file_name..." >&2
   local metadata_url="${API_ROOT_URL}/${query_file_name}?key=${API_KEY}"
   local metadata_response
   metadata_response=$(curl -sfS --connect-timeout 10 --max-time 30 "$metadata_url")
   local curl_exit_code=$?
   local meta_error_details query_file_mime_type query_file_uri jq_exit_code query_text payload_json generate_url QUERY_RESPONSE api_error_details block_reason candidate_count finish_reason safety_ratings generated_text

   query_payload_tmpfile="" # Reset global var

   if [[ $curl_exit_code -ne 0 ]]; then
      echo "Error: Failed fetch metadata (curl code $curl_exit_code)." >&2
      meta_error_details=$(echo "$metadata_response" | jq -r '.error.message // empty')
      if [[ -n "$meta_error_details" ]]; then echo "  API Error: ${meta_error_details}" >&2; elif [[ -n "$metadata_response" ]]; then echo "  Response: ${metadata_response}" >&2; fi
      echo "URL: ${metadata_url%key=*}key=***" >&2
      return 1
   fi
   query_file_mime_type=$(echo "$metadata_response" | jq -r '.mimeType // empty')
   query_file_uri=$(echo "$metadata_response" | jq -r '.uri // empty')
   jq_exit_code=$?
   if [[ $jq_exit_code -ne 0 || -z "$query_file_mime_type" || -z "$query_file_uri" ]]; then
      echo "Error: Missing mime/uri in metadata (or jq error)." >&2
      echo "Response: $metadata_response" >&2
      return 1
   fi
   [[ "$VERBOSE" -eq 1 ]] && echo "Found MIME: $query_file_mime_type, URI: $query_file_uri" >&2

   if [[ ! -f "$query_file_path" ]]; then
      echo "Error: Query file not found: $query_file_path" >&2
      return 1
   fi
   query_text=$(<"$query_file_path")
   if [[ -z "$query_text" ]]; then
      echo "Error: Query file empty: $query_file_path" >&2
      return 1
   fi
   [[ "$VERBOSE" -eq 1 ]] && echo "Read query from: $query_file_path" >&2

   # Determine maxOutputTokens value
   local max_tokens_to_use
   if [[ -n "$max_output_tokens_arg" ]]; then
      if [[ "$max_output_tokens_arg" =~ ^[1-9][0-9]*$ ]]; then
         max_tokens_to_use=$max_output_tokens_arg
      else
         echo "Error: --max-tokens value ('$max_output_tokens_arg') must be a positive integer." >&2
         return 1
      fi
   else
      max_tokens_to_use=$DEFAULT_MAX_TOKENS
   fi
   [[ "$VERBOSE" -eq 1 ]] && echo "Using maxOutputTokens: $max_tokens_to_use" >&2

   # Google Search grounding tool (enabled with -g/--grounding). Current models
   # (Gemini 2.5/3.x) use the "google_search" tool; legacy used google_search_retrieval.
   local tools_json='[]'
   if [[ "$grounding_flag" -eq 1 ]]; then
      tools_json='[ { "google_search": {} } ]'
      [[ "$VERBOSE" -eq 1 ]] && echo "Web grounding ENABLED (google_search tool)" >&2
   fi

   if [[ -n "$thinking_level" && "$query_model" =~ gemini-([0-9]+) ]] && (( BASH_REMATCH[1] < 3 )); then
      echo "Warning: --thinking-level needs Gemini 3+, ignored for $query_model" >&2
   fi
   # Construct Payload JSON string with dynamic max tokens (+ tools if grounding). Sampling fields only
   # up to Gemini 3.5: Google (2026-10) says 3.6+ ignore them and upcoming models reject them.
   payload_json=$(jq -nc \
      --arg qry "$query_text" \
      --arg mime "$query_file_mime_type" \
      --arg uri "$query_file_uri" \
      --argjson tokens "$max_tokens_to_use" \
      --argjson tools "$tools_json" \
      --arg model "$query_model" \
      --arg level "$thinking_level" \
      '(($model | capture("gemini-(?<maj>[0-9]+)([.](?<min>[0-9]+))?"))? // {"maj": "99"}) as $v | ((($v.maj|tonumber) < 3) or (($v.maj|tonumber) == 3 and (($v.min // "0")|tonumber) <= 5)) as $legacy | { "contents": [ { "parts":[ { "text": $qry }, { "fileData": { "mimeType": $mime, "fileUri": $uri } } ] } ], "generationConfig": ((if $legacy then { "temperature": 0.5, "topP": 0.95, "topK": 40 } else {} end) + (if $level != "" and ($v.maj|tonumber) >= 3 then { "thinkingConfig": { "thinkingLevel": $level } } else {} end) + { "maxOutputTokens": $tokens }) } + (if ($tools|length) > 0 then { "tools": $tools } else {} end)')
   jq_exit_code=$?
   if [[ $jq_exit_code -ne 0 || -z "$payload_json" ]]; then
      echo "Error: Failed to construct JSON payload." >&2
      return 1
   fi
   [[ "$VERBOSE" -eq 1 ]] && echo "Constructed query payload." >&2

   query_payload_tmpfile=$(mktemp "gemini_query_payload.XXXXXX")
   if [[ $? -ne 0 || -z "$query_payload_tmpfile" || ! -f "$query_payload_tmpfile" ]]; then
      echo "Error: Failed to create temporary file." >&2
      query_payload_tmpfile=""
      return 1
   fi
   [[ "$VERBOSE" -eq 1 ]] && echo "Using temporary payload file: $query_payload_tmpfile" >&2

   printf "%s" "$payload_json" >"$query_payload_tmpfile"
   local write_status=$?
   if [[ $write_status -ne 0 ]]; then
      echo "Error: Failed writing payload to temp file '$query_payload_tmpfile'." >&2
      rm -f "$query_payload_tmpfile"
      query_payload_tmpfile=""
      return 1
   fi

   generate_url=$(echo "$GENERATE_CONTENT_URL_TEMPLATE" | sed "s/\${MODEL}/${query_model}/")
   if [[ $? -ne 0 ]]; then
      echo "Error substituting model in URL." >&2
      rm -f "$query_payload_tmpfile"
      query_payload_tmpfile=""
      return 1
   fi
   [[ "$VERBOSE" -eq 1 ]] && echo "Sending query to model ${query_model}..." >&2

   local _q_t0 _q_t1
   _q_t0=$(date +%s.%N)
   QUERY_RESPONSE=$(curl -sfS --connect-timeout 15 --max-time 600 -X POST "${generate_url}?key=${API_KEY}" -H 'Content-Type: application/json' -d @"$query_payload_tmpfile")
   CURL_EXIT_CODE=$?
   _q_t1=$(date +%s.%N)
   awk -v a="$_q_t0" -v b="$_q_t1" -v m="$query_model" -v g="$grounding_flag" 'BEGIN{ printf "QUERY_LATENCY: %.2fs (model=%s grounding=%s)\n", b-a, m, g }' >&2

   rm -f "$query_payload_tmpfile"
   query_payload_tmpfile="" # Clean up immediately

   # --- Response Handling with Output Format Check ---
   if [[ "$output_json_flag" -eq 1 ]]; then
      # User requested raw JSON output
      if [[ $CURL_EXIT_CODE -eq 0 && -n "$QUERY_RESPONSE" ]]; then
         printf "%s\n" "$QUERY_RESPONSE"
         return 0
      else
         echo "Error: Query curl command failed (Code: ${CURL_EXIT_CODE}) or returned empty response." >&2
         api_error_details=$(echo "$QUERY_RESPONSE" | jq -r '.error | "\(.code // "?") \(.status // "?"): \(.message // "?")" ' 2>/dev/null)
         if [[ -n "$api_error_details" && "$api_error_details" != "? ?: ?" ]]; then echo "  API Error: ${api_error_details}" >&2; elif [[ -n "$QUERY_RESPONSE" ]]; then echo "  Response: ${QUERY_RESPONSE}" >&2; fi
         return 1
      fi
   else
      # --- Default Text Output Handling ---
      if [[ $CURL_EXIT_CODE -eq 0 ]]; then
         api_error_details=$(echo "$QUERY_RESPONSE" | jq -r '.error | "\(.code // "?") \(.status // "?"): \(.message // "?")" ' 2>/dev/null)
         jq_exit_code=$?
         if [[ $jq_exit_code -ne 0 ]]; then echo "Warn: Failed parsing API error." >&2; fi
         if [[ $jq_exit_code -eq 0 && -n "$api_error_details" && "$api_error_details" != "? ?: ?" ]]; then
            echo "Error: API error." >&2
            echo "  API Error: ${api_error_details}" >&2
            return 1
         fi
         block_reason=$(echo "$QUERY_RESPONSE" | jq -r '.promptFeedback.blockReason // empty')
         if [[ $? -ne 0 ]]; then
            echo "Warn: Failed parsing promptFeedback." >&2
            block_reason=""
         fi
         if [[ -n "$block_reason" ]]; then
            echo "Error: Query blocked. Reason: $block_reason" >&2
            [[ "$VERBOSE" -eq 1 ]] && echo "$QUERY_RESPONSE" >&2
            return 1
         fi
         candidate_count=$(echo "$QUERY_RESPONSE" | jq '.candidates | length // 0')
         if [[ $? -ne 0 ]]; then
            echo "Warn: Failed parsing candidates." >&2
            candidate_count=0
         fi
         if [[ $candidate_count -eq 0 ]]; then
            echo "Error: API returned successfully but provided no candidates." >&2
            [[ "$VERBOSE" -eq 1 ]] && echo "$QUERY_RESPONSE" >&2
            return 1
         fi
         finish_reason=$(echo "$QUERY_RESPONSE" | jq -r '.candidates[0].finishReason // "UNSPECIFIED"')
         if [[ $? -ne 0 ]]; then
            echo "Warn: Failed parsing finishReason." >&2
            finish_reason="UNKNOWN"
         fi
         if [[ "$finish_reason" == "SAFETY" ]]; then
            echo "Error: Query response flagged for safety (finishReason: SAFETY)." >&2
            [[ "$VERBOSE" -eq 1 ]] && echo "$QUERY_RESPONSE" >&2
            return 1
         fi
         if [[ "$finish_reason" != "STOP" ]]; then
            echo "Error: Model generation finished for reason: $finish_reason" >&2
            [[ "$VERBOSE" -eq 1 ]] && echo "$QUERY_RESPONSE" >&2
            return 1
         fi
         generated_text=$(echo "$QUERY_RESPONSE" | jq -r '.candidates[0].content.parts[0].text // ""')
         if [[ $? -ne 0 ]]; then
            echo "Error: Failed parsing generated text." >&2
            return 1
         fi
         printf "%s\n" "$generated_text" # Print text (or empty line)
         if [[ -z "$generated_text" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "$QUERY_RESPONSE" >&2
            echo "Warning: Model finished successfully (STOP), but no text content was found." >&2
         fi
         return 0 # Success
      else
         echo "Error: Query failed (curl code ${CURL_EXIT_CODE})." >&2
         api_error_details=$(echo "$QUERY_RESPONSE" | jq -r '.error | "\(.code // "?") \(.status // "?"): \(.message // "?")" ' 2>/dev/null)
         if [[ -n "$api_error_details" && "$api_error_details" != "? ?: ?" ]]; then echo "  API Error: ${api_error_details}" >&2; elif [[ -n "$QUERY_RESPONSE" ]]; then echo "  Response: ${QUERY_RESPONSE}" >&2; fi
         return 1
      fi
      # --- End Default Text Output Handling ---
   fi
}

# --- Cleanup Function (for trap) ---
#
# Function: cleanup
# Purpose: Trap function to clean up temporary query payload file on exit/error.
#
cleanup() {
   if [[ -n "$query_payload_tmpfile" && -f "$query_payload_tmpfile" ]]; then
      [[ "$VERBOSE" -eq 1 ]] && {
         echo
         echo "--- Running Trap Cleanup ---" >&2
         echo "Cleaning up leftover query payload temp file: $query_payload_tmpfile" >&2
      }
      rm -f "$query_payload_tmpfile"
   fi
}

# --- Function: Parse Arguments and Validate ---
#
# Function: parse_arguments
# Purpose: Parses command line arguments, sets global mode and option variables.
# Exits via usage() on error. Accepts original script arguments "$@".
#
parse_arguments() {
   local current_arg
   local -a remaining_args=()
   while [[ $# -gt 0 ]]; do
      current_arg="$1"
      if [[ "$current_arg" == -* ]]; then
         case "$current_arg" in
            --list)
               if [[ -n "$MODE" ]]; then
                  echo "E: Modes conflict (--list vs --${MODE})" >&2
                  usage
               fi
               MODE="list"
               shift
               ;;
            --delete)
               if [[ -n "$MODE" ]]; then
                  echo "E: Modes conflict (--delete vs --${MODE})" >&2
                  usage
               fi
               MODE="delete"
               shift
               ;;
            --upload)
               if [[ -n "$MODE" ]]; then
                  echo "E: Modes conflict (--upload vs --${MODE})" >&2
                  usage
               fi
               MODE="upload"
               shift
               ;;
            --query)
               if [[ -n "$MODE" ]]; then
                  echo "E: Modes conflict (--query vs --${MODE})" >&2
                  usage
               fi
               MODE="query"
               if [[ -n "$2" && "$2" != -* ]]; then
                  file_to_query="$2"
                  shift 2
               else
                  echo "E: --query needs file ID/URI." >&2
                  usage
               fi
               ;;
            --query-file) if [[ -n "$2" && "$2" != -* ]]; then
               query_file_path="$2"
               shift 2
            else
               echo "E: --query-file needs path." >&2
               usage
            fi ;;
            --model) if [[ -n "$2" && "$2" != -* ]]; then
               model_name="$2"
               shift 2
            else
               echo "E: --model needs name." >&2
               usage
            fi ;;
            --keyfile) if [[ -n "$2" && "$2" != -* ]]; then
               key_file_arg="$2"
               shift 2
            else
               echo "E: --keyfile needs path." >&2
               usage
            fi ;;
            --thinking-level) if [[ "$2" =~ ^(minimal|low|medium|high)$ ]]; then
               thinking_level="$2"
               shift 2
            else
               echo "E: --thinking-level needs minimal, low, medium or high." >&2
               usage
            fi ;;
            --max-tokens) # New option
               if [[ -n "$2" && "$2" =~ ^[1-9][0-9]*$ ]]; then
                  max_output_tokens_arg="$2"
                  shift 2
               else
                  echo "E: --max-tokens requires a positive integer argument." >&2
                  usage
               fi ;;
            --json-output)
               output_json_flag=1
               shift
               ;; # Added
            -g | --grounding) # Enable Google Search web grounding for the query
               grounding_flag=1
               shift
               ;;
            -v | --verbose)
               VERBOSE=1
               shift
               ;;
            -h | --help) usage ;;
            *)
               echo "E: Unknown option '$1'" >&2
               usage
               ;;
         esac
      else
         remaining_args+=("$1")
         shift
      fi
   done

   if [[ -z "$MODE" ]]; then
      echo "Error: No action mode specified." >&2
      usage
   fi
   case "$MODE" in list) files_to_list_args=("${remaining_args[@]}") ;; delete) files_to_delete_args=("${remaining_args[@]}") ;; upload) files_to_upload_args=("${remaining_args[@]}") ;; query) if [[ ${#remaining_args[@]} -gt 0 ]]; then echo "Warning: Extra positional args ignored for --query." >&2; fi ;; esac

   local -a temp_args
   local id_arg
   if [[ "$MODE" == "list" ]]; then
      temp_args=()
      for id_arg in "${files_to_list_args[@]}"; do if [[ "$id_arg" == files/* || "$id_arg" =~ ^[a-zA-Z0-9._-]+$ ]]; then
         if [[ "$id_arg" != files/* ]]; then id_arg="files/$id_arg"; fi
         temp_args+=("$id_arg")
      else echo "Warn: Skip ID '$id_arg' for --list." >&2; fi; done
      files_to_list_args=("${temp_args[@]}")
      unset temp_args
   elif [[ "$MODE" == "delete" ]]; then
      temp_args=()
      for id_arg in "${files_to_delete_args[@]}"; do if [[ "$id_arg" == files/* || "$id_arg" =~ ^[a-zA-Z0-9._-]+$ ]]; then
         if [[ "$id_arg" != files/* ]]; then id_arg="files/$id_arg"; fi
         temp_args+=("$id_arg")
      else echo "Warn: Skip ID '$id_arg' for --delete." >&2; fi; done
      files_to_delete_args=("${temp_args[@]}")
      unset temp_args
   fi
   if [[ "$MODE" == "query" && -n "$file_to_query" ]]; then if [[ "$file_to_query" != files/* && "$file_to_query" != https://*/* && "$file_to_query" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      file_to_query="files/$file_to_query"
      [[ "$VERBOSE" -eq 1 ]] && echo "Normalized query ID to: $file_to_query" >&2
   elif [[ "$file_to_query" != files/* && "$file_to_query" != https://*/* ]]; then
      echo "E: Invalid format for --query: $file_to_query" >&2
      usage
   fi; fi

   if [[ "$MODE" == "query" && -z "$query_file_path" ]]; then
      echo "Error: --query mode requires --query-file." >&2
      usage
   fi
   if [[ "$MODE" == "upload" && ${#files_to_upload_args[@]} -eq 0 ]]; then
      echo "Error: --upload requires at least one filepath argument." >&2
      usage
   fi
   if [[ "$MODE" == "query" && -z "$file_to_query" ]]; then
      echo "Error: --query requires a file identifier argument." >&2
      usage
   fi
   if [[ "$MODE" != "query" && -n "$query_file_path" ]]; then
      echo "Error: --query-file only valid with --query." >&2
      usage
   fi
   if [[ "$MODE" != "query" && -n "$thinking_level" ]]; then
      echo "Error: --thinking-level only valid with --query." >&2
      usage
   fi
   if [[ "$MODE" != "query" && -n "$model_name" ]]; then
      echo "Error: --model only valid with --query." >&2
      usage
   fi
   if [[ "$MODE" != "query" && "$output_json_flag" -eq 1 ]]; then
      echo "Error: --json-output only valid with --query." >&2
      usage
   fi
   if [[ "$MODE" != "query" && -n "$max_output_tokens_arg" ]]; then
      echo "Error: --max-tokens only valid with --query." >&2
      usage
   fi # Added validation

}

# --- Main Script Logic ---

# Parse command line arguments first
parse_arguments "$@"

# Now determine API key
determine_api_key
key_exit_status=$?
if [[ $key_exit_status -ne 0 ]]; then
   exit $key_exit_status
fi

# Setup Trap for Script Exit (AFTER parsing and key check, BEFORE execution)
trap cleanup EXIT ERR INT TERM

# Execute action based on mode
exit_status=0 # Default exit status

case "$MODE" in
   list)
      run_mode_list
      exit_status=$?
      ;;
   delete)
      run_mode_delete
      exit_status=$?
      ;;
   upload)
      run_mode_upload
      exit_status=$?
      ;;
   query)
      run_mode_query
      exit_status=$?
      ;;
   *)
      echo "Error: Unknown mode '$MODE'." >&2
      usage
      ;; # Safeguard
esac

exit $exit_status
