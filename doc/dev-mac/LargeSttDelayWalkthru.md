# Walkthrough: Fixing the Mac Dev-Machine STT Delay (Options 1 & 2)

This is a record of what was actually done to implement both options from
[`LargeSttDelayPlan.md`](./LargeSttDelayPlan.md) on 2026-08-31 — every file changed, every command
run, and the measured before/after results. No client-side (VAD/UI) or production (`.env` /
`docker-compose.prod.yaml`) files were touched by either option.

- **Part 1 — Option 1:** right-size the containerized CPU STT path (`small` model, more threads).
- **Part 2 — Option 2:** run STT natively on macOS via MLX/Metal, bypassing Docker entirely.

Both were implemented in sequence on the same machine; Part 2 supersedes Part 1 as the active
configuration (`.env.dev`'s `STT_MODE=native`), but Part 1's containerized path is left fully
intact and functional as the fallback (see Part 2 §6 Rollback).

---

# Part 1 — Option 1: Right-Size the Containerized CPU STT Path

## 0. Starting point

Before this change, `docker logs max-stt-1` showed:

```
Preparing model: large-v3 on device: cpu with compute_type: int8
🟩 Using faster_whisper CUDA backend.
```

`services/max-stt/src/audio_processor.py` hardcoded `cpu_threads=2, num_workers=1` regardless of
the host's actual CPU budget (10 vCPUs available to the Docker Desktop VM on this machine). This
combination — a 1.5B-parameter model, CPU inference, only 2 threads — is what produced the
observed ~20s delay between end-of-speech and the transcript appearing in the browser UI.

## 1. Code changes

### 1.1 `services/max-stt/src/config.py`

Added two new env-driven settings, following the existing pattern in this file (`MODEL_SIZE`,
`DEVICE`, `COMPUTE_TYPE`):

```diff
 MODEL_SIZE = os.environ.get("MODEL_SIZE", "base")
 DEVICE = os.environ.get("DEVICE", "cpu")
 COMPUTE_TYPE = os.environ.get("COMPUTE_TYPE", "int8")
+CPU_THREADS = int(os.environ.get("STT_CPU_THREADS", "2"))
+NUM_WORKERS = int(os.environ.get("STT_NUM_WORKERS", "1"))
 HOST = os.environ.get("UVICORN_HOST", "localhost" )
 PORT = int(os.environ.get( "UVICORN_PORT", 80))
```

Defaults (`2` / `1`) match the previous hardcoded values, so this alone is a no-op unless the new
env vars are set — it's purely additive.

### 1.2 `services/max-stt/src/audio_processor.py`

Two changes:

**a) `get_model()` now accepts `cpu_threads`/`num_workers` instead of hardcoding them**, and logs
what it was actually given (useful for exactly this kind of "why is it slow" debugging in the
future):

```diff
-def get_model(model_size: str, device: str, compute_type: str):
+def get_model(model_size: str, device: str, compute_type: str, cpu_threads: int = 2, num_workers: int = 1):
     """Loads or prepares the model based on the active hardware backend."""
     if STT_BACKEND == "mlx":
         ...
     elif STT_BACKEND == "faster_whisper":
-        logging.info("🟩 Using faster_whisper CUDA backend.")
+        logging.info(
+            f"🟩 Using faster_whisper CUDA backend. cpu_threads={cpu_threads}, num_workers={num_workers}"
+        )
         model_name = model_size.split('/')[-1].replace('faster-whisper-', '')
         return WhisperModel(
             model_name,
             device=device,
             compute_type=compute_type,
-            cpu_threads=2,
-            num_workers=1,
+            cpu_threads=cpu_threads,
+            num_workers=num_workers,
         )
```

The function signature keeps `cpu_threads=2, num_workers=1` as defaults, so any other caller (e.g.
tests) that doesn't pass them keeps today's behavior.

**b) `process_audio_chunk()` now times the actual transcription call** and logs it at `INFO`
level — this is the validation instrumentation from the plan, kept permanently since it's cheap
and directly useful for spotting this class of regression again:

