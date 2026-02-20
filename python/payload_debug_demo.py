"""Minimal reproducible payload demo for cursor-local FIM autocomplete prompts."""

from __future__ import annotations

import json

from completion_engine import CompletionEngine


def print_demo_payload() -> None:
    """Build and print representative payloads and expected completion behavior."""
    mock_lines = [
        "When modifying code:",
        "- Before planning or writing any new code, ALWAYS perform at least a quick scan",
        "  of the existing project/codebase to understand what logic already exists.",
        "- Ask clarifying questions when needed to resolve ambiguity or conflict.",
        "- Adhere to SOLID principles when they improve clarity or testability.",
        "- Bias toward cohesion and locality.",
        "- ",
    ]

    # Cursor at the end of the final bullet starter.
    line = 6
    character = 2

    engine = CompletionEngine(
        model="qwen2.5-coder:3b",
        options={
            "temperature": 0.1,
            "top_p": 0.9,
            "num_predict": 128,
            "num_ctx": 8192,
            "fim_enabled": True,
            "fim_mode": "auto",
            "context_lines_before": 20,
            "context_lines_after": 20,
            "max_prefix_chars": 4000,
            "max_suffix_chars": 2000,
        },
    )

    payload = engine.build_request_payload(
        lines=mock_lines,
        line=line,
        character=character,
        filetype="markdown",
    )

    print("=== Payload ===")
    print(json.dumps(payload, indent=2))
    print("\n=== Expected completion shape ===")
    print("Prefer a short, local insertion such as:")
    print("  Prefer domain-aligned code and prioritize clarity of intent.")
    print("Not acceptable: rewriting prior bullets into prose paragraphs.")

    suffix_lines = [
        "local function build(x, y)",
        "  local result = x ",
        "  return result",
        "end",
    ]
    suffix_payload = engine.build_request_payload(
        lines=suffix_lines,
        line=1,
        character=17,  # Cursor before `x ` so payload includes non-empty suffix.
        filetype="lua",
    )
    print("\n=== Payload with suffix context ===")
    print(json.dumps(suffix_payload, indent=2))


if __name__ == "__main__":
    print_demo_payload()
