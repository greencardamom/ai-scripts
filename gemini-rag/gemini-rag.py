#!/usr/bin/env python3
import os
import sys
import argparse
import json
import time
import mimetypes
import glob
from tqdm import tqdm
from google import genai
from google.genai import types

# --- Configuration Constants ---
CONFIG_DIR = os.path.expanduser("~/.config/gemini-rag")
STORES_FILE = os.path.join(CONFIG_DIR, "stores.json")

# Default Models
DEFAULT_HARVESTER = "gemini-2.5-pro" 
DEFAULT_AUTHOR = "gemini-2.5-pro"

# --- Infrastructure Functions ---

def setup_client(key_file=None):
    api_key = None
    if key_file:
        try:
            with open(key_file, 'r') as f:
                api_key = f.read().strip()
        except Exception as e:
            print_error(f"Error reading keyfile: {e}")
    else:
        api_key = os.environ.get("GEMINI_API_KEY")

    if not api_key:
        print_error("No API Key found. Set GEMINI_API_KEY or use --keyfile.")
    
    return genai.Client(api_key=api_key)

def load_stores():
    if not os.path.exists(CONFIG_DIR):
        os.makedirs(CONFIG_DIR)
    if not os.path.exists(STORES_FILE):
        with open(STORES_FILE, 'w') as f:
            json.dump({}, f)
        return {}
    try:
        with open(STORES_FILE, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def save_stores(data):
    with open(STORES_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def print_error(msg):
    print(f"\033[91m[ERROR] {msg}\033[0m")
    sys.exit(1)

def print_info(msg):
    print(f"\033[94m[INFO] {msg}\033[0m")

def print_success(msg):
    print(f"\033[92m{msg}\033[0m")

# --- Command Implementations ---

def cmd_list_models(client, args):
    try:
        for m in client.models.list():
            print(m.name)
    except Exception as e:
        print_error(f"Failed to list models: {e}")

def cmd_create_store(client, args):
    stores = load_stores()
    if args.create_store in stores:
        print_error(f"Store '{args.create_store}' already exists.")
    stores[args.create_store] = []
    save_stores(stores)
    print_success(f"Created store: {args.create_store}")

def cmd_delete_store(client, args):
    stores = load_stores()
    if args.delete_store not in stores:
        print_error(f"Store '{args.delete_store}' not found.")
    del stores[args.delete_store]
    save_stores(stores)
    print_success(f"Deleted store: {args.delete_store}")

def cmd_delete_file(client, args):
    if not args.store:
        print_error("--store <id> is required to delete a file.")
    stores = load_stores()
    if args.store not in stores:
        print_error(f"Store '{args.store}' not found.")
    
    original_count = len(stores[args.store])
    stores[args.store] = [
        f for f in stores[args.store] 
        if args.delete_file not in f['name'] and args.delete_file not in f['uri']
    ]
    if len(stores[args.store]) < original_count:
        save_stores(stores)
        print_success(f"Removed file '{args.delete_file}' from store '{args.store}'.")
    else:
        print_error(f"File '{args.delete_file}' not found in store.")

def cmd_list_stores(client, args):
    stores = load_stores()
    print_info("Available Stores:")
    for store in stores:
        print(f" - {store} ({len(stores[store])} files)")

def cmd_list_files(client, args):
    if not args.store:
        print_error("--store <id> is required to list files.")
    stores = load_stores()
    if args.store not in stores:
        print_error(f"Store '{args.store}' not found.")
    print_info(f"Files in '{args.store}':")
    for f in stores[args.store]:
        print(f" - {f['name']} ({f['mime']})")

def cmd_upload(client, args):
    if not args.store:
        print_error("--store <id> is required for upload.")
    stores = load_stores()
    if args.store not in stores:
        print_error(f"Store '{args.store}' does not exist.")

    files_to_upload = []
    for pattern in args.upload:
        files_to_upload.extend(glob.glob(pattern))
    
    if not files_to_upload:
        print_error("No files found matching patterns.")

    print_info(f"Batch processing {len(files_to_upload)} files...")
    for file_path in files_to_upload:
        if not os.path.isfile(file_path):
            continue
        mime_type, _ = mimetypes.guess_type(file_path)
        if not mime_type:
            mime_type = "application/octet-stream"
        print(f"Uploading: {os.path.basename(file_path)} ({mime_type})...")
        try:
            uploaded_file = client.files.upload(file=file_path, config={'mime_type': mime_type})
            file_entry = {
                "uri": uploaded_file.uri,
                "mime": mime_type, 
                "name": uploaded_file.name
                "display_name": uploaded_file.display_name
            }
            stores[args.store].append(file_entry)
            print_success(f"  -> Success: {uploaded_file.uri}")
        except Exception as e:
            print(f"\033[91m  -> Failed: {e}\033[0m")
    save_stores(stores)

# --- The Core Engine: Deep Research (Two-Stage RAG) ---

def harvest_info(client, model_name, file_data, query, index):
    prompt = (
        f"You are a strict Research Assistant. \n"
        f"Do NOT rewrite the user's essay. Do NOT verify the user's essay yet.\n"
        f"Your ONLY job is to extract raw data from the provided document.\n\n"
        f"--- METADATA INJECTION ---\n"
        f"FILENAME: {fname}\n"
        f"Use this filename to infer the date, newspaper, and page number for citations.\n\n"
        f"--- TASK 1: IDENTIFY SOURCE ---\n"
        f"Scan the document header/title page. Create a Wikipedia citation template.\n"
        f"Format: [METADATA]: {{{{cite ...}}}}\n\n"
        f"--- TASK 2: EXTRACT RAW FACTS ---\n"
        f"Scan the document for names, dates, and events mentioned in the User's Essay below.\n"
        f"Extract the EXACT sentences from the document.\n"
        f"Output as bullet points. End each with [Source {index}].\n"
        f"If the document has no relevant text, output 'NO RELEVANT DATA'.\n\n"
        f"=== USER DRAFT ESSAY (REFERENCE ONLY - DO NOT OUTPUT THIS) ===\n"
        f"\"{query}\""
    )
    
    file_part = types.Part.from_uri(file_uri=file_data['uri'], mime_type=file_data['mime'])
    
    for attempt in range(5):
        try:
            response = client.models.generate_content(
                model=model_name,
                contents=[file_part, prompt]
            )
            # FIX 1: Handle None response (Safety Block)
            if response.text is None:
                return "[No Text Generated - Safety/Recitation]"
            return response.text
        except Exception as e:
            e_str = str(e).lower()
            # FIX: Detect Expired Files (403/404)
            if "403" in e_str or "404" in e_str or "permission" in e_str or "not found" in e_str:
                return "__EXPIRED__"
            elif "429" in str(e):
                wait = (attempt + 1) * 10
                time.sleep(wait)
            else:
                return f"[{e}]"
    return "[Failed]"

def perform_query(client, args):
    if not args.store:
        print_error("--store <id> is required to query.")
    stores = load_stores()
    files = stores.get(args.store, [])
    if not files:
        print_error(f"Store '{args.store}' is empty or missing.")

    query_text = args.query
    if args.query_file:
        with open(args.query_file, 'r') as f:
            query_text = f.read().strip()
    if not query_text:
        print_error("No query provided.")

    # --- PHASE 1: HARVESTING OR CACHE LOADING ---
    compiled_notes = ""
    
    if args.notes_file and os.path.exists(args.notes_file):
        print_info(f"--- LOADING NOTES FROM: {args.notes_file} ---")
        with open(args.notes_file, 'r') as f:
            compiled_notes = f.read()
        print_success(f"Loaded {len(compiled_notes)} chars of research notes.")

    else:
        print_info(f"--- PHASE 1: HARVESTING ({len(files)} docs) using {args.harvester_model} ---")
        research_notes = []
        files_to_prune = []

        for i, f in enumerate(tqdm(files), 1):
            result = harvest_info(client, args.harvester_model, f, query_text, i)
            
            # FIX: Handle Expired Files
            if result == "__EXPIRED__":
                sys.stderr.write(f"\n\033[93m[WARN] File '{f.get('name', 'unknown')}' (Source {i}) is missing/expired on Google. Removing from local cache.\033[0m\n")
                files_to_prune.append(f)
                continue

            # FIX 2: Check if result exists before checking contents
            if result and "NO RELEVANT DATA" not in result and "404" not in result: 
                if args.verbose:
                    tqdm.write(f"  -> Found info in Source {i}")
                research_notes.append(f"--- SOURCE {i} ({f.get('name', 'unknown')}) ---\n{result}\n")
            
            # FIX 3: Save Incrementally (so crashes don't lose data)
            if args.notes_file:
                with open(args.notes_file, 'w') as cache_f:
                    cache_f.write("\n".join(research_notes))
            
            time.sleep(2) 

        # Clean up local store if files were expired
        if files_to_prune:
            original_len = len(stores[args.store])
            stores[args.store] = [f for f in stores[args.store] if f not in files_to_prune]
            save_stores(stores)
            print_info(f"Removed {len(files_to_prune)} expired files from local store.")

        if not research_notes:
            print_info("No relevant data found (or API errors occurred).")
            return

        compiled_notes = "\n".join(research_notes)

    # --- STOP HERE IF REQUESTED ---
    if args.harvest_only:
        print_success("Harvest complete. Exiting (--harvest-only).")
        return

    # --- PHASE 2: AUTHORING ---
    print_info(f"--- PHASE 2: SYNTHESIS ({args.model}) ---")
    
    history_context = ""
    if args.history_file and os.path.exists(args.history_file):
        try:
            with open(args.history_file, 'r') as f:
                hist_data = json.load(f)
                history_context = "\nPREVIOUS CONVERSATION:\n" + "\n".join(
                    [f"{h['role'].upper()}: {h['parts'][0]['text']}" for h in hist_data[-5:]]
                )
        except:
            pass

    final_prompt = (
        f"You are a helpful research assistant. \n"
        f"Below are Research Notes extracted from source documents. \n"
        f"The user has a specific task regarding these notes and their draft essay.\n\n"
        f"=== RESEARCH NOTES (SOURCE MATERIAL) ===\n"
        f"{compiled_notes}\n\n"
        f"=== USER INSTRUCTIONS ===\n"
        f"{query_text}\n\n" 
    )
    
    try:
        response = client.models.generate_content(
            model=args.model,
            contents=final_prompt
        )
        print("\n" + "="*40 + "\nRESPONSE\n" + "="*40 + "\n")
        print(response.text)
        
        if args.history_file:
            new_turn = [
                {"role": "user", "parts": [{"text": query_text}]},
                {"role": "model", "parts": [{"text": response.text}]}
            ]
            curr_hist = []
            if os.path.exists(args.history_file):
                with open(args.history_file, 'r') as f:
                    curr_hist = json.load(f)
            curr_hist.extend(new_turn)
            with open(args.history_file, 'w') as f:
                json.dump(curr_hist[-20:], f, indent=2)
                
    except Exception as e:
        print_error(f"Synthesis failed: {e}")
        with open("crash_notes_backup.txt", "w") as f:
            f.write(compiled_notes)
        print_info("Saved research notes to crash_notes_backup.txt")

def main():
    parser = argparse.ArgumentParser(description="Gemini Deep Research CLI v4.2")
    parser.add_argument("--create-store", help="Create a new store")
    parser.add_argument("--delete-store", help="Delete a store")
    parser.add_argument("--delete-file", help="Remove a file from a store")
    parser.add_argument("--upload", nargs='+', help="Upload files to a store")
    parser.add_argument("--query", help="Query string")
    parser.add_argument("--query-file", help="File containing query")
    parser.add_argument("--list-stores", action="store_true", help="List all stores")
    parser.add_argument("--list-files", action="store_true", help="List files in a store")
    parser.add_argument("--list-models", action="store_true", help="List available API models")
    parser.add_argument("--store", help="Target Store ID")
    parser.add_argument("--model", default=DEFAULT_AUTHOR, help=f"Model for synthesis (Default: {DEFAULT_AUTHOR})")
    parser.add_argument("--harvester-model", default=DEFAULT_HARVESTER, help=f"Model for file scanning (Default: {DEFAULT_HARVESTER})")
    parser.add_argument("--notes-file", help="Path to save/load research notes")
    parser.add_argument("--keyfile", help="Path to API key file")
    
    # NEW ARGUMENT
    parser.add_argument("--harvest-only", action="store_true", help="Stop after harvesting/caching, do not run synthesis")
    
    parser.add_argument("--history-file", help="Path to history JSON")
    parser.add_argument("--cite-format", default="wikipedia", help="Citation format")
    parser.add_argument("--cite-location", default="sentence", help="Citation location")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logging")
    parser.add_argument("--json-output", action="store_true", help="Output raw JSON")

    args = parser.parse_args()
    client = setup_client(args.keyfile)

    if args.list_models:
        cmd_list_models(client, args)
    elif args.create_store:
        cmd_create_store(client, args)
    elif args.delete_store:
        cmd_delete_store(client, args)
    elif args.delete_file:
        cmd_delete_file(client, args)
    elif args.list_stores:
        cmd_list_stores(client, args)
    elif args.list_files:
        cmd_list_files(client, args)
    elif args.upload:
        cmd_upload(client, args)
    elif args.query or args.query_file:
        perform_query(client, args)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