```diff
 import asyncio
 import logging
+import time
 import numpy as np
 ...
         # Offload the blocking CPU work to a separate thread
         async with transcription_semaphore:
+            start = time.monotonic()
             transcription = await asyncio.to_thread(_sync_transcribe, model_instance, audio_np)
+            elapsed = time.monotonic() - start
+            audio_seconds = len(audio_np) / 16000
+            logging.info(f"Transcription took {elapsed:.2f}s for {audio_seconds:.2f}s of audio")
 
         logging.debug(f"Transcription: {transcription}")
```

### 1.3 `services/max-stt/src/app.py`

Updated the one call site to pass the config values through:

```diff
-            model = get_model(config.MODEL_SIZE, config.DEVICE, config.COMPUTE_TYPE)
+            model = get_model(
+                config.MODEL_SIZE,
+                config.DEVICE,
+                config.COMPUTE_TYPE,
+                cpu_threads=config.CPU_THREADS,
+                num_workers=config.NUM_WORKERS,
+            )
```

(All three files above live inside the `services/max-stt` git submodule — `git -C services/max-stt
diff` shows exactly these three files changed, nothing else.)

## 2. Config changes

### 2.1 `docker-compose.yaml` — pass the new vars into the `stt` container

`docker-compose.yaml` is the file the plan flagged as needing an update so the new env vars
actually reach the container (previously only `MODEL_SIZE`/`DEVICE`/`COMPUTE_TYPE` were wired
through):

```diff
         environment:
           - APP_NAME=stt
           - MODEL_SIZE=${STT_MODEL_SIZE:-large-v3}
           - DEVICE=${STT_DEVICE:-cuda}
           - COMPUTE_TYPE=${STT_COMPUTE_TYPE:-float16}
+          - STT_CPU_THREADS=${STT_CPU_THREADS:-2}
+          - STT_NUM_WORKERS=${STT_NUM_WORKERS:-1}
```

Defaults here (`2`/`1`) again match prior behavior, so production (`.env`, which doesn't set these
vars) is unaffected — it stays on `large-v3`/`cuda`/`float16` with 2 threads unless someone
explicitly opts in.

### 2.2 `.env.dev` — the actual dev-machine tuning

This is the file that changes real runtime behavior on this machine. `.env.dev` is gitignored
(confirmed via `git check-ignore -v .env.dev` → matched by `.gitignore:6`), so this change is
local-only and won't show up in `git diff` at the repo root — recorded here instead:

```diff
 # -- STT (Speech-to-Text) Service Configuration --
+# large-v3 is too slow on CPU (~20s/utterance on a 2-thread cap) -- see
+# doc/dev-mac/LargeSttDelayPlan.md. "small" is a good latency/accuracy balance
+# for CPU dev machines; bump to "medium" if accuracy is insufficient.
-STT_MODEL_SIZE=large-v3
+STT_MODEL_SIZE=small
 # "cuda" for GPU, "cpu" for CPU
 STT_DEVICE=cpu
 # "float16" for GPU, "int8" for CPU
 STT_COMPUTE_TYPE=int8
+# Threads used per transcription (intra-op parallelism). Leave headroom for the
+# other containers sharing the Docker VM's CPU budget.
+STT_CPU_THREADS=6
+# Concurrent independent transcriptions (inter-op parallelism). 1 is enough
+# for a single active speaker.
+STT_NUM_WORKERS=1
 STT_LOG_LEVEL=info
```

`STT_CPU_THREADS=6` was chosen to leave ~4 of this machine's 10 Docker-VM vCPUs for the
`assistant`, `tts`, `proxy`, and `neo4j` containers running alongside it.

## 3. Applying the change

Since dev-mode bind-mounts the STT source (`docker-compose.dev.yaml`: `./services/max-stt:/app`)
and runs `uvicorn --reload`, the **source edits** would have hot-reloaded on their own. The
**env var changes**, however, are only read at container creation, so the container needed a
recreate. `Dockerfile`/`requirements.txt` didn't change, so a full image rebuild wasn't strictly
required, but was run anyway for cleanliness:

```bash
docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml build stt
docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml up -d --force-recreate stt
```

> **Note:** the first attempt used `make dev-build`, which runs `docker compose up --build` in the
> foreground — that command never exits on success (it stays attached, streaming logs), so it's
> the wrong shape for a scripted "run and wait for completion" step. It was interrupted and redone
> as the two-step `build` + `up -d --force-recreate` shown above, which is equivalent for a
> single-service env/dependency change and actually completes. For everyday use, `make dev` /
> `make dev-build` are still the right commands — this only mattered for scripting the validation.

