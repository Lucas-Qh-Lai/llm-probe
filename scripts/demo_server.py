#!/usr/bin/env python3
"""A tiny offline OpenAI-compatible server used for demos, screenshots and tests.

It serves entirely fictional data ("Acme AI") so documentation and screenshots can
show a realistic dashboard without exposing anyone's real endpoints, model ids or
credentials.

Capabilities it implements, so every probe has something to measure:

* ``GET  /v1/models``                 catalog with context/output limits
* ``POST /v1/chat/completions``       text, streaming, tool calls, vision, JSON
* ``POST /v1/responses``              minimal Responses API shape
* ``POST /v1/embeddings``             deterministic fake vectors

Usage:
    python3 scripts/demo_server.py --port 8899
"""

from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

MODELS: list[dict[str, Any]] = [
    {
        "id": "demo-large-1",
        "display_name": "Demo Large 1",
        "context_window": 1_000_000,
        "max_output_tokens": 65_536,
        "modalities": ["text", "image"],
        "supports_tools": True,
        "owned_by": "acme-ai",
    },
    {
        "id": "demo-small-1",
        "display_name": "Demo Small 1",
        "context_window": 131_072,
        "max_output_tokens": 16_384,
        "modalities": ["text"],
        "supports_tools": True,
        "owned_by": "acme-ai",
    },
    {
        "id": "demo-reasoner-1",
        "display_name": "Demo Reasoner 1",
        "context_window": 262_144,
        "max_output_tokens": 32_768,
        "modalities": ["text"],
        "supports_tools": False,
        "owned_by": "acme-ai",
    },
]

DEFAULT_MODEL = "demo-large-1"
TTFT_SECONDS = 0.17
CHUNK_SECONDS = 0.018


def newest_model(requested: str) -> dict[str, Any]:
    for model in MODELS:
        if model["id"] == requested:
            return model
    return MODELS[0]


