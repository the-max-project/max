# Fix: `assistant` crashes on every turn — "gemma3:4b does not support tools"

## Error

```
[ERROR] Reasoning engine crashed during execution: registry.ollama.ai/library/gemma3:4b does not support tools (status code: 400)
...
ollama._types.ResponseError: registry.ollama.ai/library/gemma3:4b does not support tools (status code: 400)
```

## Root cause chain

1. **`.env.dev:67`** sets `OLLAMA_MODEL_NAME=gemma3:4b`. This is the model `max-assistant` loads via `ChatOllama` (`services/max-assistant/src/max_assistant/clients/ollama_preloader.py:31`, wired up in `app_services.py:99`).
2. **`gemma3:4b` does not declare tool-calling ("tools") capability** in Ollama's model manifest/chat template. Ollama's `/api/chat` rejects any request that includes a `tools` payload for a model that doesn't advertise that capability — hence the 400.
3. **The reasoning graph always sends a `tools` payload for interactive turns.** In `services/max-assistant/src/max_assistant/agent/graph.py:66`:
   ```python
   llm_with_tools = llm.bind_tools(tools)
   ...
   chain = senior_assistant_prompt | llm_with_tools   # used for every non-background turn
   ```
   There is no check for whether the configured model actually supports tools — `bind_tools` is applied unconditionally, and `llm_with_tools` is the chain used for **every normal (non-background) conversational turn**.
4. **The failure is caught too broadly and too late.** `services/max-assistant/src/max_assistant/agent/agent.py:97` wraps the whole graph invocation in a blanket `except Exception`, logs it, and returns a generic `"I'm sorry, I encountered an error."` This means the crash isn't intermittent — since tools are bound on every interactive call, **100% of user turns fail** with this model configured, and the only visible symptom to the user is a generic error message with the real cause buried in the container logs.
5. **Systemic gap — this isn't unique to gemma3:4b.** The fallback defaults elsewhere in the codebase have the same problem:
   - `docker-compose.yaml:75` → `OLLAMA_MODEL_NAME=${OLLAMA_MODEL_NAME:-llama3}`
   - `services/max-assistant/src/max_assistant/config.py:72` → `OLLAMA_MODEL_NAME = os.getenv("OLLAMA_MODEL_NAME", "llama3")`

   Plain `llama3` (the original Llama 3, not 3.1) also lacks tool-calling support in Ollama's library. So an unset `OLLAMA_MODEL_NAME` in any environment hits the exact same crash. Nothing in the codebase validates that the configured model actually supports tool calling before wiring it into the tool-bound chain.

## Fix plan

### 1. Immediate: switch the dev model to one that supports tools
- Update `.env.dev` (and audit `.env` for prod) `OLLAMA_MODEL_NAME` to a model confirmed to support tool calling in Ollama, e.g. `qwen3:4B` or `llama3.1:8b-instruct-q4_K_M` (both already listed in the `.env.dev` comment block, and both are Ollama-official models with tool-calling templates).
- Before committing to a model, verify locally: `ollama show <model>` and confirm `tools` appears in the reported capabilities. Do this for whichever model is finally chosen — do not assume from the name/family alone (e.g. base `gemma3`/`llama3` do not support tools; their `.1`/instruct-tuned Ollama variants may differ).
- Annotate the `.env` / `.env.dev` model comment block with a `tools: yes/no` note per model so future swaps don't regress this.

### 2. Fail fast at startup instead of on the first user turn
- In `AppServices._initialize_clients` (`app_services.py`) or `create_llm_instance` (`ollama_preloader.py`), add a one-time capability check against the Ollama `/api/show` endpoint for `active_model` right after the `ChatOllama` instance is created.
- If the model doesn't report `tools` capability, raise a clear, actionable startup error (e.g. `RuntimeError(f"Configured model '{active_model}' does not support tool calling, required by the assistant's reasoning graph. Choose a tool-capable model.")`) instead of letting the container come up "healthy" and fail on every conversation turn.

### 3. Defensive fallback in the reasoning graph (optional but recommended)
- In `create_reasoning_engine` (`graph.py`), catch the specific `ollama._types.ResponseError` case (or use the capability check from step 2) and, if tools aren't supported, log a loud warning and fall back to `llm_with_tools = llm` (i.e. skip `bind_tools`) so the assistant still responds in a degraded, tool-less mode rather than crashing every turn.
- This is a safety net for cases where step 2's check is bypassed (e.g. model swapped at runtime, Ollama upgraded/downgraded its template support) — the assistant should degrade gracefully, not go fully non-functional.

### 4. Regression coverage
- Add a unit test that asserts engine creation raises (or degrades, depending on 2 vs 3) when given a `ChatOllama` stub reporting no `tools` capability, so this class of misconfiguration is caught in CI rather than in a running container's logs.

## Priority
Step 1 unblocks the current dev environment immediately. Steps 2–4 prevent this from silently recurring the next time someone changes `OLLAMA_MODEL_NAME`.

---

## Update (2026-09-16): recurrence + fix applied

After the above, `OLLAMA_MODEL_NAME` was changed to `gemma4:12b`, which produced a second, related crash on every turn:

```
ollama._types.ResponseError: model 'gemma4:12b' not found (status code: 404)
```

Root cause: `gemma4:12b` was never pulled into the local Ollama instance (`ollama list` shows only `gemma3:4b` and `llama3.1:8b-instruct-q4_K_M` present). The `.env.dev` comment block's `gemma4:*` entries appear to be mistyped/unverified model tags (Ollama's real families at time of writing are `gemma3` and `gemma3n`, e.g. `gemma3:12b`, `gemma3n:e4b`) and were never validated before being pulled into `OLLAMA_MODEL_NAME`. This is the same underlying gap as before: nothing validates the configured model before it's wired into the tool-bound reasoning chain.

**Applied fixes:**
- `.env.dev`: `OLLAMA_MODEL_NAME` set to `llama3.1:8b-instruct-q4_K_M` — already pulled locally and confirmed via `ollama show` to report `Capabilities: completion, tools`. Added an inline note warning that the `gemma4:*` entries in the comment block are unverified.
- Implemented step 2 from the original plan: `services/max_assistant/clients/ollama_preloader.py` now has `validate_model_capabilities(model_name, base_url, required_capabilities=("tools",))`, called from `create_llm_instance` before the `ChatOllama` instance is handed off. It calls `ollama.Client(host=base_url).show(model_name)` and raises a `RuntimeError` with an actionable message if:
  - the model isn't found/pulled (surfaces the same 404 as above, but at startup), or
  - the model doesn't report `tools` in its capabilities (surfaces the same class of error as the original `gemma3:4b` incident, but at startup).

  Verified against the live local Ollama instance: `llama3.1:8b-instruct-q4_K_M` passes, `gemma3:4b` and `gemma4:12b` are both now rejected immediately with clear errors instead of failing on the first user message.

**Still open:** `.env` (prod) has `OLLAMA_MODEL_NAME=gemma4:26B`, which is the same unverified tag pattern and will likely 404 the same way if that environment is ever started. Not changed here (production config) — verify with `ollama show gemma4:26B` (or replace with a confirmed-available tool-capable model) before deploying.
