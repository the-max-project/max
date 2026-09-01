# Implementation Plan: Fixing the ~20s STT Delay on Apple Silicon Dev Machines

## 1. Summary

On local macOS development machines (confirmed on an Apple M5, 24GB RAM, 10-core Docker Desktop VM), it takes roughly **20 seconds** from the end of a user's spoken utterance to the transcribed text ("[Me]: ...") appearing in the browser UI.

**Root cause:** `.env.dev` runs the `large-v3` Whisper model (1.5B params) on **CPU** via `faster-whisper`, artificially capped at **2 threads** (`services/max-stt/src/audio_processor.py:40-41`), because Apple's MLX/Metal GPU backend cannot run inside a Docker Desktop container (Docker Desktop containers run in a Linux VM with no Metal access — this is a hard OS-level limitation, not a config bug we can work around inside Docker).

This document lays out two implementation options, in enough detail to execute directly:

- **Option 1** — Right-size the containerized CPU path (small, low-risk, immediate).
- **Option 2** — Run STT natively on macOS via MLX, bypassing Docker for this one service (bigger lift, best possible performance, mirrors the existing native-Ollama pattern already used in this repo).

No code has been changed yet. This is the plan to review before implementation begins.

---

## 2. Current State (evidence)

| Fact | Source |
|---|---|
| Dev STT config: `large-v3` / `cpu` / `int8` | `.env.dev:58-62` |
| Container confirms this at runtime | `docker logs max-stt-1` → `Preparing model: large-v3 on device: cpu with compute_type: int8` |
| `faster_whisper.WhisperModel` hardcoded to 2 threads, 1 worker | `services/max-stt/src/audio_processor.py:36-42` |
| Docker VM has 10 CPUs available, container using ~0.2% at idle | `docker exec max-stt-1 nproc` → `10`; `docker stats` |
| Dockerfile *tries* to install `mlx-whisper` on ARM64 builds | `services/max-stt/Dockerfile` builder stage: `if [ "$ARCH" = "aarch64" ]... pip install mlx-whisper` |
| ...but it can never actually load at runtime in a container | `docker exec max-stt-1 python3 -c "import mlx_whisper"` → `ImportError: libmlx.so: cannot open shared object file` |
| Code silently falls back to `faster_whisper` when the `mlx_whisper` import fails | `services/max-stt/src/audio_processor.py:9-16` (`try: import mlx_whisper ... except ImportError: from faster_whisper import WhisperModel`) |
| Repo already has a native-macOS pattern for another GPU-bound service (Ollama) | `.env.dev:11-16` — `OPTION A: M4 Mac-Mini (Apple Silicon) Native Setup`, `OLLAMA_BASE_URL=http://host.docker.internal:11434`; gated in `Makefile:43-59` |
| Assistant→STT connection URL is configurable but never overridden today | `services/max-assistant/src/max_assistant/config.py:79` → `STT_WEBSOCKET_URL = os.getenv("STT_WEBSOCKET_URL", "ws://stt/ws")`; not present in `docker-compose.yaml`'s `assistant` environment block (`docker-compose.yaml:80-90`), so it always resolves to the containerized `stt` service |
| `assistant` and `proxy` hard-depend on the `stt` container | `docker-compose.yaml:99-101` (`assistant depends_on: [stt, tts]`), `docker-compose.yaml:117-119` (`proxy depends_on: [stt, assistant]`) |

**Important implication of the Dockerfile finding:** the ARM64 branch that installs `mlx-whisper` inside the container is dead weight — MLX has no Linux build at all (not an ARM-vs-x86 issue), so it will *never* import successfully inside any Docker container, on any host chip. This isn't something Option 1 can fix; it's the reason Option 2 exists.

---

## 3. Goals / Non-Goals

**Goals**
- Cut the perceived voice→transcript latency from ~20s to a low-single-digit number of seconds on Apple Silicon dev machines.
- Keep production (`.env` / Linux+CUDA target) untouched — these changes are dev-machine-scoped (`.env.dev`, and dev-only compose overrides).
- Preserve the existing "Start Listening → speak → see transcript" UX; no client-side (VAD/UI) changes required for either option.

