#!/usr/bin/env python3
"""Upsert one SMTP password into /etc/pve/priv/notifications.cfg.

pvesh only accepts --password on argv, which leaks via ps. This file is the
documented secret store (root-only on pmxcfs). The password arrives in the
process environment, not in argv.
"""
from __future__ import annotations

import os
import pathlib
import sys

PRIV_PATH = pathlib.Path("/etc/pve/priv/notifications.cfg")


def parse_blocks(text: str) -> list[list[str]]:
    """Split a pve config file into header+body blocks."""
    blocks: list[list[str]] = []
    current: list[str] = []
    for line in text.splitlines(keepends=True):
        starts_section = bool(line.strip()) and not line[0].isspace() and not line.lstrip().startswith(
            "#"
        )
        if current and starts_section:
            blocks.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        blocks.append(current)
    return blocks


def header_of(block: list[str]) -> str:
    for line in block:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return stripped
    return ""


def desired_block(kind: str, name: str, password: str) -> list[str]:
    return [f"{kind}: {name}\n", f"\tpassword {password}\n"]


def upsert(text: str, kind: str, name: str, password: str) -> tuple[str, bool]:
    target = f"{kind}: {name}"
    new_block = desired_block(kind, name, password)
    if not text.strip():
        return "".join(new_block), True

    blocks = parse_blocks(text)
    found = False
    out: list[str] = []
    changed = False
    for block in blocks:
        if header_of(block) == target:
            found = True
            if block != new_block:
                changed = True
            out.append(new_block)
        else:
            out.append(block)
    if not found:
        if out and out[-1] and not out[-1][-1].endswith("\n"):
            out[-1][-1] += "\n"
        out.append(new_block)
        changed = True
    rendered = "".join("".join(block) for block in out)
    if not rendered.endswith("\n"):
        rendered += "\n"
        changed = True
    return rendered, changed


def main() -> int:
    name = os.environ.get("PVE_SMTP_ENDPOINT", "").strip()
    password = os.environ.get("PVE_SMTP_PASSWORD", "").strip()
    write = os.environ.get("PVE_SMTP_PRIV_WRITE", "0") == "1"
    if not name or not password:
        print("PVE_SMTP_ENDPOINT and PVE_SMTP_PASSWORD must be non-empty", file=sys.stderr)
        return 2
    if "\n" in password or "\r" in password:
        print("password must be a single line", file=sys.stderr)
        return 2

    current = PRIV_PATH.read_text() if PRIV_PATH.exists() else ""
    rendered, changed = upsert(current, "smtp", name, password)
    if write and changed:
        PRIV_PATH.write_text(rendered)
    print("changed" if changed else "unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
