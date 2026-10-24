#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo "需要安装 Xcode 的 Mac；本脚本不能在 Linux 或 iPhone 上编译 iOS 应用。" >&2
  exit 1
fi
mkdir -p build/logs
xcodebuild -version 2>&1 | tee build/logs/xcode-version.log
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
python3 -m unittest discover -s Scripts/tests -v 2>&1 | tee build/logs/packaging-tests.log
swift test --package-path Packages/MoxuCore 2>&1 | tee build/logs/core-tests.log
xcodebuild -project Moxu.xcodeproj -scheme Moxu \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/logs/simulator-build.log
echo "模拟器应用：build/DerivedData/Build/Products/Debug-iphonesimulator/Moxu.app"
