# 网页、搜索与 Skills

[文档索引](README.md) · [项目首页](../README.md)

## 网页读取

在聊天中发送“读取并总结 https://example.com/”，模型可使用 `read_web`。网页读取默认启用，可在 **设置 → 允许联网** 关闭；停用后既不向模型提供工具，也不接受该工具调用。

- 网页读取仅支持 HTTP/HTTPS GET，搜索使用独立接口；网页读取不携带模型密钥、登录 Cookie 或自定义认证头。地址不能包含用户名和密码；每次重定向重新校验协议，最多跟随 5 次。
- 一次读取含重定向最多 30 秒，响应最多 1 MiB；HTML 提取静态正文与标题，文本、Markdown、JSON 等按文本返回。正文最多 20000 字符、链接最多 30 个，超过时分别标记截断。
- 脚本、样式等不进入 HTML 正文；不会执行 JavaScript、绕过登录或验证码。PDF、图片、无正文页面、不支持的编码和 HTTP/网络错误会明确返回失败。
- 网页结果带有来源 URL 和 `trust: untrusted`，作为资料交给模型；停止会销毁正在进行的网络请求，阻止后续工具。网页内容仍可能不完整或过时，引用应保留来源并说明截断。
- 网页读取将网站声明的 favicon 地址保存为独立的界面元数据（未声明时使用站点 `/favicon.ico`），不放入发给模型的工具结果；旧版结果中的该字段在加载时迁移。工具行在允许联网时加载并显示原色图标；加载失败、旧记录没有图标信息或关闭联网时保留通用图标，不重新读取网页，也不通过第三方图标服务查询。

## Skills 导入与调用

在 **设置 → 管理 Skills → 添加** 导入单个 `SKILL.md` 或粘贴其内容，检查后保存。例如：

```markdown
---
name: page-summary
description: 总结用户提供的网页，提取要点并保留来源链接
---

先读取用户提供的网址，再整理三个要点。保留来源 URL；读取失败或正文截断时明确说明。
```

Skill 引用 `references/guide.md` 等文件时，在编辑页填写相同的相对路径，再导入或粘贴参考文本并点击“添加参考文件”。这些内容作为副本保存在本机；没有持续的外部目录授权。当前不批量导入目录或 ZIP，不运行 Shell、Python、Node.js 或 Skill 内脚本。

- 元数据支持 `name`、`description` 的普通/引号文本及 `|`、`>` 多行文本；不是完整 YAML 实现，对这些字段中的对象、引用或无效值明确报错。其他元数据保留在文档中，不授予工具权限。
- 支持 `disable-model-invocation: true`，该 Skill 只在用户显式调用时提供给模型。点击“使用”会把 `/skill:名称` 放入聊天草稿，也可手动输入 `/skill:page-summary 读取这个链接……`。
- 默认仅把已启用、允许本轮使用的 Skill 名称和简介加入上下文；`read_skill` 读取正文时列出参考路径。未导入参考文件、越界路径、重复名称或未启用的 Skill 均明确报错。
- 每次运行固定可用 Skill 及其正文副本；工具结果按现有检查点落盘并参与历史回放。之后停用或删除不会删除旧对话里已经读取的资料。
- 最多保存 20 个 Skills，每个最多 16 个参考文件。单个文档最多 32000 字符，所有文档合计最多 512000 字符；文件选择器单次导入只接受最多 64 KiB 的 UTF-8 文本。

## 联网搜索

- **设置 → 联网搜索**：通用 `search_web` 接口支持 DeepSeek 原生搜索和 Tavily，分别适配请求与结构化来源，统一返回标题、URL、摘录及可用的来源时间。DeepSeek 默认使用 Harness 的 Anthropic Messages 搜索协议，基础地址与模型可编辑；只有一个地址匹配的已启用 DeepSeek 模型服务时，默认复用其安全存储密钥，多个时需选择。运行时解析服务引用，跟随密钥轮换；服务删除、停用或地址不匹配时明确失败。也可配置独立搜索密钥；Tavily 使用独立密钥。搜索默认关闭，“允许联网”同时控制网页读取和搜索。搜索密钥不进入模型上下文、日志或备份；辅助请求单独记录用量，服务未报告 Token 时保持未知。DeepSeek 只接受结构化原生搜索结果，不将模型自由回答作为来源。

## 搜索适配

`WebSearchTools` 只依赖统一 `SearchTransport.search()`；`NativeSearchTransport` 负责凭据解析、超时、取消、禁止重定向及用量记录，`services/search/DeepSeekSearchProvider.ets` 与 `TavilySearchProvider.ets` 各自编码请求和解析结构化结果。新搜索服务在此层适配，不修改 Agent Loop。

Tavily 请求字段参考 [Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search)；DeepSeek 搜索协议对照本地 DeepSeek Harness `packages/web/web-search-deepseek`。接口和账号是否实际支持原生搜索需联调确认；普通聊天接口可用不表示搜索一定可用。

## 验证

本地测试包含 Skill 元数据/资料校验、手动调用限制、工具启停、网页正文提取、截断与错误、取消，以及通过真实 Agent Loop 读取 Skill 和网页后保存、恢复调用结果的流程。

运行 `node scripts/test-harness-features.cjs` 验证搜索提供方、密钥复用与轮换、设置提交失败回滚、取消和重定向、文件回执恢复、引用快照隔离、重复调用提醒及有限重试；已纳入 `scripts/test.ps1`。测试使用真实业务代码与确定性网络/存储适配，不消耗在线额度。
