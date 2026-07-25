"""Shared endpoint/auth plumbing for the llama-server measurement scripts.

Every script here talks to a running llama-server over its OpenAI-compatible
endpoint. Nothing in this module is specific to this repo's deployments, so
the same scripts work against any llama-server on any host.

Environment overrides (all optional):

    LLAMA_TEST_URL            full base URL, e.g. http://10.0.0.5:8080
    LLAMA_TEST_HOST           host only            (default 127.0.0.1)
    LLAMA_TEST_PORT           port only            (default 8080)
    LLAMA_TEST_API_KEY_FILE   path to llama-server's --api-key-file
                              (default ~/.config/llama-server/api-keys)
    LLAMA_TEST_API_KEY        the key itself, if you'd rather not use a file

A server started with --allow-no-api-key needs neither of the last two.
"""
import json
import os
import sys
import urllib.error
import urllib.request

HOST = os.environ.get("LLAMA_TEST_HOST", "127.0.0.1")
PORT = os.environ.get("LLAMA_TEST_PORT", "8080")
BASE = os.environ.get("LLAMA_TEST_URL", f"http://{HOST}:{PORT}").rstrip("/")
URL = BASE + "/v1/chat/completions"

KEY_FILE = os.environ.get("LLAMA_TEST_API_KEY_FILE",
                          "~/.config/llama-server/api-keys")


def api_key():
    """First non-comment line of the api-keys file, or None if unavailable.

    None is a legitimate result (server run with --allow-no-api-key), so a
    missing file is not an error here - an unauthorized response later is.
    """
    env = os.environ.get("LLAMA_TEST_API_KEY")
    if env:
        return env.strip()
    try:
        with open(os.path.expanduser(KEY_FILE)) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return None


KEY = api_key()


def post(messages, max_tokens=8, timeout=1800, thinking=False):
    """One non-streamed chat completion.

    Non-streamed on purpose: only that response carries the `timings` block,
    and `timings.prompt_n` (tokens actually reprocessed) is the measurement
    every script here depends on. Do not "modernize" these to streaming.
    """
    body = {"messages": messages, "max_tokens": max_tokens, "temperature": 0,
            "stream": False, "cache_prompt": True,
            "chat_template_kwargs": {"enable_thinking": thinking}}
    headers = {"Content-Type": "application/json"}
    if KEY:
        headers["Authorization"] = f"Bearer {KEY}"
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        if e.code == 401:
            die(f"401 unauthorized from {URL}.\n"
                f"  Looked for a key in {KEY_FILE} (and $LLAMA_TEST_API_KEY).\n"
                f"  Set LLAMA_TEST_API_KEY_FILE, or start the server with "
                f"--allow-no-api-key.")
        die(f"HTTP {e.code} from {URL}: {detail}")
    except urllib.error.URLError as e:
        die(f"cannot reach {URL}: {e.reason}\n"
            f"  Is llama-server running? Override with LLAMA_TEST_URL / "
            f"LLAMA_TEST_HOST / LLAMA_TEST_PORT.")


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def label(default="run"):
    """Optional free-text run label from argv[1] - never an IndexError."""
    return sys.argv[1] if len(sys.argv) > 1 else default


def report(d):
    """(prompt_tokens, reprocessed_tokens, prefill_seconds) from a response."""
    t, u = d["timings"], d["usage"]
    return u["prompt_tokens"], t["prompt_n"], t["prompt_ms"] / 1000.0