Confirmed in `docker logs max-stt-1`:

```
2026-08-31 15:40:36 - INFO - Preparing model: small on device: cpu with compute_type: int8
2026-08-31 15:40:36 - INFO - 🟩 Using faster_whisper CUDA backend. cpu_threads=6, num_workers=1
2026-08-31 15:40:54 - INFO - Model loaded and ready.
```

Container came up healthy (`docker ps` → `max-stt-1 ... Up ... (healthy)`).

## 4. Validation

Browser automation wasn't available in this environment to click through the actual UI, so the
fix was validated by exercising the real pipeline directly: a genuine speech sample was sent to
the STT service's `/ws` endpoint exactly as the assistant service does, and the round-trip time
was measured.

**Test audio:** `services/max-tts/output.wav` (an existing real speech sample already checked into
the repo, "Hello from the Python test client.", ~2.14s, 22050Hz mono).

```bash
# 1. Copy the sample into the container and resample to 16kHz float32 PCM
#    (the exact format the client's VAD pipeline sends — see proxy/src/vad.js float32ToInt16 /
#    onSpeechEndCallback, and services/max-stt/src/audio_processor.py's np.frombuffer(..., dtype=np.float32))
docker cp services/max-tts/output.wav max-stt-1:/tmp/test.wav
docker exec max-stt-1 python3 -c "
import wave, numpy as np
w = wave.open('/tmp/test.wav', 'rb')
n = w.getnframes()
data = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768.0
sr = w.getframerate()
target_sr = 16000
duration = len(data) / sr
x_old = np.linspace(0, duration, len(data))
x_new = np.linspace(0, duration, int(duration * target_sr))
np.interp(x_new, x_old, data).astype(np.float32).tofile('/tmp/test_16k_f32.raw')
"

# 2. Send it over the same /ws endpoint the assistant service uses, and time the round trip
docker exec max-stt-1 python3 -c "
import asyncio, time, websockets
async def main():
    async with websockets.connect('ws://localhost:80/ws') as ws:
        audio = open('/tmp/test_16k_f32.raw', 'rb').read()
        start = time.monotonic()
        await ws.send(audio)
        response = await ws.recv()
        print(f'Round-trip: {time.monotonic() - start:.2f}s')
        print('Response:', response)
asyncio.run(main())
"
```

**Result:**

```
Round-trip: 1.84s
Response: {"type": "transcription", "source": "user", "data": "Hello from the Python test client."}
```

And from the new permanent timing log, `docker logs max-stt-1`:

```
2026-08-31 15:40:55 - INFO - Processing audio with duration 00:02.139
2026-08-31 15:40:57 - INFO - Transcription took 1.84s for 2.14s of audio
```

The transcription is also correct — confirms `small` produces usable accuracy on a clean sample,
not just speed.

### Before vs. after

| | Before (`large-v3`, cpu_threads=2) | After (`small`, cpu_threads=6) |
|---|---|---|
| Model | large-v3 (1.5B params) | small (244M params) |
| Observed/typical delay | ~20s (user-reported, matches root-cause analysis) | 1.84s (measured, ~2.1s of audio) |
| Real-time factor | ~9-10x slower than real-time | ~0.86x — essentially real-time |

This is roughly a **10x** latency reduction for a comparable utterance length. The remaining
~1.8s is largely the model's actual decode time for ~2s of audio, which is reasonable for
real-time conversational use.

Test artifacts (`/tmp/test.wav`, `/tmp/test_16k_f32.raw`) were removed from the container after
the test; nothing was left behind in the image or any volume.

## 5. What to check next (manual, needs a real browser)

The above validates the STT service in isolation. To confirm the fix end-to-end through the
actual UI (browser automation wasn't available in this session — the Chrome extension wasn't
connected):

1. Open `http://localhost:8080` (dev mode).
2. Click **Start Listening**, speak a short phrase, then stop speaking and wait for VAD to detect
   silence.
