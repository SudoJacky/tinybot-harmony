# 安装与首次启动

这页说明 Tinybot 在什么设备上可安装、安装包从哪里获取、第一次打开时应用写了哪些数据，以及卸载、清除数据和升级各自会影响什么。

## 设备与系统要求

| 项目 | 要求 | 依据 |
| --- | --- | --- |
| 设备形态 | 手机、平板与 2in1（PC、二合一，`phone`、`tablet`、`2in1`）；2in1 使用桌面窗口布局 | `entry/src/main/module.json5` 的 `deviceTypes` |
| 最低系统 | HarmonyOS 6.0.0（API 20），`compatibleSdkVersion` 为 `6.0.0(20)` | `build-profile.template.json5` |
| 目标系统 | `targetSdkVersion` 为 `26.0.0` | `build-profile.template.json5` |
| 发布包架构 | 仅 `arm64-v8a` | `docs/distribution/START-HERE.txt` |
| 模拟器 | 使用单独构建的调试包（含 `x86_64`），不随正式包分发 | `docs/distribution/START-HERE.txt` |

当前版本为 1.3.3 / 1003003，包名 `com.sudojacky.tinybot`。应用不内置模型额度，也不在设备内运行大模型；模型能力、费用与可用性由你配置的模型服务（Provider）决定。

在 2in1 设备上，应用以可缩放窗口运行，最小窗口为 360 × 420 vp；窗口宽度达到 720 vp 时进入工作表布局。平板使用 840 vp 断点，两者共用命令面板、会话详情与旁聊，见[大屏工作台](/guide/desktop)。

### HarmonyOS 6 上的能力差异

同一个安装包可以在 HarmonyOS 6（API 20）与 HarmonyOS 7（API 26）上运行，系统没有的能力会在使用时给出明确提示：

- **沉浸光感材质**：HarmonyOS 6 没有该系统模块，界面使用普通配色。外观设置中的“光感效果”显示“此系统不支持”，并保留你之前保存的偏好，换到支持的设备后继续生效。
- **PDF 文字提取**：HarmonyOS 6 未提供 PDFKit 模块，仍可导入并保留 PDF 原件，读取时提示“此系统的 PDF 组件未提供文字提取”，不会生成空白文本。可把 PDF 页面截图作为图片附件发送，或改用 Office、文本文件。
- **网络重定向**：携带凭据的请求（模型服务、搜索、MCP、OAuth、反馈、公告）在 API 20 上同样不跟随重定向，网页读取仍逐跳校验并最多五跳。

## 安装包从哪里来

| 来源 | 产物 | 前置条件 |
| --- | --- | --- |
| 华为应用市场 | 已签名的发布包 | 应用已上架且对该设备可见；上架状态、年龄分级与发布地区以市场页面为准 |
| 交付目录 | `packages/Tinybot-<版本>-<versionCode>-release-UNSIGNED.app`（当前为 `Tinybot-1.3.3-1003003-release-UNSIGNED.app`） 与同名 `.hap` | 需完成正式签名后才能安装或提交审核 |
| 本地构建 | `entry/build/default/outputs/default/entry-default-unsigned.hap` | 需要 DevEco Studio API 26 SDK 与 DevEco CLI，见[环境、构建与签名](/dev/setup) |

