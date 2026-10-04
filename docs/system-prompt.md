# Tinybot 系统提示词

提示词集中维护在 `entry/src/main/ets/model/SystemPrompt.ets`。参考本地 pi 源码 `packages/coding-agent/src/core/system-prompt.ts`（`6f1072cc0`）的分层结构，自行编写适合手机助手的内容，不继承 pi 的终端、编程或文档访问能力。

上游参考：[pi system-prompt.ts](https://github.com/earendil-works/pi/blob/6f1072cc0/packages/coding-agent/src/core/system-prompt.ts)。

## 组成

1. `DEFAULT_SYSTEM_PROMPT`：应用固定维护的身份、主动执行、核验和沟通风格，不提供用户编辑入口。默认按用户消息语言回答，支持中文和英文。
2. `runtimeInstructions`：每次请求附加工作区范围、工具使用和执行限制。网页章节仅在启用网页读取时加入。实际工具定义是能力依据，员工受限工具也必须遵守这个边界。
3. `userDocumentContext`：设置页的“用户文档（USER.md）”保存称呼、背景与回答偏好，从下一轮起加入所有对话及团队上下文。内容以 JSON 字符串界定，不能替换系统规则、授予工具权限或覆盖本轮明确要求；空白文档不注入。
4. `skillCatalog`：沿用已有逻辑，按启用状态和显式选择附加 Skills 目录，需要时读取正文。
5. `CHAT_TEAM_INSTRUCTIONS`：只对开启团队模式的聊天主 Agent 附加，涵盖按需招募、路径分工、事件等待、交接核验和最终整合。
6. `teamWorkerInstructions`：员工任务范围和内部交接要求。仅聊天团队员工需要 `team_complete_task`；旧团队执行路径不虚构此工具。

主 Agent 和员工共用基础风格与工作区边界。员工不继承主 Agent 的招募指令。记忆、会话分支说明和任务上下文仍由现有调用方追加。

## 升级与验证

加载没有 `userDocument` 的旧配置时，三个已发布的内置默认提示词精确匹配为空用户文档，其余自定义内容原样迁移。已有 `userDocument`（包括明确清空的文档）保持不变，系统提示词恢复为应用内置版本。界面语言切换不翻译文档内容。

当前 USER.md 是应用管理的 Markdown 文档，存储于全局会话配置 `config.userDocument`，不在各会话工作区创建副本。保存沿用配置的原子提交，失败保留已保存值；返回编辑页外时丢弃未保存草稿。备份保留文档，导入时仅在本机文档为空时恢复备份偏好，不覆盖本机已有的非空文档。

`SystemPrompt.test.ets` 覆盖旧版本迁移、自定义内容保留、条件章节组合和员工交接差异。全套测试：`scripts/test.ps1 -StudioPath 'D:\DevEco Studio'`。这些测试验证组装行为；真实模型执行仍受模型能力、上下文和工具结果影响。
