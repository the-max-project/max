# Whisper STT Connection URL

**Created:** 9/11/2026 14:22:04  
**Updated:** 9/11/2026 14:47:57  
**Exported:** 9/11/2026 14:49:45  

> **Reviewer note (2026-09-14):** This is an unedited chat export and its Makefile line numbers/fix scope are inaccurate against the current codebase. See "Accuracy corrections" at the bottom before applying anything below.

## Gemini:

The process is still running in the background because Uvicorn held onto port `8090` after the terminal window closed, or the command spawned detached[cite: 1, 5]. Furthermore, your Makefile's `pkill -f "services/max-stt"` does not match the running process name (`uvicorn src.app:app`)[cite: 1, 5].

Here is how to free the port and fix the issue:

<Steps>
  <Step subtitle="1 min" title="Kill the process holding the port">
    Find and kill whatever process is currently bound to port 8090[cite: 1]:

    ```bash
    kill -9 $(lsof -ti:8090)
    ```

    Verify the port is free by running:
    ```bash
    lsof -i:8090
    ```
    If successful, this command will output nothing.
  </Step>

  <Step subtitle="Makefile edit" title="Fix the Makefile kill target">
    Your Makefile targets currently search for `services/max-stt`[cite: 5]. Update lines 93, 126, and 147 in `Makefile` so that `make dev-down` and `make clean` successfully kill the Uvicorn server as well[cite: 5]:

    ```makefile
    @-pkill -f "uvicorn src.app:app" 2>/dev/null || true
    ```

    Verify the pattern matches by testing `pgrep -f "uvicorn src.app:app"` next time the service runs.

    > **Correction:** the line numbers above don't match the current `Makefile`. The `"services/max-stt"` pattern actually appears on **5** lines, not 3:
    > - line 48 — `stt:` target's launch guard (`pgrep -f "services/max-stt"`)
    > - line 95 — `dev-down:` (`pkill -f "services/max-stt"`)
    > - line 121 — `prod-macos:` launch guard (`pgrep -f "services/max-stt"`)
    > - line 132 — `prod-macos-down:` (`pkill -f "services/max-stt"`)
    > - line 160 — `clean:` (`pkill -f "services/max-stt"`)
    >
    > The original diagnosis is also a bit imprecise: the pattern *does* match — it matches the `bash .../run_native_macos.sh` wrapper process. The bug is that `run_native_macos.sh`'s last line runs `python -m uvicorn src.app:app` as a **child** of that bash script (no `exec`), so killing the wrapper orphans the uvicorn process, which keeps holding port 8090.
    >
    > All **5** occurrences need to switch from `"services/max-stt"` to `"uvicorn src.app:app"`, not just the 2-3 implied here — otherwise `make prod-macos-down` still leaves the process running, and `make prod-macos`'s launch guard (line 121) will wrongly think STT isn't running and spawn a second uvicorn on the same port.
  </Step>

  <Step subtitle="Terminal visibility" title="Ensure Terminal window focuses properly">
    The `osascript` in your `stt` target runs in the background if Terminal is hidden or in another Space[cite: 5]. Update the `stt` target in `Makefile` to explicitly activate and bring the window to the front:

    ```makefile
    stt:
    ifeq ($(IS_MACOS),true)
    	@echo "Opening native STT in a new Terminal window..."
    	@pgrep -f "uvicorn src.app:app" >/dev/null || osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "cd $(CURDIR) && bash services/max-stt/scripts/run_native_macos.sh"'
    else
    	$(DEV_COMPOSE) up -d stt
    endif
    ```

    Verify by running `make stt`; Terminal should now jump to the foreground immediately.

    > **Note:** `tell application "Terminal" to do script "..."` already activates Terminal in most cases per Apple's documented behavior, so this step is a minor robustness improvement rather than a fix for a confirmed bug — worth doing, but lower priority than the pkill/pgrep pattern fix above.
  </Step>
</Steps>

<Elicitations message="What would you like to troubleshoot next?">
  <Elicitation label="Run STT directly" query="How can I run the STT script directly in my current terminal without osascript?"/>
  <Elicitation label="Check Uvicorn logs" query="How can I check the logs of the STT service running on macOS?"/>
  <Elicitation label="Verify WebSocket" query="How can I test if the native macOS STT WebSocket endpoint is accepting audio connections?"/>
</Elicitations>

Powered by Gemini Exporter (https://www.ai-chat-exporter.com)

---

## Accuracy corrections (2026-09-14 review)

Verified against `Makefile` @ `2167112` (unchanged since 2026-09-10) and `services/max-stt/scripts/run_native_macos.sh`:

| Claim in the chat | Status |
|---|---|
| Port 8090 | ✅ Correct — matches `STT_NATIVE_PORT` default and `.env.dev`'s `STT_WEBSOCKET_URL` |
| `uvicorn src.app:app` is the right process target | ✅ Correct — confirmed in `services/max-stt/src/app.py` |
| Root cause: pkill pattern mismatch | ⚠️ Imprecise — the pattern matches the bash wrapper fine; the real issue is the child `uvicorn` process being orphaned when only the wrapper is killed (no `exec` in `run_native_macos.sh`) |
| "Update lines 93, 126, and 147" | ❌ Wrong — current lines are 48, 95, 121, 132, 160 (5 sites, not 3) |
| Fix scope ("dev-down and clean") | ❌ Incomplete — misses `prod-macos-down` (132) and the `prod-macos` launch guard (121); leaving those unfixed reintroduces the same stuck-port bug on the prod-macos path |

**Actual fix:** in `Makefile`, replace `"services/max-stt"` with `"uvicorn src.app:app"` in all 5 places (lines 48, 95, 121, 132, 160) — both the `pgrep` launch guards and the `pkill` teardown calls, across `stt`, `dev-down`, `prod-macos`, `prod-macos-down`, and `clean`.
