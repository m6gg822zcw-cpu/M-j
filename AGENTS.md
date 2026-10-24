# 墨序 iOS：后续构建与修复

本项目的用户目标是原生 iOS 小说漫画应用，并交给 Codex 构建 IPA。先阅读 BUILD_IPA.md、README.md 和 Docs/验证记录.md。

- 保留 SwiftUI 原生架构、自定义 API 与原始画师串。不要为通过构建删除气泡编辑或改成网页包装。
- 用真实 Xcode / iOS SDK 编译并修复问题；Linux 核心测试和 frontend parse 不是 iOS 构建结果。
- 测试入口为 Scripts/build.sh；有 SDK 后还需用内置「离线试用气泡编辑」检查手势、保存、重启和导出。
- 气泡坐标相对于原图归一化。编辑与 PDF / PNG / HTML 必须复用 BubblePainter，不能建立不同坐标系。
- 手工文字与气泡不能覆盖原小说、原分镜对白或原始图片；调整气泡不应发送生成请求。
- 保留 v1.0 解码兼容、修订冲突检测、图片版本检测与 Pipeline 提交时保留排版的逻辑。
- 仅使用用户现有授权的签名环境；没有签名时交付明确标注的 unsigned IPA 和编译结果。不要声称它可直接安装。
- 不把 API 密钥、证书私钥或描述文件放进源码。没有单独授权不发布 App Store / TestFlight。