**Non-Goals**
- Not addressing the secondary latency contributors called out in the earlier root-cause analysis (per-connection TTS/LLM warmup, whole-utterance non-streaming VAD send, double VAD pass) — those are separate, smaller follow-ups if still relevant after this fix.
- Not changing the CUDA/production path (`.env`, `docker-compose.prod.yaml`) — that already uses GPU acceleration correctly.

---

## 4. Option 1 — Right-Size the Containerized CPU STT Path

### 4.1 Overview

Stay entirely inside Docker. Two independent levers:

1. **Smaller model** — swap `large-v3` for a CPU-appropriate size in `.env.dev`.
2. **More threads** — stop hardcoding `cpu_threads=2` / `num_workers=1`; make them configurable and set them to use most of the 10 available vCPUs.

### 4.2 Changes

**a) `services/max-stt/src/config.py`** — add two new env-driven settings:

```python
CPU_THREADS = int(os.environ.get("STT_CPU_THREADS", "2"))
NUM_WORKERS = int(os.environ.get("STT_NUM_WORKERS", "1"))
```

**b) `services/max-stt/src/audio_processor.py`** — read them instead of hardcoding:

```python
elif STT_BACKEND == "faster_whisper":
    logging.info("🟩 Using faster_whisper CUDA backend.")
    model_name = model_size.split('/')[-1].replace('faster-whisper-', '')
    return WhisperModel(
        model_name,
        device=device,
        compute_type=compute_type,
        cpu_threads=config.CPU_THREADS,
        num_workers=config.NUM_WORKERS,
    )
```
(Requires importing `config` in `audio_processor.py`, or passing the values in as `get_model()` args from `app.py`, which already imports `config`.)

**c) `.env.dev`** — right-size for this machine:

```dotenv
# -- STT (Speech-to-Text) Service Configuration --
STT_MODEL_SIZE=small
# "cuda" for GPU, "cpu" for CPU
STT_DEVICE=cpu
# "float16" for GPU, "int8" for CPU
STT_COMPUTE_TYPE=int8
STT_CPU_THREADS=6
STT_NUM_WORKERS=1
STT_LOG_LEVEL=info
```

`STT_CPU_THREADS=6` leaves ~4 vCPUs of the Docker VM's 10 for the `assistant`, `tts`, `proxy`, and `neo4j` containers running alongside it. `num_workers` controls *inter-op* parallelism (concurrent independent transcribe calls) — for a single active speaker there's no benefit to raising it above 1, since `cpu_threads` (intra-op) is what speeds up a single transcription.

**d) `docker-compose.yaml`** — pass the new vars through to the `stt` service's environment block (next to the existing `MODEL_SIZE`/`DEVICE`/`COMPUTE_TYPE` lines, `docker-compose.yaml:19-24`):

```yaml
        environment:
          - APP_NAME=stt
          - MODEL_SIZE=${STT_MODEL_SIZE:-large-v3}
          - DEVICE=${STT_DEVICE:-cuda}
          - COMPUTE_TYPE=${STT_COMPUTE_TYPE:-float16}
          - STT_CPU_THREADS=${STT_CPU_THREADS:-2}
          - STT_NUM_WORKERS=${STT_NUM_WORKERS:-1}
```

**e) Model choice — `small` vs `medium`:**

| Model | Params | Relative CPU speed vs large-v3 | Accuracy | Recommendation |
|---|---|---|---|---|
| `small` | 244M | ~6x faster | Good for clear speech; may miss some words from less-clear senior speech | Best for lowest latency — start here |
| `medium` | 769M | ~2x faster | Noticeably closer to `large-v3` accuracy | Use if `small`'s transcription quality is unacceptable for the target users (seniors with dementia) |

Recommendation: implement with `small` first, listen-test with a few real phrases, bump to `medium` only if accuracy is the bottleneck rather than latency.

### 4.3 Validation instrumentation (add alongside the fix)

Add timing around the actual transcription call so before/after numbers are objectively measurable, in `services/max-stt/src/audio_processor.py`:

