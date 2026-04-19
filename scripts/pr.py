#!/usr/bin/env python3
"""
scripts/pr.py — commit → push → PR in the nullclaw #622 bilingual format.

Usage (interactive):
    python3 scripts/pr.py

Usage (non-interactive, all flags):
    python3 scripts/pr.py \
        --files src/foo.zig src/bar.zig \
        --commit "fix(agent): correct tool name recovery" \
        --title-en "fix(agent): correct tool name recovery" \
        --title-zh "修复(agent): 修正工具名称恢复" \
        --en "Fixed X" "Updated Y" \
        --zh "修复了 X" "更新了 Y" \
        --validation "zig build test: 6600 pass" \
        --notes "Closes #123"

Omit any flag to be prompted for that section interactively.
Pass --files as a space-separated list; omit to stage all tracked changes (git add -u).
"""

import argparse
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path


REPO = "nullclaw/nullclaw"


# ── helpers ──────────────────────────────────────────────────────────────────

def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def current_branch() -> str:
    return run(["git", "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()


def prompt(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    val = input(f"{label}{suffix}: ").strip()
    return val or default


def prompt_bullets(label: str) -> list[str]:
    print(f"{label} (one per line, blank line to finish):")
    bullets = []
    while True:
        line = input("  - ").strip()
        if not line:
            break
        bullets.append(line)
    return bullets


def format_bullets(items: list[str], indent: str = "- ") -> str:
    return "\n".join(f"{indent}{item}" for item in items)


# ── body builder ─────────────────────────────────────────────────────────────

def build_body(
    en_bullets: list[str],
    zh_bullets: list[str],
    validation: str,
    notes: str,
) -> str:
    parts = ["## Summary", ""]
    parts += ["### EN:", format_bullets(en_bullets), ""]
    parts += ["### ZH:", format_bullets(zh_bullets), ""]
    parts += ["## Validation", validation, ""]
    if notes:
        parts += ["## Notes", notes, ""]
    return "\n".join(parts).rstrip() + "\n"


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--files", nargs="*", metavar="FILE", help="Files to stage (default: git add -u)")
    p.add_argument("--commit", metavar="MSG", help="Git commit message")
    p.add_argument("--title-en", metavar="TITLE", help="PR title in English")
    p.add_argument("--title-zh", metavar="TITLE", help="PR title in Chinese")
    p.add_argument("--en", nargs="+", metavar="BULLET", help="English summary bullets")
    p.add_argument("--zh", nargs="+", metavar="BULLET", help="Chinese summary bullets")
    p.add_argument("--validation", metavar="TEXT", help="Validation section text")
    p.add_argument("--notes", metavar="TEXT", default="", help="Notes section (optional)")
    p.add_argument("--repo", default=REPO, help=f"GitHub repo (default: {REPO})")
    p.add_argument("--dry-run", action="store_true", help="Print what would happen, don't execute")
    args = p.parse_args()

    branch = current_branch()
    if branch in ("main", "master"):
        print("ERROR: on main/master — create a feature branch first.", file=sys.stderr)
        sys.exit(1)

    print(f"\n── Branch: {branch} ──\n")

    # 1. Stage files
    if args.files:
        stage_cmd = ["git", "add"] + args.files
    else:
        stage_cmd = ["git", "add", "-u"]

    # 2. Commit message
    commit_msg = args.commit or prompt("Commit message")
    if not commit_msg:
        print("ERROR: commit message required.", file=sys.stderr)
        sys.exit(1)

    # 3. PR title
    title_en = args.title_en or prompt("PR title (EN)")
    title_zh = args.title_zh or prompt("PR title (ZH)")
    full_title = f"{title_en} | {title_zh}"

    # 4. Body sections
    en_bullets = args.en or prompt_bullets("Summary EN")
    zh_bullets = args.zh or prompt_bullets("Summary ZH")
    validation = args.validation or prompt(
        "Validation",
        "zig build test --test-timeout 30s --summary all: X pass, Y skip",
    )
    notes = args.notes if args.notes is not None else prompt("Notes (optional, Enter to skip)")

    body = build_body(en_bullets, zh_bullets, validation, notes)

    # ── preview ──────────────────────────────────────────────────────────────
    print("\n" + "─" * 60)
    print(f"TITLE : {full_title}")
    print(f"COMMIT: {commit_msg}")
    print("BODY  :")
    print(textwrap.indent(body, "  "))
    print("─" * 60 + "\n")

    if args.dry_run:
        print("[dry-run] nothing executed.")
        return

    confirm = input("Proceed? [Y/n] ").strip().lower()
    if confirm not in ("", "y", "yes"):
        print("Aborted.")
        sys.exit(0)

    # ── execute ───────────────────────────────────────────────────────────────

    # Stage
    print(f"\n$ {' '.join(stage_cmd)}")
    run(stage_cmd)

    # Commit
    print(f"$ git commit -m ...")
    run(["git", "commit", "-m", commit_msg])

    # Push
    push_cmd = ["git", "push", "-u", "origin", branch]
    print(f"$ {' '.join(push_cmd)}")
    run(push_cmd)

    # PR — write body to temp file to avoid quoting issues
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
        f.write(body)
        body_file = f.name

    pr_cmd = [
        "gh", "pr", "create",
        "--repo", args.repo,
        "--title", full_title,
        "--body-file", body_file,
    ]
    print(f"$ gh pr create ...")
    result = run(pr_cmd)
    print(result.stdout.strip())

    Path(body_file).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
