#!/bin/bash
set -euo pipefail

fail() { echo "错误：$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "签名 IPA 需要装有完整 Xcode 的 Mac。"
for tool in xcodebuild xcrun python3 codesign ditto tee shasum; do
  command -v "$tool" >/dev/null || fail "缺少构建工具：$tool"
done

team_id="${MOXU_TEAM_ID:-}"
bundle_id="${MOXU_BUNDLE_ID:-}"
export_method="${MOXU_EXPORT_METHOD:-release-testing}"
source_options="${MOXU_EXPORT_OPTIONS_PLIST:-}"
[[ -n "$team_id" ]] || fail "请设置 MOXU_TEAM_ID，使用本机已有授权的 Apple Developer Team。"
[[ -n "$bundle_id" ]] || fail "请设置 MOXU_BUNDLE_ID，使用本机签名配置对应的 Bundle Identifier。"
if [[ -n "$source_options" && "$source_options" != /* ]]; then
  source_options="$PWD/$source_options"
fi

python3 - "$team_id" "$bundle_id" "$export_method" "$source_options" "${MOXU_PROVISIONING_PROFILE:-}" <<'PY'
import pathlib
import plistlib
import re
import sys

team, bundle, method, source, profile = sys.argv[1:]
if not re.fullmatch(r"[A-Z0-9]{10}", team):
    sys.exit("MOXU_TEAM_ID 必须是 10 位大写字母或数字的真实 Team ID。")
if (bundle.lower() == "com.yourname.moxu" or len(bundle) > 255
        or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle)):
    sys.exit("MOXU_BUNDLE_ID 必须是自己的有效 Bundle Identifier，不能使用 com.yourname.moxu。")
if source:
    try:
        with pathlib.Path(source).open("rb") as handle:
            options = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        sys.exit(f"无法读取 MOXU_EXPORT_OPTIONS_PLIST：{exc}")
    if not isinstance(options, dict):
        sys.exit("ExportOptions.plist 顶层必须是字典。")
    if options.get("destination", "export") != "export":
        sys.exit("本脚本只允许 destination=export；不允许 upload 或自动发布。")
    if options.get("teamID", team) != team:
        sys.exit("ExportOptions.plist 的 teamID 与 MOXU_TEAM_ID 不一致。")
    if not isinstance(options.get("method"), str) or not options["method"]:
        sys.exit("现有 ExportOptions.plist 必须明确填写 method。")
    if profile and (options.get("signingStyle") != "manual"
                    or not isinstance(options.get("provisioningProfiles"), dict)
                    or not options["provisioningProfiles"].get(bundle)):
        sys.exit("手动归档要求 ExportOptions 使用 signingStyle=manual 并为该 Bundle ID 指定 provisioningProfiles。")
elif method not in {"release-testing", "debugging", "app-store-connect"}:
    sys.exit("MOXU_EXPORT_METHOD 仅支持 release-testing、debugging 或 app-store-connect。")
PY

cd "$(dirname "$0")/.."
[[ -f Scripts/validate_ipa.py ]] || fail "缺少 Scripts/validate_ipa.py。"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path >/dev/null

mkdir -p build/SignedArchive
run_dir="$(mktemp -d "$PWD/build/SignedArchive/run-XXXXXX")"
archive_path="$run_dir/Moxu.xcarchive"
export_path="$run_dir/IPA"
options_path="$run_dir/ExportOptions.plist"

python3 - "$team_id" "$export_method" "$source_options" "$options_path" "$bundle_id" "${MOXU_PROVISIONING_PROFILE:-}" <<'PY'
import plistlib
import sys

team, method, source, destination, bundle, profile = sys.argv[1:]
if source:
    with open(source, "rb") as handle:
        options = plistlib.load(handle)
else:
    options = {"method": method, "signingStyle": "automatic"}
    if profile:
        options.update(signingStyle="manual", provisioningProfiles={bundle: profile})
# Keep the supplied file untouched. This invocation only exports to disk.
options["destination"] = "export"
options["teamID"] = team
options["uploadSymbols"] = False
with open(destination, "wb") as handle:
    plistlib.dump(options, handle)
PY

echo "使用本机已有证书与描述文件归档；日志：$run_dir"
echo "不会自动申请证书、更新描述文件或上传 App。"
signing_args=(DEVELOPMENT_TEAM="$team_id" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" CODE_SIGNING_ALLOWED=YES)
if [[ -n "${MOXU_PROVISIONING_PROFILE:-}" ]]; then
  signing_args+=(CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="$MOXU_PROVISIONING_PROFILE")
fi
if [[ -n "${MOXU_SIGNING_IDENTITY:-}" ]]; then
  signing_args+=(CODE_SIGN_IDENTITY="$MOXU_SIGNING_IDENTITY")
fi
xcodebuild -project Moxu.xcodeproj -scheme Moxu \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  "${signing_args[@]}" archive 2>&1 | tee "$run_dir/archive.log"

archive_app="$archive_path/Products/Applications/Moxu.app"
[[ -d "$archive_app" ]] || fail "归档未生成 Moxu.app，请查看 archive.log。"
codesign --verify --deep --strict --verbose=2 "$archive_app" 2>&1 | tee "$run_dir/archive-signature.log"

xcodebuild -exportArchive -archivePath "$archive_path" \
  -exportOptionsPlist "$options_path" -exportPath "$export_path" \
  2>&1 | tee "$run_dir/export.log"

shopt -s nullglob
ipas=("$export_path"/*.ipa)
[[ ${#ipas[@]} -eq 1 && -f "${ipas[0]}" ]] || fail "导出目录必须恰好包含一个 IPA，请查看 export.log。"
ipa_path="${ipas[0]}"
verification_path="$run_dir/Verification"
mkdir -p "$verification_path"
ditto -x -k "$ipa_path" "$verification_path"
apps=("$verification_path"/Payload/*.app)
[[ ${#apps[@]} -eq 1 && -d "${apps[0]}" ]] || fail "导出的 IPA 必须恰好包含一个主应用。"
codesign --verify --deep --strict --verbose=2 "${apps[0]}" 2>&1 | tee "$run_dir/export-signature.log"
python3 Scripts/validate_ipa.py "$ipa_path" --expect signed 2>&1 | tee "$run_dir/validation.log"
(cd "$export_path" && shasum -a 256 "$(basename "$ipa_path")" > "$(basename "$ipa_path").sha256")

echo "已生成并验证签名 IPA：$ipa_path"
echo "安装范围由描述文件及导出方式决定；app-store-connect 导出包用于后续分发提交。"
