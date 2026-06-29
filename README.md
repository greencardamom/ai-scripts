# ai-scripts

Provider **adapter scripts** for talking to LLM backends — each takes a prompt (and optionally a
PDF/document), calls one provider, and returns JSON. These are the "channels" that higher-level
tools dispatch to via config.

One subdirectory per tool. Each is symlinked into `~/scripts/` (on `$PATH`), so consumers reference
the stable `~/scripts/<tool>.sh` path and never the repo location directly.

| Tool | Backend | Notes |
|------|---------|-------|
| `gemini-query/` | Google Gemini API | prompt → JSON; supports `--ground` (Google-Search grounding) |
| `gemini-files/` | Gemini Files API | upload a doc + query it (large-PDF attach) |
| `gemini-rag/`   | Gemini + retrieval | RAG helper (`.sh` + `.py` + `.cfg`) |
| `claude-query/` | Anthropic Claude | `--via api` (metered) or `--via claudecode` (Claude Code subscription) |
| `antigravity-query/` | Antigravity (`agy`) | flat-rate proxy to Gemini/Claude/GPT; exit `3`=5h cap, `4`=weekly cap |

## Conventions
- **Secrets** are never stored here — each script reads its key from a keyfile (e.g. `-k <keyfile>`).
- **Symlinks:** `~/scripts/<tool>.sh -> <repo path>/<tool>/<tool>.sh`, created per host so each
  resolves against that host's own `$HOME`.
- **Consumers reference `~/scripts/<tool>.sh`** (the stable symlink), so moving files within the repo never breaks them.

