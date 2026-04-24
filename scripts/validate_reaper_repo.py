from __future__ import annotations

from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parent.parent
README_PATH = REPO_ROOT / "README.md"
VALID_TOP_LEVEL_SUFFIXES = {".lua", ".py", ".jsfx", ".md"}
JSFX_HEADER_PATTERN = re.compile(r"^\s*desc\s*:", re.IGNORECASE)
REA_SCRIPT_HEADER_PATTERN = re.compile(r"^\s*--\s*@description\b")


def fail(message: str) -> None:
    print(f"ERROR: {message}")
    sys.exit(1)


def collect_top_level_files() -> list[Path]:
    files = [path for path in REPO_ROOT.iterdir() if path.is_file()]
    unexpected = [
        path.name
        for path in files
        if path.suffix.lower() not in VALID_TOP_LEVEL_SUFFIXES and path.name != ".gitignore"
    ]
    if unexpected:
        fail(
            "Unexpected top-level files found: "
            + ", ".join(sorted(unexpected))
            + ". Update the validator if these are intentional."
        )
    return sorted(files)


def validate_jsfx_headers(files: list[Path]) -> None:
    jsfx_files = [path for path in files if path.suffix.lower() == ".jsfx"]
    for path in jsfx_files:
      content = path.read_text(encoding="utf-8", errors="replace")
      if not JSFX_HEADER_PATTERN.search(content):
          fail(f"{path.name} is missing a JSFX 'desc:' header.")


def validate_lua_headers(files: list[Path]) -> None:
    lua_files = [path for path in files if path.suffix.lower() == ".lua"]
    missing = []
    for path in lua_files:
        content = path.read_text(encoding="utf-8", errors="replace")
        if "reaper." not in content:
            continue
        if not REA_SCRIPT_HEADER_PATTERN.search(content):
            missing.append(path.name)
    if missing:
        fail(
            "These Lua ReaScripts are missing a '-- @description' header: "
            + ", ".join(sorted(missing))
        )


def validate_readme(files: list[Path]) -> None:
    if not README_PATH.exists():
        fail("README.md is missing.")

    readme = README_PATH.read_text(encoding="utf-8", errors="replace")
    required_sections = [
        "## Installation in REAPER",
        "## Voraussetzungen",
    ]
    missing = [section for section in required_sections if section not in readme]
    if missing:
        fail(
            "README.md is missing required sections: "
            + ", ".join(missing)
        )


def main() -> None:
    files = collect_top_level_files()
    validate_jsfx_headers(files)
    validate_lua_headers(files)
    validate_readme(files)
    print("Repository validation passed.")


if __name__ == "__main__":
    main()