3. Confirm `[Me]: ...` appears within a couple of seconds, not ~20s.
4. If accuracy feels off for real conversational speech (mumbled words, background noise, etc. —
   more realistic than the clean test sample used above), consider bumping `.env.dev`'s
   `STT_MODEL_SIZE` from `small` to `medium` and re-running the same `build` + `up -d
   --force-recreate stt` steps from section 3. `medium` is ~2x slower than `small` but
   meaningfully more accurate — still far faster than the original `large-v3`/2-thread setup.

## 6. Rollback

If needed, revert `.env.dev`'s STT section back to:

```dotenv
STT_MODEL_SIZE=large-v3
STT_DEVICE=cpu
STT_COMPUTE_TYPE=int8
STT_LOG_LEVEL=info
```

(dropping the `STT_CPU_THREADS`/`STT_NUM_WORKERS` lines, or leaving them — they're harmless at any
model size), then:

```bash
docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml up -d --force-recreate stt
```

The code changes (`config.py`, `audio_processor.py`, `app.py`) and the `docker-compose.yaml`
change don't need to be reverted for a rollback — they're backward-compatible by default (unset
`STT_CPU_THREADS`/`STT_NUM_WORKERS` fall back to `2`/`1`, matching the original hardcoded
behavior).

## 7. Files touched

| File | Repo | Change |
|---|---|---|
| `services/max-stt/src/config.py` | `max-stt` submodule | Added `CPU_THREADS`, `NUM_WORKERS` env-driven settings |
| `services/max-stt/src/audio_processor.py` | `max-stt` submodule | `get_model()` takes thread/worker params instead of hardcoding; added transcription timing log |
| `services/max-stt/src/app.py` | `max-stt` submodule | Pass `config.CPU_THREADS`/`config.NUM_WORKERS` into `get_model()` |
| `docker-compose.yaml` | `max` (this repo) | Pass `STT_CPU_THREADS`/`STT_NUM_WORKERS` through to the `stt` container |
| `.env.dev` | `max` (this repo, gitignored) | `STT_MODEL_SIZE=small`, added `STT_CPU_THREADS=6`, `STT_NUM_WORKERS=1` |
| `doc/dev-mac/LargeSttDelayPlan.md` | `max` (this repo) | Checked off Option 1's implementation checklist, linked to this walkthrough |

Note: `services/max-stt` and `services/max-assistant` are git submodules with their own commit
history — the source changes above are uncommitted in that submodule's working tree as of this
writing; commit them there separately if you want this change preserved beyond the local working
copy.

---

# Part 2 — Option 2: Run STT Natively on macOS via MLX

## 0. Starting point

Option 1 got the containerized CPU path down to ~1.8s for a ~2.1s utterance using the `small`
model — good, but capped in accuracy compared to `large-v3`, because Docker Desktop's Linux VM has
no path to the Mac's Metal GPU. Option 2 removes that cap entirely by running the STT service
**outside** Docker, directly on macOS, where `mlx_whisper` can actually use the GPU.

No code changes were needed in `services/max-stt/src/audio_processor.py` — its `try: import
mlx_whisper / except ImportError: ... faster_whisper` branch (lines 9-16) already picks the MLX
backend automatically whenever the import succeeds, which is exactly the case natively on macOS
(and only there — confirmed in the STT root-cause investigation that MLX has no Linux build at
all, so it can never import inside the container regardless of host chip).

## 1. New files

### 1.1 `services/max-stt/scripts/run_native_macos.sh` (new, executable)

