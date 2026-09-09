#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LingoFuse LLM Service – Multi‑session streaming server.

This service exposes two Call APIs:
  - generate(content, prompt, client_name) -> {session_id}
  - set_system_message(content) -> {status}

Each generation request spawns a dedicated thread that streams tokens
via sequenced notifications to the dynamically provided client_name.
All comments and logs are in English for clarity.

===============================================================================
USAGE
===============================================================================
  python llm_service.py [OPTIONS]

All options can also be set via environment variables (listed below).

===============================================================================
OPTIONS (also available as environment variables)
===============================================================================
  --model-path PATH
      Path to the GGUF model file (or Hugging Face model directory for transformers).
      Default: ./qwen2.5-7b-instruct-q4_k_m.gguf
      Env: LLM_MODEL_PATH

  --context-size N
      Context window size in tokens.
      Default: 32768
      Env: LLM_CONTEXT_SIZE

  --max-tokens N
      Maximum number of tokens to generate per request.
      Default: 4096
      Env: LLM_MAX_TOKENS

  --threads N
      Number of CPU threads for llama.cpp (ignored for transformers).
      Default: 6
      Env: LLM_THREADS

  --gpu-layers N
      Number of layers to offload to GPU (-1 = all, 0 = CPU only).
      Default: -1
      Env: LLM_GPU_LAYERS

  --system-message "MESSAGE"
      System message content used for all generations.
      Default: "Before answering, briefly list your reasoning steps using numbered bullets. Then give the final answer. Do not use Markdown."
      Env: LLM_SYSTEM_MESSAGE

  --endpoint ADDRESS
      LingoFuse IPC/TCP endpoint for the service.
      Default: ipc:llm_service
      Env: LINGOFUSE_ENDPOINT

  --app-name NAME
      Application name to register with LingoFuse.
      Default: LLM_Service
      Env: LINGOFUSE_APP_NAME

  --notify-api NAME
      Notify API name used for streaming chunks to clients.
      Default: llm_stream
      Env: LINGOFUSE_NOTIFY_API

  --timeout MS
      Timeout in milliseconds for API calls (not used for streaming).
      Default: 5000
      Env: LINGOFUSE_TIMEOUT_MS

  --session-timeout SECONDS
      Idle timeout for a generation session (currently informational).
      Default: 60
      Env: LLM_SESSION_TIMEOUT

  --log-level {0,1,2}
      Log verbosity level:
        0 = quiet (suppress chunk logs and warnings)
        1 = normal (show chunk logs, suppress warnings)
        2 = debug (show all logs including warnings)
      Default: 1
      Env: LLM_LOG_LEVEL

  --debug
      Shortcut for --log-level 2.
      Env: LLM_DEBUG (set to 1/true/yes)

  --quiet
      Shortcut for --log-level 0.
      Env: LLM_QUIET (set to 1/true/yes)

===============================================================================
EXAMPLES
===============================================================================
  # Start with default settings (requires model at ./qwen2.5-7b-instruct-q4_k_m.gguf)
  python llm_service.py

  # Use a custom model with increased context and different endpoint
  python llm_service.py --model-path ./models/llama-13b.gguf --context-size 8192 --endpoint ipc:my_llm

  # Set system message and GPU layers via environment
  export LLM_SYSTEM_MESSAGE="You are a helpful assistant."
  export LLM_GPU_LAYERS=40
  python llm_service.py

  # Enable debug logging (verbose)
  python llm_service.py --debug

  # Suppress runtime chunk logs (quiet mode)
  python llm_service.py --quiet

  # Set log level manually
  python llm_service.py --log-level 0

===============================================================================
DEPENDENCIES
===============================================================================
  Requires llama-cpp-python or transformers + torch.
  Ensure the LingoFuse library (LingoFuse64.dll / liblingofuse.so) is in your PATH.

