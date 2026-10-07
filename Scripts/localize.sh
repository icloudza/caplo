#!/bin/bash
# 同步界面文字：让编译器提取 Swift 包里所有可本地化字符串，合并进 App/Localizable.xcstrings，并报告未翻译的条目。
#
#   Scripts/localize.sh          同步并报告
#   Scripts/localize.sh --check  只报告，有未翻译条目时退出码为 1（可放进 CI）
#
# 为什么不靠 Xcode 自动提取：界面代码都在 CaploKit 包里，Xcode 只把应用目标自己的字符串同步进应用的字符串目录，
# 包里的 Text("…") / String(localized:) 运行时却查的是主包（Bundle.main）。所以由这个脚本把包的提取结果并进来，
# 条目一律标成手动维护（extractionState = manual），Xcode 构建时不会把它们当成过期条目删掉。
set -euo pipefail
cd "$(dirname "$0")/.."

catalog=App/Localizable.xcstrings
derived=build/localize
if [[ ${1:-} != --check ]]; then
    xcodebuild -project Caplo.xcodeproj -scheme Caplo -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES build > "$derived.log" 2>&1 \
        || { tail -20 "$derived.log" >&2; exit 1; }
fi

python3 - "$catalog" "$derived" "${1:-}" <<'PY'
import glob, json, os, subprocess, sys, tempfile

catalog_path, derived, mode = sys.argv[1], sys.argv[2], sys.argv[3]
# 只给用户看得到的界面翻译：组件画廊、窗口回归、材质评审、暂停中的截图功能都是开发用的，不进目录。
EXCLUDED = ("/Gallery.swift", "/Features/Legacy/", "/WindowSmokeTest.swift", "/MaterialReview.swift", "/PreviewGallery/")

catalog = json.load(open(catalog_path, encoding="utf-8")) if os.path.exists(catalog_path) else \
    {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}

if mode != "--check":
    files = [f for f in glob.glob(derived + "/**/*.stringsdata", recursive=True)
             if not any(x in json.load(open(f)).get("source", "") for x in EXCLUDED)]
    with tempfile.TemporaryDirectory() as tmp:
        scratch = os.path.join(tmp, "Localizable.xcstrings")
        json.dump({"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}, open(scratch, "w"))
        args = ["xcrun", "xcstringstool", "sync", scratch]
        for f in files: args += ["--stringsdata", f]
        subprocess.run(args, check=True)
        extracted = json.load(open(scratch))["strings"]
    added = 0
    for key in extracted:
        if key not in catalog["strings"]:
            catalog["strings"][key] = {}
            added += 1
    for key, entry in catalog["strings"].items():
        entry["extractionState"] = "manual" if key in extracted else "stale"
    stale = [k for k, e in catalog["strings"].items() if e["extractionState"] == "stale"]
    for key in stale: del catalog["strings"][key]
    json.dump(catalog, open(catalog_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2, sort_keys=True)
    open(catalog_path, "a").write("\n")
    print(f"同步完成：共 {len(catalog['strings'])} 条，新增 {added} 条，移除不再使用的 {len(stale)} 条")

def needs_translation(key, entry):
    # 不含中文的键（"%@ · %@"、"Caplo"、"REC"）原样即可，不要求翻译。
    if not any("一" <= ch <= "鿿" for ch in key): return False
    en = entry.get("localizations", {}).get("en", {})
    # 带数量的条目用复数变体（one / other），每个变体都要有译文。
    units = [v["stringUnit"] for v in en.get("variations", {}).get("plural", {}).values()] or [en.get("stringUnit")]
    return any(not u or u.get("state") != "translated" or not u.get("value") for u in units)

missing = [k for k, e in catalog["strings"].items() if needs_translation(k, e)]
if missing:
    print(f"未翻译成英文：{len(missing)} 条")
    for key in missing[:40]: print("  " + key)
    if len(missing) > 40: print(f"  …另有 {len(missing) - 40} 条")
    if mode == "--check": sys.exit(1)
else:
    print("全部条目都有英文翻译")
PY