Creates an isolated venv (`.venv-native`, gitignored-by-convention next to the container's own
build artifacts), installs the service's normal `requirements.txt` plus `mlx-whisper`, and runs
the same `src.app:app` FastAPI app the container runs — just natively, bound to `0.0.0.0` on a
configurable port:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer python3.11 (matches the container's PYTHON_VERSION) if available.
PYBIN="python3"
if command -v python3.11 >/dev/null 2>&1; then
    PYBIN="python3.11"
fi

if [ ! -d .venv-native ]; then
    "$PYBIN" -m venv .venv-native
fi
source .venv-native/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt mlx-whisper

export MODEL_SIZE="${STT_MODEL_SIZE:-large-v3}"
export DEVICE=mps          # unused by the mlx branch, kept for log clarity
export COMPUTE_TYPE=native # unused by the mlx branch, kept for log clarity
export UVICORN_HOST=0.0.0.0
export UVICORN_PORT="${STT_NATIVE_PORT:-8090}"

echo "Starting native STT service on http://${UVICORN_HOST}:${UVICORN_PORT} (model=${MODEL_SIZE})"
python -m uvicorn src.app:app --host "$UVICORN_HOST" --port "$UVICORN_PORT"
```

**One deviation from the plan:** the plan's draft script used plain `python3`. This machine's
system Python is 3.9.6, while the container (and the rest of this repo) targets 3.11, and
`mlx-whisper` prefers a modern interpreter — so the script was written to prefer `python3.11`
(found via Homebrew at `/opt/homebrew/bin/python3.11`) when available, falling back to `python3`
otherwise.

### 1.2 `docker-compose.stt-native.yaml` (new, dev-only override)

Gates the containerized `stt` service behind a Compose profile that's never active in this mode,
and marks the dependency on it as non-required for `assistant` and `proxy`:

```yaml
services:
  stt:
    profiles: ["container-stt"]   # only starts if container-stt is in COMPOSE_PROFILES

  # depends_on lists are unioned (not replaced) across -f files, so simply
  # re-listing a shorter dependency list here does NOT drop `stt` -- it has to
  # be marked not-required explicitly instead.
  assistant:
    depends_on:
      stt:
        condition: service_started
        required: false            # stt is native, not compose-managed, when this file is active

  proxy:
    depends_on:
      stt:
        condition: service_started
        required: false            # stt is native, not compose-managed, when this file is active
```

**Important deviation from the plan.** The plan's draft override simply re-declared shorter
`depends_on` lists (e.g. `assistant.depends_on: [tts]`, dropping `stt`), assuming a later `-f` file
replaces an earlier one's list. That assumption is wrong: Docker Compose **unions** `depends_on`
across merged files rather than replacing it. Verified directly:

```
$ docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml \
    -f docker-compose.stt-native.yaml config
service "assistant" depends on undefined service "stt": invalid compose project
```

i.e. the base file's `depends_on: [stt, tts]` and the override's `depends_on: [tts]` merged back
into `[stt, tts]`, and since `stt` is profile-gated off, Compose refused to start. The fix is the
long-form `depends_on` mapping with `required: false`, which — confirmed via the same `config`
command — merges **per-key**: `assistant`'s `stt` entry becomes `required: false` while its `tts`
and `neo4j` entries are untouched, inherited from the base file with `required: true` intact. This
is the version actually running.

## 2. Config changes

### 2.1 `docker-compose.yaml` — pass `STT_WEBSOCKET_URL` through to `assistant`

This variable was read by the code (`services/max-assistant/src/max_assistant/config.py:79`,
defaulting to `ws://stt/ws`) but never actually wired into the container's environment — so it
could never be overridden without this change:

```diff
         environment:
           - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://ollama:11434}
           - OLLAMA_MODEL_NAME=${OLLAMA_MODEL_NAME:-llama3}
+          - STT_WEBSOCKET_URL=${STT_WEBSOCKET_URL:-ws://stt/ws}
           - TTS_VOICE=${TTS_VOICE:-en_US-lessac-medium}
```

Default (`ws://stt/ws`) matches prior behavior, so production is unaffected unless it explicitly
sets `STT_WEBSOCKET_URL`.

### 2.2 `.env.dev` — activate native mode

```diff
 STT_BASE_IMAGE=python:3.11-slim-bookworm
 COMPOSE_PROFILES=local-only
 OLLAMA_BASE_URL=http://host.docker.internal:11434
+
+# STT natively via MLX/Metal (see doc/dev-mac/LargeSttDelayPlan.md, Option 2).
+# Set to "native" to run STT outside Docker (start it separately with
+# `make stt-native`); leave unset/anything else to keep the containerized
+# CPU STT service from Option 1.
+STT_MODE=native
+STT_NATIVE_PORT=8090
+STT_WEBSOCKET_URL=ws://host.docker.internal:8090/ws
```

And, since native MLX doesn't need the CPU-friendly model-size tradeoff from Option 1, the model
size was bumped back up to `large-v3` (comments updated to explain both paths share this one
variable):

```diff
-STT_MODEL_SIZE=small
+STT_MODEL_SIZE=large-v3
```

`STT_DEVICE`, `STT_COMPUTE_TYPE`, `STT_CPU_THREADS`, `STT_NUM_WORKERS` were all left as Option 1
set them — they're inert with `STT_MODE=native` active (the native script's `mlx` backend ignores
them), but stay ready to go the moment `STT_MODE` is switched back for the containerized fallback.