交付目录由准备脚本生成：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare-distribution.ps1 -StudioRoot "C:\Program Files\Huawei\DevEco Studio"
```

脚本先检查 ArkTS，再构建 Release APP，核对版本号、`app.debug=false`、包内容、arm64 沙箱库与符号表 Build ID，最后生成独立目录与 ZIP。`-SkipBuild` 只打包既有产物，仍校验结构与版本，但不能证明包含最新代码。

两点容易踩空：

- 目录里的 `UNSIGNED` 文件不是可安装包。Release 编译不等于发布签名，需要在 DevEco Studio 的 Build > Upload Product 选择 `build\outputs\default\tinybot-harmony-default-unsigned.app`，关联包名 `com.sudojacky.tinybot`，用对应发布证书或云管理签名重签。
- 本地 `devecocli build` 在未配置签名时生成未签名 HAP；真机调试需要先 `devecocli auth login` 与 `devecocli signature generate`，再用 `devecocli run --device <设备>`。

## 首次启动做了什么

启动过程按固定顺序完成，界面在数据就绪前显示“正在打开本地会话…”，失败时显示错误与“重试读取”。

1. `EntryAbility` 在首屏创建前应用外观与语言偏好，然后加载页面；在 2in1 上同时设置最小窗口并监听窗口显示与隐藏，用于通知和草稿保存。
2. 组装原生会话服务：会话仓库、运行内核、系统安全存储、工作区与附件目录、模型服务注册表。
3. 打开 ArkData 加密数据库 `tinybot.db`；首次升级时在事务内导入旧版 `sessions-v2/index.json` 或 `tinybot-v1.json`、用量账本和看板文件，逐条读回校验后完成迁移，旧文件原样保留。数据库不可用或密钥无法解开时，启动页提供升级前副本与云备份作为恢复来源。
4. 校验项目数据，安装内置 Skills 的本地副本，检查每个项目的工作区是否存在（不自动创建），并为每个普通会话补建目录；已暂停的待发送队列在加载时保持暂停。
5. 选中上次的会话；没有可用会话时新建一条空会话并保存。
6. 数据就绪后再判断是否展示首次使用引导。

### 首次使用引导

引导顶部显示四步进度。可点已完成的步骤或“上一步”返回查看。

| 步骤 | 内容 | 交互 |
| --- | --- | --- |
| 华为账号 | 同意用户协议并通过系统登录 | 如果发现云备份，可以在此时恢复 |
| 外观与语言 | 选择界面语言和明暗模式 | 修改立即应用，也可接受默认值 |
| 模型服务 | 选择服务商、填写所需的 API Key、选择模型 | 自定义服务可在高级设置里填写地址和协议 |
| 设置完成 | 查看选中的模型 | 点“开始使用”进入聊天 |

首次使用状态保存在设备本地。点“稍后设置”可先进入聊天页，重启后从已到达的步骤继续。未保存的 API Key 需要重新填写。点“开始使用”或成功恢复启动备份后，系统会记录引导已完成。

升级会沿用已有的完成记录。可从“设置 → 使用帮助 → 首次使用指引”或“关于 Tinybot → 首次使用指引”重新打开。

### 还没有配置模型或没有登录时

- 未配置模型时，空会话欢迎页显示“先连接一个模型服务”，按钮“连接你的模型”直接进入设置。
- 未登录华为账号时，聊天底部提示条提供“去登录”；未登录仍可查看本地历史、配置服务、准备草稿和附件，发送时才要求登录。
- 标题、摘要、团队执行与记忆提炼等模型调用同样需要登录。

## 网络与权限

应用声明三项权限：

| 权限 | 用途 | 申请方式 |
| --- | --- | --- |
| `ohos.permission.INTERNET` | 访问你配置的模型服务、网页读取、搜索、MCP 与云备份 | 安装时授予，无运行时弹窗 |
| `ohos.permission.MICROPHONE` | 语音输入，使用系统语音识别服务（支持中文离线识别） | 首次开始录音时由系统弹窗询问，场景为使用时（`inuse`） |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 应用退到后台后继续正在进行的模型流传输 | 由系统长时任务机制管理，完成或中止后释放 |
| `ohos.permission.FILE_ACCESS_PERSIST` | 项目共享文件夹：在项目内保留你通过系统选择器授予的目录读写授权 | 系统授权，跟随你选择的目录长期有效，可随项目解除挂载而撤销 |

其余外部文件访问都通过系统选择器返回的 URI 完成，不申请图库或整个外部文件夹权限：

- 添加图片走系统图片选择器，添加文档走系统文件选择器。
- 导出文件走系统保存选择器，分享走系统分享面板。
- 应用内浏览器与必应联网搜索默认开启；可在设置中关闭，关闭“允许网页读取与搜索”后网页读取与搜索都不再提供给模型。
- 华为云空间备份要先在系统“设置 → 云空间”登录华为账号并开启 Tinybot。

应用不提供独立的代理设置，网络请求走系统网络栈；需要代理的网络请在系统层配置。

## 数据存放位置

会话与工作区都位于应用沙箱（Sandbox）内，路径由系统分配，应用不改用公共目录。会话使用 UIAbility 的 `filesDir`，工作区与附件使用应用级 `ApplicationContext.filesDir`，下面的 `<filesDir>` 按数据类别分别指这两处：

```text
<databaseDir>/tinybot.db                  加密数据库：会话、配置、用量、生活看板与卡片
<filesDir>/sessions-v2/index.json        旧版会话索引（升级后保留）
<filesDir>/sessions-v2/<uuid>.json       旧版单会话文件（升级后保留）
<filesDir>/tinybot-v1.json               旧版单体会话文件（迁移后保留）
<filesDir>/usage-records/index.json      旧版用量账本清单（升级后保留）
<filesDir>/usage-records/<页>.json       旧版用量账本分块（升级后保留）
<filesDir>/usage-ledger.json             旧版账本（迁移后保留）
<filesDir>/workspace/<工作区ID>/         会话或项目工作区
<filesDir>/workspace/<工作区ID>/attachments/<附件ID>/<文件名>   文本与文档原件
<filesDir>/workspace/<工作区ID>/generated-images/<uuid>.png   图片工具生成的结果
<filesDir>/workspace/<工作区ID>/mini-apps/<appId>/             旧版小程序页面与数据（升级保留）
<filesDir>/workspace/<工作区ID>/.tinybot-review/   文件审阅基线
<filesDir>/attachments/<uuid>.jpg        图片附件副本
```

另有三类数据不在上述目录：

| 数据 | 位置 | 进入备份 |
| --- | --- | --- |
| 首次使用记录、界面偏好、2in1 分栏宽度 | 偏好库 `tinybot-ui`（由系统管理） | 否 |
| 模型与 MCP 凭据 | 系统安全存储 | 模型 API Key 经华为账号信息加密后进入备份；MCP 与搜索凭据不导出 |
| 云备份快照 | 系统云目录 `tinybot-backups` | 本身就是备份产物 |

具体目录职责与字段见[磁盘布局](/reference/storage)。

## 卸载、清除数据与升级

**卸载应用或清除应用数据**都会删除沙箱内的全部内容：会话、工作区文件、审阅基线、附件、用量账本、偏好与首次使用记录。华为云空间中的快照不受影响，重装后可在“设置 → 备份与恢复”刷新列表并恢复为独立副本；恢复保留会话与项目 ID，已有会话不会被覆盖，本机已有密钥和服务设置优先。新格式备份中的模型 API Key 可登录同一华为账号恢复；旧备份未包含的密钥，以及 MCP 与搜索凭据，需要重新填写。

**升级**的约束：

- 必须使用相同签名覆盖安装，不卸载、不清空数据；只在干净环境验证全新安装。
- 版本号需要递增，否则平台会拒绝同一 `versionCode` 的再次上传。
- 首次打开新版时，会把旧版会话索引、用量账本与看板文件在事务内导入加密数据库并逐条校验；旧文件原样保留为升级前副本。数据库密钥无法解开时，启动页可从升级前副本或云备份恢复到新的数据库。
- 内置 Skills 以本地副本安装，升级不覆盖同名用户 Skill，也不恢复被停用或删除的条目。
- 旧版工具禁用记录在加载时清理。1.0.1 曾移除旧的图片生成设置与 `generate_image` 接口，当前版本以独立的图片模型配置和 `image_gen`、`view_image` 工具重新提供；图片附件输入、视觉模型与历史图片始终保留。旧记录不会恢复已退役的 `generate_image` 或已停用的图片设置。
- 2in1 的分栏宽度与收起状态保存在 `tinybot-ui`，覆盖升级后继续生效；手机与平板不受这些键影响。
- 本地备份与云备份都兼容 v1 格式，v1 备份恢复为无项目归属的普通会话。

升级后的回归重点是会话、模型配置、草稿与工作区是否完整，可参考[发布清单](/dev/release)。

## 接下来

- 想先聊一句：[第一次对话](/getting-started/first-chat)
- 想先配置模型：[模型服务与上下文](/guide/models)
- 想按任务查功能：[指南总览](/guide/)
