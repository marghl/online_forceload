#!/usr/bin/env python3
"""Statically validate Online Forceload translation catalogs."""

from __future__ import annotations

import ast
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "init.lua"
LOCALE_DIR = ROOT / "locale"
EXPECTED_LANGUAGES = {
    "cs", "de", "en", "es", "fr", "it", "nl",
    "pl", "pt", "ro", "ru", "sv", "uk",
}
AI_LANGUAGES = EXPECTED_LANGUAGES - {"de"}
AI_MARKERS = ("AI", "IA", "SI", "ИИ", "ШІ")
TRANSLATION_CALL = re.compile(r'\bS\(\s*("(?:\\.|[^"\\])*")')
PLACEHOLDER = re.compile(r"@\d+")


def source_keys() -> set[str]:
    text = SOURCE.read_text(encoding="utf-8")
    return {ast.literal_eval(match.group(1)) for match in TRANSLATION_CALL.finditer(text)}


def read_catalog(path: Path, errors: list[str]) -> tuple[dict[str, str], list[str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as exc:
        errors.append(f"{path.name}: invalid UTF-8: {exc}")
        return {}, []

    entries: dict[str, str] = {}
    for number, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            errors.append(f"{path.name}:{number}: expected key=value")
            continue
        key, value = line.split("=", 1)
        if key in entries:
            errors.append(f"{path.name}:{number}: duplicate key: {key}")
        entries[key] = value
    return entries, lines


def main() -> int:
    errors: list[str] = []
    expected_keys = source_keys()
    catalogs = {path.name.removeprefix("online_forceload.").removesuffix(".tr"): path
                for path in LOCALE_DIR.glob("online_forceload.*.tr")}

    missing_languages = EXPECTED_LANGUAGES - catalogs.keys()
    unexpected_languages = catalogs.keys() - EXPECTED_LANGUAGES
    if missing_languages:
        errors.append("missing catalogs: " + ", ".join(sorted(missing_languages)))
    if unexpected_languages:
        errors.append("unexpected catalogs: " + ", ".join(sorted(unexpected_languages)))

    for language in sorted(EXPECTED_LANGUAGES & catalogs.keys()):
        path = catalogs[language]
        entries, lines = read_catalog(path, errors)
        missing_keys = expected_keys - entries.keys()
        stale_keys = entries.keys() - expected_keys
        if missing_keys:
            errors.append(f"{path.name}: missing keys: " + ", ".join(sorted(missing_keys)))
        if stale_keys:
            errors.append(f"{path.name}: stale keys: " + ", ".join(sorted(stale_keys)))

        for key in sorted(expected_keys & entries.keys()):
            value = entries[key]
            if not value.strip():
                errors.append(f"{path.name}: empty translation: {key}")
            source_placeholders = Counter(PLACEHOLDER.findall(key))
            translated_placeholders = Counter(PLACEHOLDER.findall(value))
            if source_placeholders != translated_placeholders:
                errors.append(
                    f"{path.name}: placeholder mismatch for {key!r}: "
                    f"expected {dict(source_placeholders)}, got {dict(translated_placeholders)}"
                )

        if language in AI_LANGUAGES:
            comments = "\n".join(line for line in lines if line.startswith("#"))
            if not any(marker in comments for marker in AI_MARKERS):
                errors.append(f"{path.name}: missing AI-generated translation comment")

    if errors:
        print("Locale validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        f"Locale validation passed: {len(catalogs)} catalogs, "
        f"{len(expected_keys)} source strings."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