### 2.3 `Makefile` — detect native mode and add the `stt-native` target

Mirrors the existing `HAS_CONTAINER_OLLAMA` pattern used for native Ollama:

```diff
 HAS_CONTAINER_OLLAMA := $(shell grep -E '^COMPOSE_PROFILES=.*container-ollama' .env .env.dev 2>/dev/null)
+
+# Native STT (MLX on macOS) support -- mirrors the native-Ollama pattern above.
+# See doc/dev-mac/LargeSttDelayPlan.md (Option 2).
+DEV_STT_NATIVE := $(shell grep -E '^STT_MODE=native' .env.dev 2>/dev/null)
+
+ifneq ($(DEV_STT_NATIVE),)
+	DEV_COMPOSE += -f docker-compose.stt-native.yaml
+endif
```

```diff
 ## Build and start the development containers
 dev: shared
+ifneq ($(DEV_STT_NATIVE),)
+	@echo "STT_MODE=native detected -- run 'make stt-native' in a separate terminal before/while using the app."
+endif
 	$(DEV_COMPOSE) up

 dev-build: shared
+ifneq ($(DEV_STT_NATIVE),)
+	@echo "STT_MODE=native detected -- run 'make stt-native' in a separate terminal before/while using the app."
+endif
 	$(DEV_COMPOSE) up --build

 ## Stop the development containers
 dev-down:
 	$(DEV_COMPOSE_LOG) down
+
+## Run the STT service natively (MLX/Metal) -- required when STT_MODE=native in .env.dev
+stt-native:
+	set -a && . ./.env.dev && set +a && ./services/max-stt/scripts/run_native_macos.sh
```

(`stt-native` also added to `.PHONY`.)

**Deviation from the plan:** the plan's draft `stt-native` target just called the script directly.
That leaves the script unable to see `STT_MODEL_SIZE`/`STT_NATIVE_PORT` from `.env.dev`, since
`make` doesn't export a called script's parent shell environment from an arbitrary file — only
`docker compose --env-file` does that automatically. The target was written to explicitly source
`.env.dev` (`set -a && . ./.env.dev && set +a`, exporting everything it defines) before invoking
the script, so the two paths (Compose and the native script) read the exact same source of truth.

## 3. Running it

```bash
make stt-native
```

Output confirmed the MLX backend loaded (native macOS, not the container):

```
Starting native STT service on http://0.0.0.0:8090 (model=large-v3)
INFO:     Started server process [74498]
INFO:     Waiting for application startup.
2026-08-31 10:16:43 - INFO - Preparing model: large-v3 on device: mps with compute_type: native
2026-08-31 10:16:43 - INFO - 🍎 Using MLX backend. Mapped 'large-v3' to 'mlx-community/whisper-large-v3-mlx'
2026-08-31 10:16:43 - INFO - Model loaded and ready.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8090 (Press CTRL+C to quit)
```

```bash
curl -s http://localhost:8090/health
# {"status":"healthy"}
```

Then, in another terminal:

```bash
make dev
```

Output confirmed the native-mode hint printed and the containerized `stt` service was **not**
started — only `assistant` needed a recreate (to pick up the new `STT_WEBSOCKET_URL`), everything
else kept running:

```
STT_MODE=native detected -- run 'make stt-native' in a separate terminal before/while using the app.
docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml -f docker-compose.stt-native.yaml up
 Container max-tts-1 Running
 Container max-proxy-1 Running
 Container max-neo4j-1 Running
 Container max-assistant-1 Recreate
```

```
$ docker ps --format '{{.Names}}'
max-assistant-1
max-proxy-1
max-tts-1
max-neo4j-1
```

No `max-stt-1` — confirmed the containerized service is fully absent, and:

```bash
$ docker exec max-assistant-1 printenv STT_WEBSOCKET_URL
ws://host.docker.internal:8090/ws
```

## 4. Validation

### 4.1 First-call cost: the one-time model download