def message_text(messages: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for message in messages:
        content = message.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and isinstance(block.get("text"), str):
                    parts.append(block["text"])
    return "\n".join(parts)


def has_image(messages: list[dict[str, Any]]) -> bool:
    for message in messages:
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") in ("image_url", "input_image", "image"):
                    return True
    return False


def token_estimate(text: str) -> int:
    return max(1, len(text) // 4)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # quieter logs
        if self.server.verbose:  # type: ignore[attr-defined]
            super().log_message(fmt, *args)

    # MARK: - helpers

    def send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, message: str, status: int = 400, code: str = "invalid_request_error") -> None:
        self.send_json({"error": {"message": message, "type": code, "code": code}}, status=status)

    def read_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode())
        except json.JSONDecodeError:
            return {}

    # MARK: - routes

    def do_GET(self) -> None:
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            self.send_json({
                "object": "list",
                "data": [
                    {
                        "id": model["id"],
                        "object": "model",
                        "created": 0,
                        "owned_by": model["owned_by"],
                        "display_name": model["display_name"],
                        "context_window": model["context_window"],
                        "max_output_tokens": model["max_output_tokens"],
                        "modalities": model["modalities"],
                        "supports_tools": model["supports_tools"],
                    }
                    for model in MODELS
                ],
            })
            return
        self.send_error_json("Not found", status=404, code="not_found")

    def do_POST(self) -> None:
        path = self.path.split("?")[0].rstrip("/")
        if path in ("/v1/chat/completions", "/chat/completions"):
            self.handle_chat()
        elif path in ("/v1/responses", "/responses"):
            self.handle_responses()
        elif path in ("/v1/embeddings", "/embeddings"):
            self.handle_embeddings()
        else:
            self.send_error_json("Not found", status=404, code="not_found")

    def handle_embeddings(self) -> None:
        body = self.read_body()
        model = newest_model(body.get("model", DEFAULT_MODEL))
        self.send_json({
            "object": "list",
            "model": model["id"],
            "data": [{"object": "embedding", "index": 0, "embedding": [0.01 * (i % 7) for i in range(64)]}],
            "usage": {"prompt_tokens": 2, "total_tokens": 2},
        })

    def handle_chat(self) -> None:
        body = self.read_body()
        model = newest_model(body.get("model", DEFAULT_MODEL))
        messages = body.get("messages") or []
        tools = body.get("tools") or []
        tool_choice = body.get("tool_choice")
        streaming = bool(body.get("stream"))
        prompt = message_text(messages)

        requested_max = body.get("max_tokens") or body.get("max_completion_tokens")
        if isinstance(requested_max, int) and requested_max > model["max_output_tokens"]:
            self.send_error_json(
                f"max_tokens: {requested_max} > {model['max_output_tokens']}, "
                f"which is the maximum allowed number of output tokens for {model['id']}",
                status=400,
            )
            return

        # Tool calling: answer with both tools so parallel calling is measurable.
        if tools and tool_choice in ("required", "any"):
            calls = []
            for index, tool in enumerate(tools):
                name = tool.get("function", {}).get("name") if "function" in tool else tool.get("name")
                if name is None:
                    continue
                arguments = {"status_token": "OK-1234"} if "status" in name else {"value": 7}
                calls.append({
                    "id": f"call_demo_{index}",
                    "type": "function",
                    "function": {"name": name, "arguments": json.dumps(arguments)},
                })
            if calls:
                payload = {
                    "id": "chatcmpl-demo-tool",
                    "object": "chat.completion",
                    "created": int(time.time()),
                    "model": model["id"],
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": None, "tool_calls": calls},
                        "finish_reason": "tool_calls",
                    }],
                    "usage": {"prompt_tokens": token_estimate(prompt), "completion_tokens": 36, "total_tokens": token_estimate(prompt) + 36},
                }
                self.send_json(payload)
                return

        # Structured output.
        response_format = body.get("response_format") or {}
        wants_json = bool(response_format) or bool(body.get("force_json"))

        # Vision.
        if has_image(messages):
            text = "red"
        elif wants_json:
            text = json.dumps({"status": "ok", "value": 7})
        elif "r" in prompt.lower() and "strawberry" in prompt.lower():
            text = "The letter r appears three times in strawberry."
        elif prompt.strip().lower().startswith("count from 1 to 24"):
            text = " ".join(str(number) for number in range(1, 25))
        elif "report" in prompt.lower() and tools:
            text = "I would call the tool."
        else:
            text = "ok"

        output_tokens = max(1, token_estimate(text))
        input_tokens = token_estimate(prompt)

        if not streaming:
            self.send_json({
                "id": "chatcmpl-demo",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model["id"],
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": input_tokens, "completion_tokens": output_tokens, "total_tokens": input_tokens + output_tokens},
            })
            return

        self.stream_chat(model, text, input_tokens, output_tokens)

    def stream_chat(self, model: dict[str, Any], text: str, input_tokens: int, output_tokens: int) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        # No Content-Length: the end of the stream is signalled by closing the
        # connection, which is what an SSE client expects.
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def emit(payload: dict[str, Any]) -> None:
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        created = int(time.time())
        emit({
            "id": "chatcmpl-demo-stream",
            "object": "chat.completion.chunk",
            "created": created,
            "model": model["id"],
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}],
        })

        time.sleep(TTFT_SECONDS)
        # Emit word by word so the probe can timestamp each delta.
        words = text.split(" ") if text else [""]
        for word in words:
            emit({
                "id": "chatcmpl-demo-stream",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model["id"],
                "choices": [{"index": 0, "delta": {"content": word + " "}, "finish_reason": None}],
            })
            time.sleep(CHUNK_SECONDS)

        emit({
            "id": "chatcmpl-demo-stream",
            "object": "chat.completion.chunk",
            "created": created,
            "model": model["id"],
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": input_tokens, "completion_tokens": output_tokens, "total_tokens": input_tokens + output_tokens},
        })
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def handle_responses(self) -> None:
        body = self.read_body()
        model = newest_model(body.get("model", DEFAULT_MODEL))
        text = "ok"
        self.send_json({
            "id": "resp_demo",
            "object": "response",
            "created_at": int(time.time()),
            "status": "completed",
            "error": None,
            "model": model["id"],
            "output": [
                {
                    "type": "reasoning",
                    "id": "rs_demo",
                    "summary": [{"type": "summary_text", "text": "Deciding on the shortest valid answer."}],
                },
                {
                    "type": "message",
                    "id": "msg_demo",
                    "role": "assistant",
                    "status": "completed",
                    "content": [{"type": "output_text", "text": text, "annotations": []}],
                },
            ],
            "output_text": text,
            "usage": {"input_tokens": 12, "output_tokens": 2, "total_tokens": 14},
        })


def main() -> None:
    parser = argparse.ArgumentParser(description="Offline demo server for LLMProbe")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.verbose = args.verbose  # type: ignore[attr-defined]
    print(f"Demo server listening on http://{args.host}:{args.port}/v1")
    print("All data is fictional (Acme AI). Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