```python
async def process_audio_chunk(model_instance, audio_chunk: bytes) -> str:
    ...
    async with transcription_semaphore:
        start = time.monotonic()
        transcription = await asyncio.to_thread(_sync_transcribe, model_instance, audio_np)
        logging.info(f"Transcription took {time.monotonic() - start:.2f}s for {len(audio_np)/16000:.2f}s of audio")
    ...
```
(`import time` at top of file.) This is cheap enough to leave in permanently — it's useful ongoing telemetry for this exact class of regression.

### 4.4 Implementation checklist

- [x] Add `STT_CPU_THREADS` / `STT_NUM_WORKERS` to `services/max-stt/src/config.py`
- [x] Update `get_model()` in `services/max-stt/src/audio_processor.py` to use them
- [x] Add the timing log line in `process_audio_chunk()`
- [x] Update `.env.dev` (`STT_MODEL_SIZE=small`, add `STT_CPU_THREADS=6`, `STT_NUM_WORKERS=1`)
- [x] Update `docker-compose.yaml`'s `stt` service environment block to pass the two new vars through
- [x] Rebuild the `stt` image and recreate the container with the new env vars
- [x] Confirm via `docker logs max-stt-1` that it now logs `Preparing model: small on device: cpu ...`
- [x] Feed a real speech sample directly to the STT service and confirm the new `Transcription took Xs` log line
- [x] Compare measured latency against the ~20s baseline

Implemented 2026-08-31 — see [`doc/dev-mac/LargeSttDelayWalkthru.md`](./LargeSttDelayWalkthru.md) for the full diff, commands run, and before/after measurement.

### 4.5 Rollback

Trivial — revert `.env.dev` to `STT_MODEL_SIZE=large-v3` and drop the two new vars (or leave them; they default back to the current hardcoded values of `2`/`1` if unset, so the code change alone is backward-compatible even without touching `.env.dev`). No data migration, no persistent state involved.

### 4.6 Effort & Risk

- **Effort:** ~1 hour (small, well-scoped code + config change).
- **Risk:** Low. Purely a dev-machine config change plus a backward-compatible code change (defaults preserve current behavior if env vars are unset). Production (`.env`) is untouched since it's a separate file.

---

## 5. Option 2 — Run STT Natively on macOS via MLX

### 5.1 Overview

Docker Desktop's Linux VM has no path to the Mac's Metal GPU/ANE, so MLX (Apple's accelerated ML framework) can only run **outside** Docker, directly on macOS. This mirrors the pattern this repo already uses for Ollama (`.env.dev:11-16`, `Makefile:43-59`): run the GPU-hungry service natively, and have the Dockerized services reach it over `host.docker.internal`.

The `mlx_whisper` code path already exists in `services/max-stt/src/audio_processor.py:9-31` and needs no logic changes — it's already what gets used automatically whenever `import mlx_whisper` succeeds, which only happens outside a container on macOS.

### 5.2 Architecture change

```
Before (all containerized):
  browser --wss--> nginx --> assistant (container) --ws--> stt (container, CPU, large-v3)

After (Option 2):
  browser --wss--> nginx --> assistant (container) --ws--> stt (native macOS process, MLX/Metal, large-v3)
                                                              via host.docker.internal:<port>
```

### 5.3 Changes

**a) New native run script — `services/max-stt/scripts/run_native_macos.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d .venv-native ]; then
    python3 -m venv .venv-native
fi
source .venv-native/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt mlx-whisper

export MODEL_SIZE="${STT_MODEL_SIZE:-large-v3}"
export DEVICE=mps          # unused by the mlx branch, kept for log clarity
export COMPUTE_TYPE=native # unused by the mlx branch, kept for log clarity
export UVICORN_HOST=0.0.0.0
export UVICORN_PORT="${STT_NATIVE_PORT:-8090}"

python -m uvicorn src.app:app --host "$UVICORN_HOST" --port "$UVICORN_PORT"
```

Since `import mlx_whisper` succeeds natively, `audio_processor.py`'s existing `try/except ImportError` block automatically selects the MLX backend — no code change needed here.

