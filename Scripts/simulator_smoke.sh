#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/smoke
smoke_dir="$PWD/build/smoke"
# Do not publish an earlier screenshot if this run fails before taking one.
rm -f "$smoke_dir/launch.png" "$smoke_dir/launch.log"
exec > >(tee "$smoke_dir/smoke.log") 2>&1

fail() { echo "错误：$*" >&2; exit 1; }
device_id=""
cleanup() {
  result=$?
  trap - EXIT
  if [[ -n "$device_id" ]]; then
    echo "清理临时模拟器：$device_id"
    xcrun simctl shutdown "$device_id" || true
    xcrun simctl delete "$device_id" || true
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(uname -s)" == Darwin ]] || fail "模拟器启动检查需要装有完整 Xcode 的 Mac。"
for tool in xcrun python3; do
  command -v "$tool" >/dev/null || fail "缺少构建工具：$tool"
done
app_path="$PWD/build/DerivedData/Build/Products/Debug-iphonesimulator/Moxu.app"
[[ -d "$app_path" ]] || fail "未找到模拟器 App；请先成功运行 bash Scripts/build.sh。"
bundle_id="$(python3 - "$app_path/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
bundle = info.get("CFBundleIdentifier")
if (not isinstance(bundle, str) or not bundle or "$" in bundle
        or any(c.isspace() for c in bundle)):
    sys.exit("模拟器 App 的实际 Bundle Identifier 无效。")
if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
    sys.exit("此步骤只允许安装真实的 iPhoneSimulator 构建。")
print(bundle)
PY
)"

xcrun simctl list runtimes --json > "$smoke_dir/runtimes.json"
xcrun simctl list devicetypes --json > "$smoke_dir/devicetypes.json"
python3 - "$smoke_dir" <<'PY' > "$smoke_dir/selection.txt"
import json
import pathlib
import re
import sys

folder = pathlib.Path(sys.argv[1])
runtimes = json.loads((folder / "runtimes.json").read_text())["runtimes"]
types = json.loads((folder / "devicetypes.json").read_text())["devicetypes"]

def packed_version(value):
    numbers = [int(v) for v in re.findall(r"\d+", str(value))][:3]
    numbers += [0] * (3 - len(numbers))
    return (numbers[0] << 16) | (numbers[1] << 8) | numbers[2]

pairs = []
for runtime in runtimes:
    if (not runtime.get("isAvailable")
            or not runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")):
        continue
    version = packed_version(runtime["version"])
    for device_type in types:
        if not device_type.get("identifier", "").startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-"):
            continue
        minimum = device_type.get("minRuntimeVersion", 0)
        maximum = device_type.get("maxRuntimeVersion", 0xFFFFFFFF)
        if minimum <= version <= maximum:
            pairs.append((version, minimum, device_type["identifier"], runtime, device_type))
if not pairs:
    sys.exit("没有已安装且可用的兼容 iOS runtime / iPhone 设备类型；请检查 Xcode Simulator 平台安装。")
_, _, _, runtime, device_type = max(pairs, key=lambda item: item[:3])
(folder / "selection.json").write_text(json.dumps(
    {"runtime": runtime, "deviceType": device_type}, ensure_ascii=False, indent=2))
print(runtime["identifier"], device_type["identifier"])
PY
read -r runtime_id device_type_id < "$smoke_dir/selection.txt"
echo "模拟器 runtime：$runtime_id"
echo "iPhone 类型：$device_type_id"
echo "安装 App：$bundle_id"
device_id="$(xcrun simctl create "Moxu-Smoke-$(date +%s)-$$" "$device_type_id" "$runtime_id")"
[[ -n "$device_id" ]] || fail "创建临时模拟器未返回设备 ID。"
xcrun simctl boot "$device_id"
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" "$app_path"
xcrun simctl launch "$device_id" "$bundle_id" 2>&1 | tee "$smoke_dir/launch.log"
# Give the first foreground frame time to render before recording evidence.
sleep 3
xcrun simctl io "$device_id" screenshot --type=png "$smoke_dir/launch.png"
[[ -s "$smoke_dir/launch.png" ]] || fail "未生成启动截图。"
echo "启动请求及截图检查完成：$smoke_dir/launch.png"
echo "执行本地文件导入与 1/2/4 格导出的原生检查，不调用生成服务。"
container_path="$(xcrun simctl get_app_container "$device_id" "$bundle_id" data)"
native_dir="$container_path/Documents/NativeSmoke"
xcrun simctl launch --terminate-running-process "$device_id" "$bundle_id" --moxu-native-smoke \
  2>&1 | tee "$smoke_dir/native-launch.log"
for ((attempt = 0; attempt < 90; attempt++)); do
  if [[ -f "$native_dir/result.json" ]]; then break; fi
  sleep 1
done
if [[ -d "$native_dir" ]]; then
  rm -rf "$smoke_dir/native"
  cp -R "$native_dir" "$smoke_dir/native"
fi
[[ -f "$smoke_dir/native/result.json" ]] || fail "原生导入/导出检查未在90秒内返回结果。"
python3 - "$smoke_dir/native/result.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
for check in report.get("checks", []):
    print(check)
if report.get("success") is not True or len(report.get("checks", [])) < 9:
    sys.exit("原生导入/导出检查失败：" + str(report.get("error", "检查项不完整")))
print("原生导入/导出检查通过；实物在 build/smoke/native。")
PY
echo "已检查本地导入与导出，不代替第三方云盘授权、气泡手势和真机完整验收。"
echo "继续通过真实系统文件选择器检查 TXT / JSON 导入及取消后重开。"
bash Scripts/picker_ui_test.sh "$device_id"
