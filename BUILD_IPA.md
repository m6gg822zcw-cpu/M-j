# 给 Codex 的 IPA 构建交接

这是墨序 iOS 原生源码 v1.1.3（build 5），用户要求完成 iOS 编译并生成 IPA。优先使用已有 Mac / macOS CI 与签名环境继续构建、修复和验收。项目入口为 `Moxu.xcodeproj`，scheme 为 `Moxu`，最低 iOS 17，建议 Xcode 16 或更新。

**当前状态（v1.1.3 build 5）：**95 项 Linux 核心测试通过；真实 iOS 编译、系统文件选择器 UI 测试及更新 IPA 正在验证。上一版仅覆盖内部文件导入方法，本版增加实际系统选择与存档核对。结果见 [小说导入修复记录](Docs/v1.1.3_小说导入修复.md)。

## 最短打包路径

有 Mac 和完整 Xcode 16 或更新版本时，在本目录运行：

    bash Scripts/build.sh
    bash Scripts/archive_unsigned.sh

成功后生成 `build/Moxu-unsigned.ipa` 及 SHA-256 校验文件。它是真机目标的未签名包，仍需签名后安装。每次归档使用独立目录，编译失败会停止；不会打包上次残留的 App。

没有 Mac 时，把本目录完整提交到自己的 GitHub 仓库（保留 `.github/workflows/ios.yml`），进入 **Actions → Build iOS and core tests → Run workflow**。也可 push 自动触发。只有成功后才下载 `Moxu-unsigned-requires-signing` artifact；解压后才是 IPA。`Moxu-build-logs` 包含测试、模拟器构建及归档日志，失败时也可下载。此工作流使用 macOS runner，可能消耗账户的 Actions 配额；本轮已在用户授权仓库成功运行远程工作流。

如需签名 IPA，先在 Mac 的 Xcode 配置好自己已获授权的 Team、证书、私钥及描述文件，再运行（替换占位值）：

    export MOXU_TEAM_ID='你的10位TEAM_ID'
    export MOXU_BUNDLE_ID='你的唯一BundleID'
    bash Scripts/build.sh
    bash Scripts/archive_signed.sh

脚本默认使用 `release-testing`，适合已包含在描述文件中的设备；可用 `MOXU_EXPORT_METHOD=debugging` 导出开发包。`app-store-connect` 仅导出分发包，不能直接装到普通设备，本脚本不上传。

已有专用 ExportOptions 时设置 `MOXU_EXPORT_OPTIONS_PLIST=/完整路径/ExportOptions.plist`，该文件的 `method` 优先，`teamID` 必须匹配，`destination=upload` 会被拒绝。归档默认沿用工程 Automatic 签名；手动签名另设 `MOXU_PROVISIONING_PROFILE` 为已安装描述文件的名称或 UUID，必要时用 `MOXU_SIGNING_IDENTITY` 指定已有签名身份。未提供自定义 plist 时，脚本会用同一描述文件生成 manual 导出映射；若同时提供自定义 plist，必须填写 `signingStyle=manual` 和对应 Bundle ID 的 `provisioningProfiles`。描述文件类型须与导出方法匹配，例如开发描述文件搭配 `debugging`。

签名输出位于 `build/SignedArchive/run-*/IPA/`，同目录包含 SHA-256 文件。日志在对应的 `run-*` 目录。脚本验证归档及导出 App 的 `codesign` 签名，并检查 IPA 主程序为 iOS 真机 arm64；不自动申请证书、更新描述文件或上传 App。若提示缺少描述文件，请先在 Xcode 为该 Bundle ID 完成本机签名配置。

`Scripts/validate_ipa.py` 只检查结构、架构与平台及签名文件是否存在，不能单独证明签名可信、设备在安装范围内或应用能正常运行。签名流程另外调用 macOS `codesign`；仍需真机安装验收。

## 先构建

    xcodebuild -version
    bash Scripts/build.sh

脚本先测试本地 MoxuCore 包，再构建通用 iOS 模拟器应用，无需先填写服务密钥。没有远程 Swift 依赖，系统 zlib 直接使用 SDK 头文件与库。Pillow 只用于重新生成开发用图标 / 离线示例，不是 App 或构建依赖；资源已经提供。

新增文件都已加入工程。只有增加 / 删除原生源文件时才需要运行 `python3 Scripts/generate_project.py`；该生成器会重建项目配置，重建后需重新核对 Bundle Identifier 与 Team。常规构建直接打开现有工程。

## 必须验收的气泡链路

App 启动后点击书架的「离线试用气泡编辑」，打开「气泡排版 · 离线示例」，切换到「漫画」并点「调整气泡」。该路径不调用任何文本 / 生图 API，也不要求用户凭据。

1. 拖动白色气泡改变位置；拖青色角点改变尺寸；拖橙色尾尖指向 A / B 定位标记。
2. 调整文字、说话者、字号、心声 / 旁白样式、显示姓名、隐藏与层级；测试撤销 / 重做、恢复原对白布局。
3. 键盘展开和收起、iPhone 横竖屏、iPad、较长对白时，画布要能操作；拖动应持续跟手，不发送 API。
4. 保存、返回、重新打开，再彻底重启 App，位置和文字应一致。取消编辑不能悄悄保存草稿。
5. 打开全屏漫画预览，对照 PDF、PNG、HTML 导出；所有气泡应按**实际图片区域**同比例对齐，包括有留白的分页图片，不能按整页或屏幕坐标偏移。
6. 文字放不下应明确提示修改；导出不能静默裁掉对白。隐藏 / 删除全部气泡后要保持纯图，不能自动恢复旧对白。
7. 工程备份再导入应恢复气泡。旧 v1.0 备份没有 lettering 字段也必须能读取。重绘保留手工图层，但新人物位置可能变化，需再次核对尾尖。

同一绘制器在 `App/BubbleCanvas.swift` 的 `BubblePainter`，被阅读、编辑、全屏预览与导出共同调用；不要另外实现一套导出坐标。保存入口为 `Repository.saveLettering`，包含图片版本与排版修订校验。Pipeline 提交会合并保留磁盘上的手工排版。

## 生成 IPA

先检查现有签名配置。使用真实、已有授权的 Team / Bundle Identifier 与签名证书，不要把证书、私钥或 API 密钥放进源码包或 Git。

具备签名环境后，按实际配置归档。例如下面的两个变量由现有环境确定：

    xcodebuild -project Moxu.xcodeproj -scheme Moxu \
      -configuration Release -destination 'generic/platform=iOS' \
      -archivePath build/Moxu.xcarchive \
      DEVELOPMENT_TEAM="$MOXU_TEAM_ID" \
      PRODUCT_BUNDLE_IDENTIFIER="$MOXU_BUNDLE_ID" archive

根据本机 `xcodebuild -help` 支持的导出方法和现有描述文件，生成 `build/ExportOptions.plist`，然后执行：

    xcodebuild -exportArchive \
      -archivePath build/Moxu.xcarchive \
      -exportOptionsPlist build/ExportOptions.plist \
      -exportPath build/IPA

若缺少签名材料，仍应先完成全部编译修复、模拟器验证，并运行：

    bash Scripts/archive_unsigned.sh

它输出 `build/Moxu-unsigned.ipa`，须清楚标注“未签名，需要签名后安装”。签名 IPA 与未签名 IPA 不可混称；不要用空文件、源码 ZIP 或模拟器 .app 冒充可安装的 IPA。

最终交付应包括实际生成的 IPA、更新后的完整源码、构建 / 测试结果与已知限制。不自动提交 App Store 或 TestFlight。