**b) `docker-compose.yaml`** — pass `STT_WEBSOCKET_URL` through to the `assistant` service (it's not currently forwarded at all, `docker-compose.yaml:80-90`):

```yaml
        environment:
          - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://ollama:11434}
          - OLLAMA_MODEL_NAME=${OLLAMA_MODEL_NAME:-llama3}
          - STT_WEBSOCKET_URL=${STT_WEBSOCKET_URL:-ws://stt/ws}
          - TTS_VOICE=${TTS_VOICE:-en_US-lessac-medium}
          ...
```

**c) Gate the containerized `stt` service behind a profile, and drop the hard dependency on it,** in a new dev-only override file — **`docker-compose.stt-native.yaml`**:

```yaml
services:
  stt:
    profiles: ["container-stt"]   # only starts if container-stt is in COMPOSE_PROFILES

  assistant:
    depends_on:
      - tts                        # stt removed — it's native, not a compose-managed service

  proxy:
    depends_on:
      - assistant                  # stt removed
```

This file is only added to the compose command when native STT mode is active (see Makefile change below), so it has zero effect on production or on developers who haven't opted in.

**d) `.env.dev`** — add a mode switch and point the assistant at the native STT process:

```dotenv
# ------------------------------------------------------------------------------
# OPTION A: M4 Mac-Mini (Apple Silicon) Native Setup
# ------------------------------------------------------------------------------
STT_BASE_IMAGE=python:3.11-slim-bookworm
COMPOSE_PROFILES=local-only
OLLAMA_BASE_URL=http://host.docker.internal:11434

# Set to "native" to run STT outside Docker via MLX (see doc/dev-mac/LargeSttDelayPlan.md).
# Leave unset/anything else to keep using the containerized CPU STT service.
STT_MODE=native
STT_NATIVE_PORT=8090
STT_WEBSOCKET_URL=ws://host.docker.internal:8090/ws

# -- STT (Speech-to-Text) Service Configuration --
# Only used when STT_MODE is not "native" (containerized path):
STT_MODEL_SIZE=large-v3
STT_DEVICE=cpu
STT_COMPUTE_TYPE=int8
STT_LOG_LEVEL=info
```

Note `STT_MODEL_SIZE=large-v3` can stay as-is for the native path — MLX on an M5 can handle it at usable speed, so there's no need to trade accuracy for latency the way Option 1 does.

**e) `Makefile`** — mirror the existing `HAS_CONTAINER_OLLAMA` pattern to conditionally add the override file and skip the containerized STT service message:

```make
# Native STT (MLX on macOS) support — mirrors the native-Ollama pattern above.
DEV_STT_NATIVE := $(shell grep -E '^STT_MODE=native' .env.dev 2>/dev/null)

ifneq ($(DEV_STT_NATIVE),)
	DEV_COMPOSE += -f docker-compose.stt-native.yaml
endif
```

```make
## Build and start the development containers
dev: shared
ifneq ($(DEV_STT_NATIVE),)
	@echo "STT_MODE=native detected -- run 'make stt-native' in a separate terminal before/while using the app."
endif
	$(DEV_COMPOSE) up

## Run the STT service natively (MLX/Metal) — required when STT_MODE=native in .env.dev
stt-native:
	./services/max-stt/scripts/run_native_macos.sh
```

Developer workflow becomes: `make dev` in one terminal, `make stt-native` in another (or a background process/launchd plist if you want it always running — see Operational Notes below).

### 5.4 Operational notes

- **Process lifecycle:** Docker Compose won't manage the native process's start/stop/restart. Simplest: run `make stt-native` in a dedicated terminal tab while developing. If persistent background operation is wanted later, a `launchd` user agent (`~/Library/LaunchAgents/com.max.stt-native.plist`) can wrap the same script — not needed for initial rollout.
- **Model cache location:** natively, Hugging Face/MLX models cache to `~/.cache/huggingface` on the Mac's real filesystem (fast, no Docker volume virtualization overhead) rather than the `model_cache` Docker volume the container uses — expect one clean re-download the first time.
- **Health checks:** the containerized `stt` service's Compose healthcheck (`docker-compose.yaml:32-38`) disappears along with the container when `container-stt` isn't in the active profile — no action needed, but be aware `docker compose ps` won't show STT health status anymore; use `curl http://localhost:8090/health` against the native process instead.
- **Firewall prompt:** macOS will likely prompt to allow incoming network connections to the Python process the first time it binds `0.0.0.0:8090` — accept it (needed for the container→host connection).

