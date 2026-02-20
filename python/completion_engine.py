"""Completion payload builder and Ollama client wrapper for cursor-local autocomplete."""

from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Optional

import ollama


class CompletionEngine:
    """Builds suffix-aware completion payloads and streams completions from Ollama."""

    def __init__(self, model: str, client_url: str = "http://localhost:11434", options: Optional[Dict[str, Any]] = None):
        """Initialize engine with model, Ollama endpoint, and generation controls."""
        self.model = model
        self.client = ollama.Client(client_url)
        self.options = options or {}

        self.fim_enabled = self.options.pop("fim_enabled", True)
        self.fim_mode = self.options.pop("fim_mode", "auto")
        self.context_lines_before = int(self.options.pop("context_lines_before", 80))
        self.context_lines_after = int(self.options.pop("context_lines_after", 40))
        self.max_prefix_chars = int(self.options.pop("max_prefix_chars", 8000))
        self.max_suffix_chars = int(self.options.pop("max_suffix_chars", 3000))

        # Debugging can be toggled with init option or env vars.
        self.debug = bool(self.options.pop("debug", False)) or os.getenv("OLLAMA_COPILOT_DEBUG", "") == "1"
        self.debug_log_file = self.options.pop("debug_log_file", None) or os.getenv(
            "OLLAMA_COPILOT_DEBUG_LOG",
            "/tmp/ollama-copilot-debug.log",
        )

    def complete(self, lines: List[str], line: int, character: int, filetype: str = ""):
        """Stream completion tokens for the insertion point using FIM when enabled."""
        payload = self.build_request_payload(lines=lines, line=line, character=character, filetype=filetype)
        self._debug_log("payload", payload)

        try:
            stream = self.client.generate(**payload)
            return self._debug_stream(stream)
        except TypeError as exc:
            # Fallback for older Ollama python client versions without `suffix` support.
            if "suffix" not in str(exc):
                raise
            fallback_payload = self.build_request_payload(
                lines=lines,
                line=line,
                character=character,
                filetype=filetype,
                force_manual_fim=True,
            )
            self._debug_log("payload_fallback", fallback_payload)
            stream = self.client.generate(**fallback_payload)
            return self._debug_stream(stream)

    def build_request_payload(
        self,
        lines: List[str],
        line: int,
        character: int,
        filetype: str = "",
        force_manual_fim: bool = False,
    ) -> Dict[str, Any]:
        """Construct Ollama `generate` payload with prompt/suffix and constrained options."""
        prefix, suffix, local_indent = self._split_prefix_suffix(lines=lines, line=line, character=character)
        centered_prefix = self._centered_prefix(lines=lines, line=line, character=character, filetype=filetype, indent=local_indent)

        payload: Dict[str, Any] = {
            "model": self.model,
            "stream": True,
            "options": self.options,
        }

        use_template_fim = self.fim_enabled and not force_manual_fim and self.fim_mode in ("auto", "template")

        if use_template_fim:
            payload["prompt"] = prefix[-self.max_prefix_chars :]
            payload["suffix"] = suffix[: self.max_suffix_chars]
            return payload

        if self.fim_enabled:
            payload["prompt"] = self._manual_fim_prompt(prefix[-self.max_prefix_chars :], suffix)
            return payload

        payload["prompt"] = centered_prefix + "\n"
        return payload

    def _split_prefix_suffix(self, lines: List[str], line: int, character: int) -> tuple[str, str, str]:
        """Return full-document prefix and suffix split at cursor, plus local indent."""
        bounded_line = max(0, min(line, len(lines) - 1)) if lines else 0
        current_line = lines[bounded_line] if lines else ""
        bounded_character = max(0, min(character, len(current_line)))

        left = current_line[:bounded_character]
        right = current_line[bounded_character:]
        indent = left[: len(left) - len(left.lstrip(" \t"))]

        prefix = "\n".join(lines[:bounded_line])
        prefix = f"{prefix}\n{left}" if prefix else left
        suffix = right
        if bounded_line + 1 < len(lines):
            suffix = f"{suffix}\n" + "\n".join(lines[bounded_line + 1 :])

        return prefix, suffix, indent

    def _centered_prefix(self, lines: List[str], line: int, character: int, filetype: str, indent: str) -> str:
        """Build a cursor-local instruction block with bounded surrounding context."""
        if not lines:
            lines = [""]

        bounded_line = max(0, min(line, len(lines) - 1))
        current_line = lines[bounded_line]
        bounded_character = max(0, min(character, len(current_line)))

        start = max(0, bounded_line - self.context_lines_before)
        before_lines = lines[start:bounded_line]
        line_prefix = current_line[:bounded_character]
        line_suffix = current_line[bounded_character:]

        before_text = "\n".join(before_lines)
        if len(before_text) > self.max_prefix_chars:
            before_text = before_text[-self.max_prefix_chars :]

        return (
            "[AUTOCOMPLETE_TASK]\n"
            "Return ONLY the exact text to insert at <CURSOR>.\n"
            "Do not restate existing text. Do not explain. Do not use markdown fences.\n"
            f"filetype={filetype or 'plain'}\n"
            f"indentation={json.dumps(indent)}\n"
            "[PREFIX_BEFORE_CURSOR]\n"
            f"{before_text}\n"
            "[CURRENT_LINE_PREFIX]\n"
            f"{line_prefix}\n"
            "[CURRENT_LINE_SUFFIX]\n"
            f"{line_suffix}\n"
            "[INSERT_AT_CURSOR]\n"
        )

    def _manual_fim_prompt(self, prefix: str, suffix: str) -> str:
        """Construct model-native manual FIM wrapper for models expecting special tokens."""
        bounded_suffix = suffix[: self.max_suffix_chars]
        return f"<|fim_prefix|>{prefix}<|fim_suffix|>{bounded_suffix}<|fim_middle|>"

    def _debug_stream(self, stream):
        """Wrap stream iterator and log raw chunks when debug mode is enabled."""
        def iterator():
            for chunk in stream:
                normalized_chunk = self._normalize_chunk(chunk)
                if self.debug:
                    self._debug_log("raw_chunk", normalized_chunk)
                yield normalized_chunk

        return iterator()

    def _normalize_chunk(self, chunk: Any) -> Dict[str, Any]:
        """Convert Ollama SDK response chunks into plain dicts for stable indexing."""
        if isinstance(chunk, dict):
            return chunk
        if hasattr(chunk, "model_dump"):
            return chunk.model_dump()
        if hasattr(chunk, "dict"):
            return chunk.dict()
        return {"response": str(chunk)}

    def _debug_log(self, event: str, payload: Any) -> None:
        """Append debug records to a local log file without disturbing stdio LSP traffic."""
        if not self.debug:
            return

        serializable_payload = payload
        if hasattr(payload, "model_dump"):
            serializable_payload = payload.model_dump()
        elif hasattr(payload, "dict"):
            serializable_payload = payload.dict()

        try:
            with open(self.debug_log_file, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"event": event, "payload": serializable_payload}, default=str))
                handle.write("\n")
        except Exception:
            # Debug logging must never break completions.
            return
