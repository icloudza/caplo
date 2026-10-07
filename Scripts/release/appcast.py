#!/usr/bin/env python3
"""生成 Sparkle 的 appcast.xml 与官网用的 latest.json。

appcast 只放最新一个正式版：Sparkle 只需要最新条目就能判断与下载；旧安装包仍保存在下载服务器的 releases/ 目录。
写出的 appcast 还要再用 sign_update 签名（应用开启了 SURequireSignedFeed，未签名的 appcast 会被拒绝）。
"""
import argparse
import email.utils
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="展示版本，例如 1.4.2")
    parser.add_argument("--build", required=True, help="CFBundleVersion")
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--url", required=True, help="安装包的公开下载地址")
    parser.add_argument("--notes", required=True, type=Path, help="更新说明文件")
    parser.add_argument("--signature", required=True, help="sign_update 对安装包输出的 sparkle:edSignature 值")
    parser.add_argument("--minimum-system", default="15.0")
    parser.add_argument("--site", default="", help="官网地址，写进 appcast 的 <link>")
    parser.add_argument("--out", required=True, type=Path, help="输出目录")
    args = parser.parse_args()

    length = args.dmg.stat().st_size
    sha256 = subprocess.run(["shasum", "-a", "256", str(args.dmg)], check=True, capture_output=True, text=True).stdout.split()[0]
    notes = args.notes.read_text(encoding="utf-8").strip()
    now = datetime.now(timezone.utc)
    # CDATA 里不能出现 "]]>"；说明来自仓库文件，出现时拆开，避免生成坏的 XML。
    notes_cdata = notes.replace("]]>", "]]]]><![CDATA[>")
    link = f"\n    <link>{escape(args.site)}</link>" if args.site else ""

    appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Caplo</title>{link}
    <language>zh-CN</language>
    <item>
      <title>Caplo {escape(args.version)}</title>
      <pubDate>{email.utils.format_datetime(now)}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(args.minimum_system)}</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text"><![CDATA[{notes_cdata}]]></description>
      <enclosure url={quoteattr(args.url)} length="{length}" type="application/x-apple-diskimage" sparkle:edSignature={quoteattr(args.signature)}/>
    </item>
  </channel>
</rss>
"""
    latest = {
        "version": args.version,
        "build": args.build,
        "published": now.isoformat(timespec="seconds"),
        "url": args.url,
        "size": length,
        "sha256": sha256,
        "minimumSystemVersion": args.minimum_system,
        "notes": notes,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "appcast.xml").write_text(appcast, encoding="utf-8")
    (args.out / "latest.json").write_text(json.dumps(latest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


def parse_signature(output: str) -> str:
    """从 sign_update 的输出（sparkle:edSignature="…" length="…"）里取签名。"""
    match = re.search(r'sparkle:edSignature="([^"]+)"', output)
    if not match:
        raise SystemExit(f"sign_update 输出里没有签名：{output!r}")
    return match.group(1)


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--parse-signature":
        print(parse_signature(sys.stdin.read()))
        sys.exit(0)
    sys.exit(main())