### 5.5 Implementation checklist

- [x] Add `services/max-stt/scripts/run_native_macos.sh` (executable: `chmod +x`)
- [x] Add `STT_WEBSOCKET_URL` passthrough to `assistant` in `docker-compose.yaml`
- [x] Add new `docker-compose.stt-native.yaml` override (profile-gate `stt`, trim `depends_on` on `assistant`/`proxy`) — required a `required: false` long-form fix, not the plan's original shorter-list approach (see walkthrough)
- [x] Add `STT_MODE`, `STT_NATIVE_PORT`, `STT_WEBSOCKET_URL` to `.env.dev`
- [x] Add `DEV_STT_NATIVE` detection + conditional compose file + `stt-native` target to `Makefile`
- [x] Run `make stt-native` once manually, confirm `🍎 Using MLX backend` in its console output and `curl http://localhost:8090/health` returns healthy
- [x] Run `make dev`, confirm the containerized `stt` service does **not** start (`docker compose ps` / `docker ps`)
- [x] Confirm transcripts appear quickly and correctly (scripted client, real client protocol — browser automation unavailable this session)
- [x] Confirm `assistant`'s logs show it connected to `ws://host.docker.internal:8090/ws` (not `ws://stt/ws`)

Implemented 2026-08-31 — see [`doc/dev-mac/LargeSttDelayWalkthru.md`](./LargeSttDelayWalkthru.md) (Part 2) for the full diff, commands run, and before/after measurement. Measured warm-model latency: **0.90s** for `large-v3` on native MLX vs. 1.84s for Option 1's `small`-on-CPU and ~20s for the original `large-v3`-on-CPU setup.

### 5.6 Rollback

Set `STT_MODE` in `.env.dev` back to anything other than `native` (or delete the line) and stop the native process. `make dev` will then resolve `DEV_STT_NATIVE` to empty, drop the override file, and the containerized `stt` service (with its normal `depends_on` wiring) returns exactly as it was. No file needs to be deleted to roll back — it's purely additive and gated.

### 5.7 Effort & Risk

- **Effort:** ~3-4 hours (new script, new compose override, Makefile plumbing, end-to-end testing of the two-process dev workflow).
- **Risk:** Medium. More moving parts than Option 1 (a process outside Compose's lifecycle management, a new override file, `depends_on` surgery). Contained risk, though: everything is additive and dev-only (`.env.dev`, a new compose override, a new script) — production and the default containerized path are unaffected, and rollback is a one-line env change.

---

## 6. Recommended Rollout Sequence

1. **Now:** Ship Option 1. It's small, low-risk, and should already take the delay from ~20s down to low single digits on this machine.
2. **Measure:** Use the added timing log (`Transcription took Xs...`) to confirm the actual improvement and decide whether `small` is accurate enough or `medium` is needed.
3. **Later, if still not fast/accurate enough:** Layer in Option 2 to get native GPU acceleration and be able to run `large-v3` at low latency, without giving up accuracy. Because Option 2 is purely additive (new files + a `.env.dev` switch), it can be picked up independently at any time without re-touching Option 1's work.

---

## 7. Success Metrics

- Time from end-of-speech (VAD "Speech ended" console log in the browser) to `[Me]: ...` text appearing in the chat pane: target **< 5s** (down from ~20s).
- No regression in transcription accuracy that materially affects usability for the target users (seniors with dementia) — spot-check with a handful of representative phrases before/after.
- No change in behavior for the production (`.env` / CUDA) deployment path.

## 8. Open Questions

- Is `small` model accuracy acceptable for this project's target users, or should `medium` be the Option 1 default from the start? (Needs a quick listening test — not answerable from code alone.)
- Is a native background process (Option 2) acceptable operationally for this developer's workflow, or is "one extra terminal tab" friction enough to just standardize on Option 1 for local dev and reserve full `large-v3` accuracy for the CUDA-backed production/staging environment?
