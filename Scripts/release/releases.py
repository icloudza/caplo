#!/usr/bin/env python3
"""生成官网"更新日志"页用的 releases.json：截至当前标签的全部正式版，新的在前。

每次发版全量重新生成，说明一律取自仓库（notes.sh，与应用内更新窗口、GitHub Release 同一份），
改了旧版本的说明，下次发版时官网自动同步。

更新说明的双语写法：列表项写中文，下一行缩进写英文；`##` 标题同理。解析成
{"zh": 中文, "en": 英文或 null}，官网中文页只显示中文、英文页只显示英文（没有英文时退回中文）。

用法：releases.py --tag v1.4.2 --out <目录>
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
BULLET = re.compile(r"^(?:[-*•·]|\d+\.)\s+")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def parse(notes: str) -> list[dict]:
    """把说明拆成若干段：每段一个可选标题和若干条目；缩进的续行是上一个标题或条目的英文。"""
    sections: list[dict] = [{"title": None, "items": []}]
    last: dict | None = None
    for raw in notes.splitlines():
        line = raw.strip()
        if not line:
            continue
        if raw[0].isspace() and last is not None and not BULLET.match(line):
            last["en"] = f"{last['en']} {line}" if last["en"] else line
            continue
        if line.startswith("#"):
            title = line.lstrip("#").strip()
            if not title:
                continue
            last = {"zh": title, "en": None}
            section = {"title": last, "items": []}
            # 开头还没有条目的空段直接换成带标题的段。
            if sections[-1]["items"] or sections[-1]["title"]:
                sections.append(section)
            else:
                sections[-1] = section
            continue
        last = {"zh": BULLET.sub("", line, count=1), "en": None}
        sections[-1]["items"].append(last)
    return [section for section in sections if section["items"] or section["title"]]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="本次发布的正式版标签")
    parser.add_argument("--out", required=True, type=Path, help="输出目录")
    args = parser.parse_args()

    current = STABLE.match(args.tag)
    if not current:
        raise SystemExit(f"{args.tag} 不是正式版标签")
    limit = tuple(map(int, current.groups()))
    tags = {args.tag} | {tag for tag in git("tag", "-l", "v*").splitlines() if STABLE.match(tag)}
    # 只收到当前标签为止：重新发布旧标签时，官网和 latest.json 一样回到那个版本。
    versions = sorted((tuple(map(int, STABLE.match(tag).groups())), tag) for tag in tags)
    releases = []
    for number, tag in reversed(versions):
        if number > limit:
            continue
        notes = subprocess.run([str(ROOT / "Scripts/release/notes.sh"), tag], cwd=ROOT, check=True,
                               capture_output=True, text=True).stdout
        # 附注标签取打标签的日期，轻量标签取提交日期，均按作者本地时区的日历日。
        date = git("for-each-ref", "--format=%(creatordate:short)", f"refs/tags/{tag}")
        releases.append({"version": tag[1:], "date": date, "sections": parse(notes)})

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "releases.json").write_text(json.dumps({"releases": releases}, ensure_ascii=False, indent=2) + "\n",
                                            encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
