#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman

"""Small lexical helpers shared by source-only host regressions."""

import re


_PREPROCESSOR_DIRECTIVE = re.compile(
    r"^[ \t]*#[ \t]*(if|ifdef|ifndef|elif|else|endif)\b(?:[ \t]+(.*?))?[ \t]*$")


def update_preprocessor_stack(stack, line):
    """Update condition frames; return (is_directive, error)."""
    match = _PREPROCESSOR_DIRECTIVE.match(line)
    if not match:
        return False, None
    operation = match.group(1)
    argument = (match.group(2) or "").strip()
    if operation in ("if", "ifdef", "ifndef"):
        stack.append((operation, argument, False))
    elif operation in ("elif", "else"):
        if not stack:
            return True, "unmatched #" + operation
        kind, condition, unused = stack[-1]
        stack[-1] = (kind, condition, True)
    elif not stack:
        return True, "unmatched #endif"
    else:
        stack.pop()
    return True, None


def strip_c_comments(source):
    # Translation phase 2 removes splices before phase 3 recognizes comments.
    source = re.sub(r"\\\r?\n", "", source)
    result = []
    state = "code"
    escaped = False
    index = 0
    while index < len(source):
        char = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

        if state == "line-comment":
            if char == "\n":
                result.append(char)
                state = "code"
            else:
                result.append(" ")
        elif state == "block-comment":
            if char == "*" and following == "/":
                result.extend((" ", " "))
                index += 1
                state = "code"
            else:
                result.append("\n" if char == "\n" else " ")
        elif state in ("string", "character"):
            result.append(char)
            quote = '"' if state == "string" else "'"
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                state = "code"
        elif char == "/" and following == "/":
            result.extend((" ", " "))
            index += 1
            state = "line-comment"
        elif char == "/" and following == "*":
            result.extend((" ", " "))
            index += 1
            state = "block-comment"
        else:
            result.append(char)
            if char == '"':
                state = "string"
            elif char == "'":
                state = "character"
        index += 1
    return "".join(result)


def normalized_c_code(source):
    """Remove insignificant whitespace outside C string and character literals."""
    result = []
    quote = None
    escaped = False
    for char in source:
        if quote is not None:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in ('"', "'"):
            quote = char
            result.append(char)
        elif not char.isspace():
            result.append(char)
    return "".join(result)
