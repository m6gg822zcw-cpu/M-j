# NAI 中转请求格式 · v1.1.1（build 3）

## 配置

1. 在「画师串」打开方案，将「生图请求格式」设为「NAI」并保存。
2. 在「连接」配置 OpenAI 兼容生图或 NovelAI 连接，填写中转的真实图片接口、模型 ID 与密钥。
3. 将连接默认画师设为上述方案；作品也可单独选择，作品选择优先。
4. 使用连接页显示的 NAI 步数、CFG、采样器、噪声调度、随机种子及参考方式。宽高仍需符合 NAI 的 64 倍数要求。

完整接口如 `https://relay.example.com/v1/images/generations` 会原样保留。只填写 `https://relay.example.com/v1` 时，OpenAI 兼容生图连接发送到 `/v1/images/generations`；NovelAI 连接按自己的默认路径发送到 `/v1/ai/generate-image`。不要把文本聊天接口当作图片接口。

## 请求示例

例如模型 ID 为 `nai-diffusion-4-5-full`，地址看似 OpenAI 的图片接口，请求体仍采用以下结构（这里只列主要字段）：

```json
{
  "input": "bookstore, {{artist:example}}",
  "model": "nai-diffusion-4-5-full",
  "action": "generate",
  "parameters": {
    "width": 1024,
    "height": 1536,
    "steps": 28,
    "scale": 5,
    "sampler": "k_euler_ancestral",
    "negative_prompt": "bad hands"
  }
}
```

真实请求还包含当前适配器所需的 NAI 版本字段、种子、V4 独立人物及参考参数；高级 JSON 在此模式合并到 `parameters` 内。原始画师串不翻译、不去重、不重排。中转模型别名及 NAI 版本参数必须与服务实际支持的模型匹配。

NAI 模式下人物参考沿用 NAI 的单人物／V4.5 精确参考限制，不因为原连接是 OpenAI 就发送 multipart `image[]` 或自动补建多个参考。人物定妆图也发送同一套 NAI 请求格式。返回可为 NAI ZIP、原图、OpenAI base64 或图片 URL；不承诺支持各平台的私有协议。

「跟随连接」继续使用连接原本的协议。若中转只接收 OpenAI `prompt / size` 请求，应使用「跟随连接」；服务器后端是 NAI 并不代表它接受 NAI JSON。

## 兼容与验证

旧画师、旧 Settings 及 `.moxu` 中没有新字段时，默认跟随连接。修改格式不会改写原小说、原图、对白或气泡，也不会自动重新请求收费图片；旧图通过指纹提示待更新。

新增 10 项协议及兼容测试、3 项完整流水线测试。Linux Swift 6.0.3 与 macOS Xcode 16.4 全部 72 项核心测试通过，包含 NAI 生图及定妆图的完整中转地址、参考规则、恢复不重复请求、原串与返回格式。真实收费服务未调用；更新版 iOS 编译与归档结果见下。

## 更新版构建结果

2026-10-24，[GitHub macOS 构建](https://github.com/m6gg822zcw-cpu/M-j/actions/runs/40108171952) 已成功。测试代码提交 `16af250b6c191fce63594b7cb95a97bf8b148610`，后续文档更新不改变编译代码。

- Xcode 16.4 / iOS SDK 18.5：72 项核心测试及 8 项打包校验通过。
- iOS 模拟器 Debug 编译通过，临时 iPhone Air / iOS 26.2 安装、启动并截图；已查看书架首页截图。
- iPhoneOS arm64 Release 归档通过；NAI 选择器、连接参数控件及预览已通过真实 iOS SDK 类型检查。
- IPA 结构、下载 artifact digest 和 IPA 自带 SHA-256 校验均通过，版本 1.1.1，build 3。

[下载 IPA artifact](https://github.com/m6gg822zcw-cpu/M-j/actions/runs/40108171952/artifacts/12566110326)。解压后获得 `Moxu-unsigned.ipa`。文件为 886036 字节，SHA-256：

    9a1f7854d084e560100c483de6deb2e24e5442eabb1b3f461871df6343ba766c

**此 IPA 未签名，需要使用自己的有效签名配置重新签名后才能安装。** 当前仍是工程默认 Bundle ID `com.yourname.moxu`。未上传 App Store 或 TestFlight。GitHub 产物按当前保留策略有效至 2026-11-07，可重新运行工作流生成新包。

本轮模拟请求验证了客户端发包与响应解析，未实际调用你的中转。服务端必须接受 NAI JSON；只接受 OpenAI 请求格式的服务请选「跟随连接」。启动截图不代替气泡完整手工验收、真实中转联调或真机性能检查。