===============================================================================
"""
import os
import sys
import json
import uuid
import argparse
import threading
import time
import atexit
import platform
from typing import Dict, Any, Optional, Tuple

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from lingofuse import Server, App, set_option, check_app
from lingofuse.core import DataHandle
from lingofuse._lf_native import (
    LF_Sequenced_Notify,
    LF_FreeData,
    LF_CheckApp,
    LF_GetStatusCount,
    LF_GetStatus,
)

# ----------------------------------------------------------------------
# LLM Backend Selection (unchanged)
# ----------------------------------------------------------------------
try:
    import llama_cpp
    LLM_BACKEND = "llama_cpp"
except ImportError:
    LLM_BACKEND = None
    print("[WARN] llama-cpp-python not installed, trying transformers...", file=sys.stderr)

if LLM_BACKEND is None:
    try:
        import transformers
        import torch
        LLM_BACKEND = "transformers"
    except ImportError:
        LLM_BACKEND = None
        print("[ERROR] No LLM backend available. Install llama-cpp-python or transformers.", file=sys.stderr)
        sys.exit(1)

# ----------------------------------------------------------------------
# Default configuration (may be overridden by env/CLI)
# ----------------------------------------------------------------------
DEFAULT_MODEL_PATH = "./qwen2.5-7b-instruct-q4_k_m.gguf"
DEFAULT_CONTEXT_SIZE = 32768
DEFAULT_MAX_TOKENS = 4096
DEFAULT_THREADS = 6
DEFAULT_GPU_LAYERS = -1
DEFAULT_SYSTEM_MESSAGE = (
    "Before answering, briefly list your reasoning steps using numbered bullets. "
    "Then give the final answer. Do not use Markdown."
)
DEFAULT_ENDPOINT = "ipc:llm_service"
DEFAULT_APP_NAME = "LLM_Service"
DEFAULT_NOTIFY_API = "llm_stream"
DEFAULT_TIMEOUT_MS = 5000
DEFAULT_SESSION_TIMEOUT = 60  # seconds: auto‑kill generation if no progress
DEFAULT_LOG_LEVEL = 0          # 0=quiet, 1=normal, 2=debug

# ----------------------------------------------------------------------
# Argument parsing (environment overrides)
# ----------------------------------------------------------------------
def parse_args():
    parser = argparse.ArgumentParser(
        description="LingoFuse LLM Service – multi‑session streaming server",
        epilog="All options can be overridden by environment variables (see the docstring for details)."
    )
    parser.add_argument(
        "--model-path",
        default=os.environ.get("LLM_MODEL_PATH", DEFAULT_MODEL_PATH),
        help=f"Path to the GGUF model file (or HF model directory). Default: {DEFAULT_MODEL_PATH}"
    )
    parser.add_argument(
        "--context-size",
        type=int,
        default=int(os.environ.get("LLM_CONTEXT_SIZE", str(DEFAULT_CONTEXT_SIZE))),
        help=f"Context window size in tokens. Default: {DEFAULT_CONTEXT_SIZE}"
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=int(os.environ.get("LLM_MAX_TOKENS", str(DEFAULT_MAX_TOKENS))),
        help=f"Maximum number of tokens to generate. Default: {DEFAULT_MAX_TOKENS}"
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=int(os.environ.get("LLM_THREADS", str(DEFAULT_THREADS))),
        help=f"Number of CPU threads (llama.cpp only). Default: {DEFAULT_THREADS}"
    )
    parser.add_argument(
        "--gpu-layers",
        type=int,
        default=int(os.environ.get("LLM_GPU_LAYERS", str(DEFAULT_GPU_LAYERS))),
        help=f"GPU layers to offload (-1=all, 0=CPU). Default: {DEFAULT_GPU_LAYERS}"
    )
    parser.add_argument(
        "--system-message",
        default=os.environ.get("LLM_SYSTEM_MESSAGE", DEFAULT_SYSTEM_MESSAGE),
        help=f"System message for generations. Default: {DEFAULT_SYSTEM_MESSAGE[:50]}..."
    )
    parser.add_argument(
        "--endpoint",
        default=os.environ.get("LINGOFUSE_ENDPOINT", DEFAULT_ENDPOINT),
        help=f"LingoFuse endpoint (IPC or TCP). Default: {DEFAULT_ENDPOINT}"
    )
    parser.add_argument(
        "--app-name",
        default=os.environ.get("LINGOFUSE_APP_NAME", DEFAULT_APP_NAME),
        help=f"Application name to register. Default: {DEFAULT_APP_NAME}"
    )
    parser.add_argument(
        "--notify-api",
        default=os.environ.get("LINGOFUSE_NOTIFY_API", DEFAULT_NOTIFY_API),
        help=f"Notify API name for streaming chunks. Default: {DEFAULT_NOTIFY_API}"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("LINGOFUSE_TIMEOUT_MS", str(DEFAULT_TIMEOUT_MS))),
        help=f"Call timeout in milliseconds. Default: {DEFAULT_TIMEOUT_MS}"
    )
    parser.add_argument(
        "--session-timeout",
        type=int,
        default=int(os.environ.get("LLM_SESSION_TIMEOUT", str(DEFAULT_SESSION_TIMEOUT))),
        help=f"Idle session timeout in seconds (informational). Default: {DEFAULT_SESSION_TIMEOUT}"
    )
    parser.add_argument(
        "--log-level",
        type=int,
        choices=[0, 1, 2],
        default=int(os.environ.get("LLM_LOG_LEVEL", str(DEFAULT_LOG_LEVEL))),
        help="Log verbosity: 0=quiet, 1=normal, 2=debug. Default: 1"
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        default=os.environ.get("LLM_DEBUG", "0").lower() in ("1", "true", "yes"),
        help="Shortcut for --log-level 2. Default: False"
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        default=os.environ.get("LLM_QUIET", "0").lower() in ("1", "true", "yes"),
        help="Shortcut for --log-level 0. Default: False"
    )
    return parser.parse_args()

# ----------------------------------------------------------------------
# LLM loader (same as original, with debug prints)
# ----------------------------------------------------------------------
def safe_get_attr(obj, attr):
    """
    Safely get an attribute from an object, handling callables.
    Used to retrieve model metadata without raising exceptions.
    """
    try:
        val = getattr(obj, attr)
        if callable(val):
            return val()
        return val
    except (AttributeError, TypeError):
        return None

def load_llm(model_path, context_size, threads, gpu_layers):
    """
    Load the LLM model using the detected backend (llama.cpp or transformers).
    Prints progress and metadata to stdout.
    Returns a tuple (model, tokenizer_or_none) where tokenizer_or_none is
    the tokenizer for transformers backend, or None for llama.cpp.
    """
    print("[LLM] Loading model... (this may take a few seconds)")
    print(f"[LLM] Model path: {model_path}")
    print(f"[LLM] Context size: {context_size}, threads: {threads}, GPU layers: {gpu_layers}")
    if LLM_BACKEND == "llama_cpp":
        print("[LLM] Using backend: llama-cpp-python")
        model = llama_cpp.Llama(
            model_path=model_path,
            n_ctx=context_size,
            n_threads=threads,
            n_gpu_layers=gpu_layers,
            verbose=False
        )
        # Print metadata (skip tokenizer.chat_template to avoid clutter)
        try:
            metadata = model.metadata
            if metadata:
                print("[LLM] Model metadata:")
                for k, v in metadata.items():
                    if k == "tokenizer.chat_template":
                        continue
                    print(f"    {k}: {v}")
        except AttributeError:
            pass
        # llama_cpp model does not provide a separate tokenizer; we'll use model.tokenize()
        return model, None
    elif LLM_BACKEND == "transformers":
        print("[LLM] Using backend: transformers")
        from transformers import AutoModelForCausalLM, AutoTokenizer
        tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
        model = AutoModelForCausalLM.from_pretrained(
            model_path,
            torch_dtype=torch.float16,
            device_map="auto",
            trust_remote_code=True
        )
        print(f"[LLM] Model loaded with device map: {model.hf_device_map}")
        return model, tokenizer
    else:
        raise RuntimeError("No LLM backend available")

# ----------------------------------------------------------------------
# Service class
# ----------------------------------------------------------------------
class LLMService:
    """
    Main service class that manages LLM generation and LingoFuse networking.

    Attributes:
        config (argparse.Namespace): parsed command-line arguments.
        system_message (str): current system message for all generations.
        backend (str): 'llama_cpp' or 'transformers'.
        llm: the loaded model object.
        tokenizer: tokenizer for transformers backend (or None).
        context_size (int): maximum context size in tokens.
        active_sessions (Dict[str, dict]): tracking of active generation sessions.
        server (Server): LingoFuse server instance.
        log_level (int): current log verbosity level (0,1,2).
        enable_chunk_logging (bool): whether to log each sent chunk.
        enable_warning_logging (bool): whether to log warnings (e.g., unreachable target).
    """
    def __init__(self, config: argparse.Namespace):
        self.config = config
        self.system_message = config.system_message
        self.backend = LLM_BACKEND

        # Set log level based on shortcuts and explicit value
        if config.debug:
            self.log_level = 2
        elif config.quiet:
            self.log_level = 0
        else:
            self.log_level = config.log_level

        self.enable_chunk_logging = self.log_level >= 1
        self.enable_warning_logging = self.log_level >= 2

        print("[LLM] Loading LLM...")
        load_start = time.time()
        self.llm, self.tokenizer = load_llm(
            config.model_path,
            config.context_size,
            config.threads,
            config.gpu_layers
        )
        # Store context size for safety checks
        self.context_size = config.context_size
        print(f"[LLM] Model loaded in {time.time() - load_start:.2f}s")
        print(f"[LLM] Maximum context size: {self.context_size} tokens")

        # Active session tracking (for logging / future cleanup)
        self.active_sessions: Dict[str, dict] = {}
        self._session_lock = threading.Lock()

        # Create Server and register APIs
        self.server = Server(config.app_name, "Local LLM Service with multi‑session streaming")
        self._register_apis()
        atexit.register(self.cleanup)

    def set_log_level(self, level: int) -> None:
        """
        Dynamically adjust the log verbosity at runtime.

        Args:
            level (int): 0 (quiet), 1 (normal), 2 (debug).
        """
        self.log_level = level
        self.enable_chunk_logging = level >= 1
        self.enable_warning_logging = level >= 2
        print(f"[Service] Log level set to {level}")

    def _register_apis(self):
        """Register the 'generate' and 'set_system_message' Call APIs."""
        @self.server.expose("generate")
        def generate(data: dict) -> dict:
            content = data.get("content", "")
            prompt = data.get("prompt", "")
            client_name = data.get("client_name")
            if not content and not prompt:
                return {"code": -1, "error": "Missing content or prompt"}
            if not client_name:
                return {"code": -1, "error": "Missing client_name (must be generated via generate_app_name())"}

            # Safety check: estimate token count before starting generation
            full_input = content + "\n\n" + prompt
            estimated_tokens = self._estimate_tokens(full_input) + self._estimate_tokens(self.system_message)
            if estimated_tokens > self.context_size * 0.9:  # 90% safety margin
                return {
                    "code": -1,
                    "error": f"Input too long: estimated {estimated_tokens} tokens, max allowed {int(self.context_size * 0.9)}"
                }

            session_id = str(uuid.uuid4())
            # Store session info
            with self._session_lock:
                self.active_sessions[session_id] = {
                    "client_name": client_name,
                    "start_time": time.time(),
                    "status": "running"
                }

            print(f"[Service] New session {session_id} for client {client_name}")

            # Start generation in a separate thread
            threading.Thread(
                target=self._stream_generate,
                args=(session_id, client_name, content, prompt),
                daemon=True
            ).start()

            return {"code": 0, "session_id": session_id}

        @self.server.expose("set_system_message")
        def set_system_message(data: dict) -> dict:
            new_msg = data.get("content")
            if new_msg is None:
                return {"code": -1, "error": "Missing 'content' field"}
            self.system_message = new_msg
            print(f"[Service] System message updated: {new_msg[:50]}...")
            return {"code": 0, "status": "ok"}

        print("[Service] Registered APIs: 'generate', 'set_system_message'")

    def _estimate_tokens(self, text: str) -> int:
        """
        Estimate the token count of a text string.
        For llama.cpp, we use the model's tokenize method (if available).
        For transformers, we use the tokenizer.
        Fallback to character count / 4 as a rough approximation.
        """
        if self.backend == "llama_cpp" and hasattr(self.llm, "tokenize"):
            try:
                # llama-cpp-python tokenize returns a list of token IDs
                tokens = self.llm.tokenize(text.encode("utf-8"))
                return len(tokens)
            except Exception:
                pass
        elif self.backend == "transformers" and self.tokenizer is not None:
            try:
                return len(self.tokenizer.encode(text))
            except Exception:
                pass
        # Fallback: rough estimate (1 token ≈ 4 characters for English/Chinese mix)
        return len(text) // 4 + 1

    def _stream_generate(self, session_id: str, client_name: str, content: str, prompt: str):
        """
        Stream tokens to the given client_name via sequenced notifications.
        Logs progress and errors according to the current log level.
        """
        full_input = content + "\n\n" + prompt
        print(f"[Session {session_id}] Started generation for client {client_name}")
        try:
            # Prepare messages with system message
            messages = [
                {"role": "system", "content": self.system_message},
                {"role": "user", "content": full_input}
            ]

            if self.backend == "llama_cpp":
                # Use create_chat_completion with streaming
                stream = self.llm.create_chat_completion(
                    messages=messages,
                    stream=True,
                    max_tokens=self.config.max_tokens
                )
                for chunk in stream:
                    if "choices" in chunk:
                        delta = chunk["choices"][0].get("delta", {})
                        text = delta.get("content", "")
                        if text:
                            self._send_chunk(session_id, client_name, text)
            elif self.backend == "transformers":
                # Placeholder: transformers streaming is not implemented here
                self._send_chunk(session_id, client_name, "__ERROR__: transformers streaming not fully implemented")
            # End of stream
            self._send_chunk(session_id, client_name, "__FINISH__")
            print(f"[Session {session_id}] Generation finished successfully")
        except Exception as e:
            error_msg = str(e)
            # Check for common CUDA / OOM errors
            if "CUDA out of memory" in error_msg or "out of memory" in error_msg.lower():
                error_msg = "CUDA out of memory – input too long or model too large for GPU"
            elif "context" in error_msg.lower() and "length" in error_msg.lower():
                error_msg = f"Context length exceeded – maximum context size: {self.context_size} tokens"
            print(f"[Session {session_id}] Generation error: {error_msg}")
            # Send error to client
            self._send_chunk(session_id, client_name, f"__ERROR__: {error_msg}")
        finally:
            # Remove session from active tracking
            with self._session_lock:
                self.active_sessions.pop(session_id, None)

    def _send_chunk(self, session_id: str, client_name: str, text: str):
        """
        Send a JSON payload as a sequenced notification to the client app.
        Uses DataHandle.write_json for standardized encoding.
        Logging depends on the current log level settings.
        """
        payload = {"session_id": session_id, "chunk": text}
        hnd = DataHandle(self.config.notify_api)
        hnd.write_json(payload)

        # Log chunk only if enabled
        if self.enable_chunk_logging:
            # Check target reachability (only if warning logging is enabled)
            if self.enable_warning_logging and not check_app(client_name):
                print(f"[Session {session_id}] WARNING: Target client app '{client_name}' not reachable")
            json_line = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
            print(f"[Session {session_id}] Sent chunk: {json_line}")

        LF_Sequenced_Notify(client_name.encode("utf-8"), hnd.raw)
        hnd.free()  # explicit free

    def cleanup(self):
        """Stop the server and release resources (model, etc.)."""
        self.server.stop()
        # Close model if possible
        try:
            if hasattr(self.llm, 'close'):
                self.llm.close()
        except Exception:
            pass
        print("[Service] Cleanup complete")

def print_service_status(config):
    """Print a summary of the service configuration."""
    lines = [
        "=" * 70,
        " LINGOFUSE LLM SERVICE STATUS",
        "=" * 70,
        f"  Backend               : {LLM_BACKEND}",
        f"  Model path            : {config.model_path}",
        f"  Context size          : {config.context_size}",
        f"  Max tokens            : {config.max_tokens}",
        f"  CPU threads           : {config.threads}",
        f"  GPU layers offloaded  : {config.gpu_layers}",
        f"  System message        : {config.system_message[:50]}...",
        f"  LingoFuse endpoint    : {config.endpoint}",
        f"  Service app name      : {config.app_name}",
        f"  Notify API name       : {config.notify_api}",
        f"  Session timeout (s)   : {config.session_timeout}",
        f"  Log level             : {config.log_level}",
        "=" * 70
    ]
    print("\n".join(lines))

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    args = parse_args()
    if args.debug:
        print("[DEBUG] Configuration:", file=sys.stderr)
        for k, v in vars(args).items():
            print(f"  {k} = {v}", file=sys.stderr)

    if not os.path.exists(args.model_path):
        print(f"[ERROR] Model file not found: {args.model_path}", file=sys.stderr)
        sys.exit(1)

    service = LLMService(args)
    print_service_status(args)

    try:
        # Start server (will prepare service and client internally)
        service.server.start(args.endpoint)
        print(f"[Service] LLM Service is running on {args.endpoint}")
        print("[Service] Press Ctrl+C to stop...")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[Service] Shutting down...")
    finally:
        service.cleanup()

if __name__ == "__main__":
    main()