The very first transcription request took **209.94s** — this is expected and not a performance
regression. Unlike the container's `get_model()` MLX branch (which just returns a repo string),
`mlx_whisper.transcribe()` downloads the model weights from Hugging Face lazily on first use, and
`large-v3`'s MLX weights are several GB (confirmed via `du -sh ~/.cache/huggingface` climbing
during the call: 527MB → 1.2GB → ... during the download). This matches the plan's §5.4 Operational
Notes ("expect one clean re-download the first time").

### 4.2 Warm-model latency (the number that matters)

With the model cached, the same ~2.14s test clip (`services/max-tts/output.wav`, same one used for
Option 1) was sent 3 times in a row directly to the native service:

```bash
services/max-stt/.venv-native/bin/python3 -c "
import asyncio, time, websockets
async def main():
    async with websockets.connect('ws://localhost:8090/ws') as ws:
        audio = open('/tmp/max_stt_native_test.raw', 'rb').read()
        for i in range(3):
            start = time.monotonic()
            await ws.send(audio)
            response = await ws.recv()
            print(f'Run {i+1} round-trip: {time.monotonic()-start:.2f}s -> {response}')
asyncio.run(main())
"
```

```
Run 1 round-trip: 0.90s -> {"type": "transcription", "source": "user", "data": "Hello from the Python test client."}
Run 2 round-trip: 0.90s -> {"type": "transcription", "source": "user", "data": "Hello from the Python test client."}
Run 3 round-trip: 0.90s -> {"type": "transcription", "source": "user", "data": "Hello from the Python test client."}
```

Consistent **0.90s** for `large-v3` — matched in the service's own timing log:

```
2026-08-31 10:20:41 - INFO - Transcription took 0.90s for 2.14s of audio
2026-08-31 10:20:41 - INFO - Transcription took 0.89s for 2.14s of audio
2026-08-31 10:20:42 - INFO - Transcription took 0.89s for 2.14s of audio
```

### 4.3 End-to-end through the real client path

The isolated numbers above only prove the STT service itself is fast. To confirm the full chain
actually works — browser-equivalent client → nginx (`wss://`) → `assistant` → native STT via
`host.docker.internal` — a client was scripted to speak the exact protocol
`proxy/src/app.js`/`proxy/src/websocket.js` use (send a `{"type":"config","username":...}` JSON
message, then a raw float32 PCM audio blob, over the same TLS WebSocket endpoint the browser
connects to):

```bash
services/max-stt/.venv-native/bin/python3 -c "
import asyncio, json, ssl, time, websockets
async def main():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    async with websockets.connect('wss://localhost:8443/ws', ssl=ctx) as ws:
        await ws.send(json.dumps({'type': 'config', 'username': 'Margaret.Miller'}))
        audio = open('/tmp/max_stt_native_test.raw', 'rb').read()
        await asyncio.sleep(1.0)
        start = time.monotonic()
        await ws.send(audio)
        msg = await asyncio.wait_for(ws.recv(), timeout=30)
        print(f'[{time.monotonic()-start:.2f}s]', msg)
asyncio.run(main())
"
```

```
[1.10s] {"type": "transcription", "source": "user", "data": "Hello from the Python test client."}
```

And `docker logs max-assistant-1` confirms it actually reached across to the native process, not
the (now-absent) container:

```
2026-08-31 10:21:22 - max_assistant.clients.stt_client - INFO - Establishing persistent connection to STT service at ws://host.docker.internal:8090/ws...
2026-08-31 10:21:22 - max_assistant.clients.stt_client - INFO - STT persistent connection opened and hot.
2026-08-31 10:21:25 - max_assistant.clients.stt_client - INFO - Received message from STT: {"type": "transcription", "source": "user", "data": "Hello from the Python test client."}
```

### Before vs. after (all three configurations, same ~2.14s test clip)

| | Original (`large-v3`, cpu_threads=2) | Option 1 (`small`, cpu_threads=6) | **Option 2 (`large-v3`, native MLX)** |
|---|---|---|---|
| Where it runs | Docker container, CPU | Docker container, CPU | Native macOS process, Metal GPU |
| Model | large-v3 (1.5B params) | small (244M params) | **large-v3 (1.5B params)** |
| Warm transcription time | ~20s (typical/reported) | 1.84s | **0.90s** |
| Real-time factor | ~9-10x slower than real-time | ~0.86x | **~0.42x** |
| End-to-end (real client path, incl. network hops) | not measured (see below) | not measured | **1.10s** |

