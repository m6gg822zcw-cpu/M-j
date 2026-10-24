#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/build/Moxu-unsigned.ipa"
# Remove the published path even if preflight fails, so it cannot look like a new build.
rm -f "$output" "$output.sha256"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo "需要装有完整 Xcode 和 iOS SDK 的 Mac；尚未生成 IPA。" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "需要 Python 3。" >&2; exit 1; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null
mkdir -p build/UnsignedArchive
# Fresh staging prevents a previous archive from leaking into this IPA.
run_dir="$(mktemp -d "$PWD/build/UnsignedArchive/run.XXXXXX")"
xcodebuild -project Moxu.xcodeproj -scheme Moxu \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$run_dir/Moxu.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive 2>&1 | tee "$run_dir/archive.log"
mkdir -p "$run_dir/IPA/Payload"
ditto "$run_dir/Moxu.xcarchive/Products/Applications/Moxu.app" "$run_dir/IPA/Payload/Moxu.app"
ditto -c -k --keepParent "$run_dir/IPA/Payload" "$run_dir/Moxu-unsigned.ipa"
python3 Scripts/validate_ipa.py "$run_dir/Moxu-unsigned.ipa" --expect unsigned
mv "$run_dir/Moxu-unsigned.ipa" "$output"
(cd build && shasum -a 256 Moxu-unsigned.ipa > Moxu-unsigned.ipa.sha256)
echo "已生成 $output"
echo "此文件未签名，需要使用自己的证书签名后才能安装。日志：$run_dir/archive.log"
