import asyncio
import websockets
import json
import os
import yaml
import argparse
import librosa
import numpy as np
import ssl
import time


def get_audio_bytes(input_file):
    """
    Reads the audio file and returns the raw Float32 bytes from memory.
    If it's a .wav, it converts it to mono, 16000Hz raw Float32 on the fly.
    """
    if not os.path.exists(input_file):
        raise FileNotFoundError(f"Audio file '{input_file}' not found.")

    if input_file.lower().endswith('.wav'):
        print(f"🔄 Processing '{input_file}' to mono, 16000Hz raw Float32 in memory...")

        # Load and resample using librosa
        data, samplerate = librosa.load(input_file, sr=16000, mono=True)

        # Ensure float32 format
        data = data.astype(np.float32)

        # Return the raw bytes directly
        return data.tobytes()
    else:
        # Assume it's already a raw file and read its bytes
        with open(input_file, "rb") as f:
            return f.read()


import time  # Make sure 'time' is imported at the top of your file


async def run_single_test(websocket, username, audio_file_path, expected_text, timeout=60):
    print(f"\n--- Running Test: {audio_file_path} ---")

    found_expected = False
    received_llm = False

    try:
        # Get the audio bytes directly into memory
        audio_data = get_audio_bytes(audio_file_path)

        # Note: We no longer send the 'config' message on every single test
        # unless your server requires it per turn, but we definitely send the audio.

        # Record the exact start time right before sending audio
        start_time = time.time()
        await websocket.send(audio_data)
        print(f"Sent audio data ({len(audio_data)} bytes) at t=0.00s. Waiting up to {timeout}s...")

        # Listen for the responses using a timeout loop on the shared connection
        async def listen_for_responses():
            nonlocal found_expected, received_llm

            while True:
                response = await websocket.recv()
                elapsed = time.time() - start_time

                # Ignore binary responses (audio playback from the server)
                if isinstance(response, bytes):
                    print(f"[+{elapsed:.2f}s] [Received binary audio data]")
                    continue

                # Parse text/JSON response
                try:
                    message_data = json.loads(response)
                    message_text = message_data.get("data")

                    if message_text:
                        source = message_data.get("source", "unknown")
                        print(f"[+{elapsed:.2f}s] [{source.upper()}]: {message_text}")

                        # Apply the test explicitly to the USER message transcription
                        if source.lower() == "user" and expected_text.lower() in message_text.lower():
                            found_expected = True

                        # Check if the server has sent an LLM/Assistant response
                        if source.lower() in ["llm", "assistant"]:
                            received_llm = True

                        # If BOTH conditions are met, finish this test step
                        if found_expected and received_llm:
                            print(f"✅ PASSED in {elapsed:.2f}s: Expected user text matched and LLM response received.")
                            return True

                except json.JSONDecodeError:
                    print(f"[+{elapsed:.2f}s] [RAW TEXT]: {response}")
                    received_llm = True

                    if expected_text.lower() in response.lower():
                        found_expected = True

                    if found_expected and received_llm:
                        print(f"✅ PASSED in {elapsed:.2f}s: Expected text matched and LLM response received.")
                        return True

        return await asyncio.wait_for(listen_for_responses(), timeout=timeout)

    except asyncio.TimeoutError:
        print(
            f"❌ FAILED: Timed out after {timeout}s. (Found Expected User Text: {found_expected}, Received LLM: {received_llm})")
        return False
    except Exception as e:
        print(f"❌ Error during test: {e}")
        return False


async def run_all_tests(config_data):
    global_config = config_data.get("config", {})
    ws_url = global_config.get("ws_url", "ws://localhost:8080/ws")
    username = global_config.get("username", "YamlBatchRunner")

    tests = config_data.get("tests", [])
    if not tests:
        print("❌ No tests found under the 'tests:' key in the YAML file.")
        return

    print(f"Starting persistent session batch run of {len(tests)} tests against {ws_url}...")

    # Setup SSL context if needed
    ssl_context = None
    if ws_url.startswith("wss://"):
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ssl_context.check_hostname = False
        ssl_context.verify_mode = ssl.CERT_NONE

    passed_count = 0

    # Open ONE persistent WebSocket connection for all tests
    try:
        async with websockets.connect(ws_url, ssl=ssl_context) as websocket:
            print("🔗 Persistent WebSocket connection established.")

            # Send initial config message once at the start of the session
            config_message = {
                "type": "config",
                "username": username
            }
            await websocket.send(json.dumps(config_message))

            # Iterate through all tests using the same open connection
            for i, test in enumerate(tests, 1):
                audio_file = test.get("audio_file")
                expected_text = test.get("expected_text")

                if not audio_file or not expected_text:
                    print(f"\n⚠️ Skipping test {i}: Missing 'audio_file' or 'expected_text'")
                    continue

                success = await run_single_test(websocket, username, audio_file, expected_text)
                if success:
                    passed_count += 1

    except Exception as e:
        print(f"❌ Persistent connection error: {e}")

    print(f"\n=== Test Run Complete: {passed_count}/{len(tests)} Passed ===")


def main():
    parser = argparse.ArgumentParser(description="Run batch WebSocket audio tests from a YAML configuration.")
    parser.add_argument("config", help="Path to the YAML test configuration file.")
    args = parser.parse_args()

    try:
        with open(args.config, 'r') as file:
            config_data = yaml.safe_load(file)
    except FileNotFoundError:
        print(f"❌ Error: Configuration file '{args.config}' not found.")
        return
    except yaml.YAMLError as e:
        print(f"❌ Error parsing YAML file: {e}")
        return

    # Execute the async event loop
    asyncio.run(run_all_tests(config_data))


if __name__ == "__main__":
    main()