Option 2 gets both the best accuracy (full `large-v3`, no downgrade) *and* the best speed —
roughly **22x faster** than the original setup and **2x faster** than Option 1's CPU-tuned
`small`-model path, because it's the only option actually using the Mac's GPU.

## 5. What to check next (manual, needs a real browser)

Same caveat as Part 1 — browser automation wasn't available in this session (Chrome extension not
connected), so the scripted test above stands in for a real "speak into the mic" pass. Manually:

1. Make sure both processes are running: `make stt-native` in one terminal, `make dev` in another.
2. Open `http://localhost:8080`, click **Start Listening**, speak, stop, and confirm `[Me]: ...`
   appears quickly.
3. Watch `docker logs -f max-assistant-1` for the `Establishing persistent connection to STT
   service at ws://host.docker.internal:8090/ws...` line to confirm it's really talking to the
   native process.
4. First run after a fresh machine/cache-clear will have the ~3-minute one-time model download
   from §4.1 — that's expected, not a bug.
5. macOS may prompt to allow incoming network connections to the Python process the first time it
   binds `0.0.0.0:8090` (per the plan's §5.4 operational notes) — accept it.

## 6. Rollback

Two independent ways to back out, without touching any code:

**a) Switch back to the Option 1 containerized path** (fastest rollback — no process management):

```dotenv
# in .env.dev
STT_MODE=  # or delete the line entirely
```

Then stop the `make stt-native` process (Ctrl-C, or `kill` the `uvicorn` process) and run
`make dev` again — `DEV_STT_NATIVE` resolves empty, `docker-compose.stt-native.yaml` drops out of
the compose command, and the containerized `stt` service (with its normal hard `depends_on`) comes
back exactly as Option 1 left it. `STT_MODEL_SIZE` will need to be dropped back to `small`/`medium`
for CPU-reasonable speed, since it's currently set to `large-v3` for the native path.

**b) Roll back Option 2's files entirely:** delete
`services/max-stt/scripts/run_native_macos.sh`, `docker-compose.stt-native.yaml`, and
`services/max-stt/.venv-native/` (the local venv, never committed), then revert the `Makefile` and
`docker-compose.yaml` diffs from §2.3/§2.1 above and the `.env.dev` additions from §2.2. Everything
in Part 2 is additive, so nothing else needs to change.

## 7. Files touched

| File | Repo | Change |
|---|---|---|
| `services/max-stt/scripts/run_native_macos.sh` | `max-stt` submodule | New: runs the STT app natively via a local venv + MLX |
| `docker-compose.stt-native.yaml` | `max` (this repo) | New: profile-gates the containerized `stt` service off, marks it non-required for `assistant`/`proxy` |
| `docker-compose.yaml` | `max` (this repo) | Pass `STT_WEBSOCKET_URL` through to `assistant` (was previously read by code but never wired) |
| `.env.dev` | `max` (this repo, gitignored) | Added `STT_MODE=native`, `STT_NATIVE_PORT=8090`, `STT_WEBSOCKET_URL=ws://host.docker.internal:8090/ws`; bumped `STT_MODEL_SIZE` back to `large-v3` |
| `Makefile` | `max` (this repo) | Added `DEV_STT_NATIVE` detection, conditional compose override, `stt-native` target |
| `doc/dev-mac/LargeSttDelayPlan.md` | `max` (this repo) | Checked off Option 2's implementation checklist, linked to this walkthrough |

`services/max-stt/.venv-native/` was created on disk by the run script but is a local build
artifact (same category as the container's own `/opt/venv`) — not intended to be committed.

## 8. Currently running state (as of this writing)

Both processes are live on this machine as the active configuration:

```
$ docker ps --format '{{.Names}}'
max-assistant-1
max-proxy-1
max-tts-1
max-neo4j-1

$ ps aux | grep uvicorn
... python -m uvicorn src.app:app --host 0.0.0.0 --port 8090   # native STT, MLX backend
```

`make stt-native` needs to be running for the app to work end-to-end whenever `make dev` is used
with `STT_MODE=native` in `.env.dev` — it is not managed by Docker Compose and won't restart on
its own if stopped or if the Mac reboots.
