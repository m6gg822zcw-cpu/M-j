# API 配置与适配

本工程直接请求你配置的服务，不依赖 Tavo、SillyTavern、父页面变量或 JavaScript 桥。地址、模型与非敏感参数保存在本机；密钥保存在 Keychain。小说片段会发送给所选文本服务，人物参考会发送给所选生图服务；开启视觉检查时还会发送给所选视觉文本服务。

## 文本连接

- OpenAI 兼容：填服务提供的 `/v1` 根地址或完整 `chat/completions` 地址。普通兼容服务一般使用 `max_tokens`；要求新字段的模型可在编辑页改成 `max_completion_tokens`。
- Responses：原生 `/responses`，解析 `output[].content[].text`，不复用服务器对话。默认 `store: false`。
- Anthropic：根地址 `https://api.anthropic.com/v1`，使用 `x-api-key` 与版本请求头。
- Gemini：根地址 `https://generativelanguage.googleapis.com/v1beta`，使用 `x-goog-api-key`。

温度可完全关闭，避免向不支持该参数的推理模型发送 `temperature`。输出上限应足够容纳完整 JSON 分镜；复杂模型的推理 token 也可能计入上限。若 JSON 或覆盖检查失败，会额外尝试一次结构修复，仍失败则停在上一个保存点。

可选自定义章节识别正则在「连接 → 生成与检查」设置，留空采用默认中英文章标题规则；只影响之后导入的作品。例如 `^【\d+】[^\n]+$` 可以识别 `【01】雨夜`。有目录页的小说可能产生卷首文本，目录序号不强行等同原书章号。

## NAI

根地址 `https://image.novelai.net`，粘贴平台接受的 Bearer token，模型字段自行填真实可用 ID。内置候选包括 `nai-diffusion-4-5-full`；候选列表不是订阅权限或连通性检查。

宽高是 64 的倍数，本适配器范围 64—2048、步数 1—50。实际可用尺寸、步数和费用仍由平台 / 模型决定。默认不启用隐式质量标签，用户正面与负面串原样进入请求。

NAI 英文信息分为：

1. 基础场景：本格人数、背景、镜头、动作关系，附加背景串和正面画师串。
2. 独立人物：固定身份标签、当前有效衣装层、动作表情、人物附加串；左右站位映射到角色中心。
3. 负面：独立负面串。

中文身份和英文 NAI 固定标签分别可编辑。脱下的外套会从衣装层标签中移除，而不是只增加一个相反标签。

「精确参考」是**未经真实 API 联调的实验适配**，默认关闭，仅允许 V4.5 单个人物与一张符合尺寸的参考。API 私有参数可能调整，出错时先关闭该选项。多人镜头不合并精确参考：继续使用独立角色标签并提示人工核对。单人图生图可用，但可能把定妆构图带入成图，并非同一性保证。

## OpenAI 兼容生图

无参考图发 JSON `images/generations`，期望 `data[0].b64_json`、`data[0].url` 或直接图片；有参考图发 `images/edits` multipart，字段为 `image[]`。如果平台不支持编辑接口，在连接中关闭「发送人物参考图」，仍会携带锁定身份文字。

参考不足时会先补建缺少的定妆图，再生成漫画格，所以一个漫画格可能伴随多个收费请求。也可先自己上传参考。参考多于连接设置的上限时，本地合成带编号的对照板；这依然依赖模型正确区分人物。

尺寸填写平台实际支持的值。高级参数可加入平台支持的 `quality` 等字段。负面串在自然语言提示中作为避免内容保留，不假装平台支持 NAI 标签权重。

## Gemini 生图

使用原生 `generateContent`，发送文字和 `inlineData`，解析候选 `parts` 中的图片。选择支持图片生成与所需参考数量的真实模型 ID。应用不把 NAI 标签协议冒充 Gemini 原生参数。

当前画幅等模型专属设置可放进高级 JSON。高级参数与顶层请求做合并，**同名对象会整体替换，不进行深层合并**；例如替换 `generationConfig` 时，应保留平台所需的 `responseModalities`，再加入该模型支持的图像配置。

## 请求可检查、错误可恢复

每格「查看提示词」可在出图前看当前组合，出图后看实际脱敏参数与原文。NAI 的独立角色串在请求 JSON 中逐一保留。请求头中的密钥不写入项目记录；参考图片的 base64 会在审计副本中隐藏。

网络层不自动重试收费 POST。图片请求前先落请求凭据，成功响应先保存原始图片，再解码规范化，最后把成图与分镜一起提交。遇到系统终止或解码失败时，下次先恢复本地文件。服务记录不明且没有本地成图时，必须由用户在界面上核实后明确重新请求。

400 / 401 / 403 / 404 / 422 会按明确失败处理；超时、服务端异常、无有效图片等情况保留待核实记录。图像 URL 后续下载不携带 API Authorization；收费请求不跟随重定向，GET 只允许同主机 HTTPS 重定向。

高级 JSON 禁止覆盖模型、提示词、主要身份参考字段和密钥等专用内容。服务需要不同鉴权或异步协议时，应扩展 `APIKind`、`RequestBuilder` 和 `ProviderClient`，不要把密钥写进 URL 或原始画师串。

## 官方参考

接口结构参考下列一手资料；文档存在不等于本项目已获得服务联调验证：

- [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- [OpenAI Responses](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [OpenAI 图像编辑](https://developers.openai.com/api/reference/resources/images/methods/edit)
- [Anthropic Messages](https://docs.anthropic.com/en/api/messages)
- [Gemini generateContent](https://ai.google.dev/api/generate-content)
- [Gemini 图像生成](https://ai.google.dev/gemini-api/docs/image-generation)
- [NovelAI 多人物](https://docs.novelai.net/en/image/multiplecharacters/)
- [NovelAI 精确参考](https://docs.novelai.net/en/image/precisereference/)
- [NovelAI 权重语法](https://docs.novelai.net/en/image/strengthening-weakening/)
- [NovelAI 图像接口文档](https://image.novelai.net/docs/index.html)

## 画师方案覆盖 NAI 请求格式

v1.1.1 的画师方案可选择 NAI，请求体格式与连接路由分别确定。连接仍可为 OpenAI 兼容生图，读取其 `/models`；选用 NAI 画师时生图使用 NAI JSON 和 Bearer 认证，完整图片接口原样使用，根地址则按原连接类型拼接默认图片端点。漫画和定妆图共用该规则，参考图处理也采用 NAI 限制。

支持 NAI ZIP、原始 PNG/JPEG/WebP，以及中转的 OpenAI `data[].b64_json` / `data[].url` 响应。图片 URL 下载不会附带生成接口的密钥。该兼容不包含平台私有签名、异步轮询协议或任意额外响应结构。详细例子见 [NAI中转请求说明](NAI中转请求说明.md)。
