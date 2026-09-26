#!/bin/bash

# Dependencies
# python3 -m pip install google-generativeai tqdm
# python3 -m pip install --upgrade google-genai

# --- Wrapper for gemini-rag.py ---

# readlink -f so the config is found next to the real script, not next to a symlink
SCRIPT_DIR="$( cd "$( dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" &> /dev/null && pwd )"
CONFIG_FILE="$SCRIPT_DIR/gemini-rag.cfg"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    echo "       Copy gemini-rag.cfg.example to gemini-rag.cfg and edit it."
    exit 1
fi

source "$CONFIG_FILE"

# gemini-rag.py ships beside this script, so the checkout location is not config.
GEMINI_RAG_SCRIPTS_DIR="${GEMINI_RAG_SCRIPTS_DIR:-$SCRIPT_DIR}"

if [ -z "${GEMINI_RAG_VENV_ACTIVATE:-}" ]; then
    echo "Error: GEMINI_RAG_VENV_ACTIVATE is not set in the config file."
    exit 1
fi

# --- Script Execution ---

PYTHON_SCRIPT_NAME="gemini-rag.py"
TARGET_PYTHON_SCRIPT="$GEMINI_RAG_SCRIPTS_DIR/$PYTHON_SCRIPT_NAME"

if [ ! -f "$TARGET_PYTHON_SCRIPT" ]; then
    echo "Error: Python script not found: $TARGET_PYTHON_SCRIPT"
    exit 1
fi

if [ ! -f "$GEMINI_RAG_VENV_ACTIVATE" ]; then
    echo "Error: Virtual environment activate script not found: $GEMINI_RAG_VENV_ACTIVATE"
    exit 1
fi

# Activate and Run
source "$GEMINI_RAG_VENV_ACTIVATE"
python "$TARGET_PYTHON_SCRIPT" "$@"
