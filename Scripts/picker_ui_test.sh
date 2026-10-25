#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device_id="${1:-}"
[[ -n "$device_id" ]] || { echo "用法：bash Scripts/picker_ui_test.sh <已启动的模拟器UDID>" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo "真实系统文件选择器 UI 测试需要 Xcode 和 iOS Simulator。" >&2; exit 1; }
mkdir -p build/smoke
smoke_dir="$PWD/build/smoke"
export_attachments() {
  result=$?
  trap - EXIT
  if [[ -d "$smoke_dir/PickerUI.xcresult" ]]; then
    xcrun xcresulttool export attachments --path "$smoke_dir/PickerUI.xcresult" \
      --output-path "$smoke_dir/picker-attachments" || true
  fi
  exit "$result"
}
trap export_attachments EXIT
rm -rf "$smoke_dir/PickerUI.xcresult"
rm -f "$smoke_dir/picker-storage.json" "$smoke_dir/picker-baseline.json"
app_path="$PWD/build/DerivedData/Build/Products/Debug-iphonesimulator/Moxu.app"
bundle_id="$(python3 - "$app_path/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle)["CFBundleIdentifier"])
PY
)"
xcrun simctl bootstatus "$device_id" -b
xcrun simctl launch --terminate-running-process "$device_id" "$bundle_id" --moxu-picker-ui-test \
  2>&1 | tee "$smoke_dir/picker-fixture-launch.log"
container_path="$(xcrun simctl get_app_container "$device_id" "$bundle_id" data)"
for ((attempt = 0; attempt < 30; attempt++)); do
  if [[ -f "$container_path/Documents/PickerUI/PickerNovel.txt" && -f "$container_path/Documents/PickerUI/PickerChapters.json" ]]; then break; fi
  sleep 1
done
python3 - "$container_path" "$smoke_dir/picker-baseline.json" <<'PY'
import hashlib, json, pathlib, sys
container, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
originals = {}
for name in ("PickerNovel.txt", "PickerChapters.json"):
    data = (container / "Documents/PickerUI" / name).read_bytes()
    originals[name] = hashlib.sha256(data).hexdigest()
projects = container / "Library/Application Support/Moxu/Projects"
if not projects.is_dir():
    sys.exit("找不到实际 App 工程存档目录。")
output.write_text(json.dumps({"originals": originals, "projectIDs": [p.parent.name for p in projects.glob("*/Project.json")]}, indent=2))
PY
xcodebuild -project Moxu.xcodeproj -scheme Moxu -configuration Debug \
  -destination "platform=iOS Simulator,id=$device_id" -destination-timeout 30 \
  -derivedDataPath build/PickerDerivedData -resultBundlePath "$smoke_dir/PickerUI.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 240 -maximum-test-execution-time-allowance 300 \
  -only-testing:MoxuUITests/ImportFlowTests \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test 2>&1 | tee "$smoke_dir/picker-ui-test.log"

container_path="$(xcrun simctl get_app_container "$device_id" "$bundle_id" data)"
python3 - "$container_path" "$smoke_dir/picker-baseline.json" "$smoke_dir/picker-storage.json" <<'PY'
import hashlib, json, pathlib, sys
container, baseline_path, output = map(pathlib.Path, sys.argv[1:])
report = {"success": False, "imports": []}
try:
    baseline = json.loads(baseline_path.read_text())
    originals = container / "Documents/PickerUI"
    hashes = {name: hashlib.sha256((originals / name).read_bytes()).hexdigest() for name in baseline["originals"]}
    if hashes != baseline["originals"]:
        raise ValueError("系统选择和导入过程修改了原始书稿字节。")
    txt = "序章\n林舟推开书店的门。原文与 emoji 🙂 应完整导入。"
    if (originals / "PickerNovel.txt").read_text() != txt:
        raise ValueError("TXT 原始夹具内容不符。")
    expected_json = {"chapters": [{"title": "第一章 桥灯", "text": "苏禾提着铜灯走过桥头。"}]}
    if json.loads((originals / "PickerChapters.json").read_text()) != expected_json:
        raise ValueError("JSON 原始夹具内容不符。")
    projects = container / "Library/Application Support/Moxu/Projects"
    if not projects.is_dir():
        raise ValueError("找不到实际 App 工程存档目录。")
    expected = {"PickerNovel": (2, "序章", txt.split("\n", 1)[1]),
                "PickerChapters": (1, "第一章 桥灯", "苏禾提着铜灯走过桥头。")}
    counts = {name: 0 for name in expected}
    for project_path in projects.glob("*/Project.json"):
        if project_path.parent.name in baseline["projectIDs"]:
            continue
        project = json.loads(project_path.read_text())
        title = project.get("title")
        if title not in expected:
            continue
        _, chapter_title, body = expected[title]
        chapters = project.get("chapters", [])
        if len(chapters) != 1 or chapters[0].get("title") != chapter_title:
            raise ValueError(f"{title} 章节数量或标题不符：{chapters}")
        source = json.loads((project_path.parent / "Chapters/1-source.json").read_text())
        actual = "\n".join(unit["text"] for unit in source)
        if actual != body:
            raise ValueError(f"{title} 真实存档正文不符：{actual!r}")
        counts[title] += 1
        report["imports"].append({"projectID": project_path.parent.name, "title": title,
                                  "chapterCount": len(chapters), "chapterTitle": chapter_title, "body": actual})
    if any(counts[name] != expected[name][0] for name in expected):
        raise ValueError(f"真实系统选择器应新增两次TXT、一次JSON存档，实际：{counts}")
    report.update(success=True, originalsSHA256=hashes)
except Exception as error:
    report["error"] = str(error)
output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
if not report["success"]:
    sys.exit("系统选择器存档校验失败：" + report["error"])
print("真实系统选择器TXT、JSON、取消后重选均通过；实际书架存档和原书稿字节校验通过。")
PY
