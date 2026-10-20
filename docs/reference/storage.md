# 磁盘布局

Tinybot 不使用数据库：会话、配置、用量、附件和工作区都是应用沙箱里的普通文件。这一页给出目录树、各文件的格式与生命周期，便于备份、排查和判断“删了什么会丢什么”。文件工具只能看到工作区，其余目录不对模型开放。会话与项目如何共享目录见[项目与共享工作区](/guide/projects)，云备份的使用流程见[华为云空间备份](/guide/cloud-backup)。

## 目录树

两个 `filesDir` 不是同一个目录：会话、用量与诊断日志写在 UIAbility 上下文的 `filesDir`，附件、工作区与 CPU Profile 写在应用级 `ApplicationContext.filesDir`。

```text
<ability filesDir>/
├─ sessions-v2/
│  ├─ index.json                 会话清单 + 全局配置
│  ├─ <uuid>.json                每个会话一个文件
│  └─ index.json.tmp             清单提交的中间文件
├─ usage-records/
│  ├─ index.json                 {"version":1,"pages":N}
│  └─ 0.json、1.json …           每页 256 条用量记录
├─ tinybot-v1.json               旧版单文件会话，迁移后保留
├─ usage-ledger.json             旧版单文件用量，迁移后保留
├─ performance-current.jsonl     诊断日志（当前）
└─ performance-previous.jsonl    诊断日志（上一份）

<app filesDir>/
├─ attachments/
│  ├─ <id>.jpg                   图片附件，JPEG
│  ├─ <id>.txt                   文本附件正文
│  └─ extract-<uuid>.pdf         PDF 抽取时的临时副本
├─ workspace/
│  └─ <workspaceId>/
│     ├─ …                       会话或项目文件
│     └─ .tinybot-review/        修改前基线，界面审阅用
└─ tinybot-cpu.json              CPU Profile 导出

<cacheDir>/
├─ backup-<uuid>.json            本地导出或上传前的快照
├─ conversation-<uuid>.md        会话导出
├─ chart-<uuid>.csv              图表数据导出
├─ tinybot-performance.json      诊断包
└─ <uuid>-<name>                 分享用的稳定副本

<cloudFileDir>/
└─ tinybot-backups/
   ├─ tinybot-<13位时间戳>-<uuid>.json
   └─ *.partial                  未完成的临时文件
```

## 会话 v2 索引与独立会话文件

清单是唯一入口，结构固定：

```json
{
  "version": 2,
  "data": { "config": {}, "extensions": {}, "productivity": {}, "providerProfiles": [], "projects": [], "activeThreadId": "" },
  "threads": [{ "id": "<会话ID>", "file": "<uuid>.json" }]
}
```

- `data` 保存全局配置、扩展设置、助手资料、服务列表与项目；`threads[]` 只保存会话 ID 与文件名的映射，会话内容在独立文件里。
- 变更的会话写成新的 `<uuid>.json`（内容不可变），随后写 `index.json.tmp` 并重命名为 `index.json`，最后删除不再被引用的旧文件。删除失败只留下无害的孤儿文件，不会被加载。
- 清单文件名必须匹配 `^[a-zA-Z0-9-]+\.json$`，加载时还要求文件内的 `id` 与清单一致；损坏时报“会话索引损坏，原文件已保留”，不会覆盖。
- 首次启动没有 `sessions-v2/index.json` 时，会尝试读取旧的 `tinybot-v1.json` 并写成 v2；旧文件不会被删除。
- 会话消息按用户/助手成对校验，工具步骤同时校验状态、参数上限与预览快照；加载时会把状态为 `generating` 的回答改为 `stopped`，并中断遗留的 `running` 调用。
- 清单提交是原子的：写文件用截断后循环写入加 `fsync`，重命名切换引用，因此崩溃后要么看到旧清单，要么看到新清单。

## 用量账本分块

| 文件 | 内容 |
| --- | --- |
| `usage-records/index.json` | `{"version":1,"pages":N}`，只记录页数 |
| `usage-records/<n>.json` | 第 n 页，最多 256 条请求用量 |

- 记录按请求 ID 去重，后写入的覆盖先写入的；加载时如果内存中已有同 ID 记录，以内存版本为准。
- 写入先写 `.tmp` 再重命名，页数变化或清单缺失时重写清单。
- 旧版 `usage-ledger.json` 会被一次性读入并重新分块；迁移完成后旧文件保留，作为恢复副本。
- 账本没有条数上限，也没有清理入口；它不在备份范围内，只在清除应用数据时消失。
- 会话步骤里保留当轮用量快照，全量统计与筛选以这份账本为准。

## 附件与图片

- 图片导入时按最长边缩到 1600 px、JPEG 质量 85，压缩后超过 4 MB 直接拒绝；原图上限 20 MB、8000 万像素。文档（PDF、DOCX、XLSX、PPTX）上限 8 MB，抽取为纯文本后按文本附件保存。
- 文本附件正文同时存在于会话记录的 `text` 字段与 `<id>.txt` 文件；图片只存 `<id>.jpg`，模型请求前再编码成 data URL。
- 预览截图、网页批注、手绘示意都走同一条图片保存路径，写入 `attachments` 并作为附件记录引用。
- 每条消息最多 4 个附件；恢复时要求字节数与记录中的 `size` 一致，缺失或不一致直接拒绝。
- 代码里没有按会话回收附件的路径：删除会话只移除索引与消息，附件文件仍留在 `attachments` 中。

## 工作区

- 路径为 `workspace/<workspaceId>`：普通会话用会话 ID，项目会话用项目的稳定 `workspaceId`（新建时为 `project-<uuid>`）。目录在首次进入会话或创建项目时建立，已有会话启动时自动补建。
- 工作区工具只能读写该目录内的相对路径，拒绝符号链接与越界；写入通过 `.tinybot-<uuid>.tmp` 临时文件和重命名完成，列表会过滤这类内部项。
- `.tinybot-review/` 保存被修改文件的原始基线（`{path, existed, content}`，文件名用 URL 编码后的相对路径）。接受修改或恢复后基线删除；“文件”页面的预览与恢复依赖它。
- 删除会话不删除工作区；项目在当前版本只有创建与编辑，没有删除入口。卸载应用或清除应用数据才会删除这些文件。
- 单个工作区没有容量上限；备份时才受 20 MiB 与 1000 个文件的限制。

## 备份文件

- 本地导出与华为云备份共用同一份快照：外层格式为 `tinybot-harmony.backup.v2`（可读 v1），包含 `data`、`attachments`、`files`，分别保存脱敏后的会话数据、附件字节和工作区文件字节。
- 快照会重置 `config`（只保留 `userDocument`）、清空服务凭据别名并停用服务与搜索；恢复时再与本机设置匹配。
- 云目录固定为 `<cloudFileDir>/tinybot-backups`，文件名是 `tinybot-<13位时间戳>-<uuid>.json`；先写 `.partial` 再重命名，列表只收录完成的 `.json`。
- 本地导出的临时文件写在 `cacheDir/backup-<uuid>.json`，交给系统文件选择器后删除。
- 单份备份最多 20 MiB、1000 个工作区文件；每次手动备份都会新增一份，首版没有自动清理。删除只 `unlink` 选中的快照，再请求云端同步，不触碰工作区、会话或其他备份。
- 恢复只新增独立副本：已有会话不覆盖，新附件分配新 ID，新项目使用新的物理目录；已有项目保留本地名称、指令与文件。

## 诊断日志

- 开发者模式开启采集后，性能事件与运行日志按批追加到 `performance-current.jsonl`；单文件约 4 MiB 时轮转为 `performance-previous.jsonl`，只保留当前与上一份。
- 每批约 5 秒写入一次，进程异常退出可能丢失最后一批，不是同步崩溃日志。
- “停止并导出”生成 `cacheDir/tinybot-performance.json`（schema 2，含统计、事件、两份日志与 traceEvents）；CPU Profile 单独写到 `<app filesDir>/tinybot-cpu.json`。
- “清除诊断数据”停止采集，删除两份 JSONL、导出包与 CPU Profile，并清空内存统计。关闭采集不会删除已写入的文件。
- 日志只含白名单字段，不含密钥、URL、工具参数、文件路径或系统堆栈；Debug/Info 在关闭采集时不落盘，Warn/Error 仍进入系统 HiLog。

## 容量与配额

| 对象 | 上限 | 依据 |
| --- | --- | --- |
| 单份云备份或本地导出 | 20 MiB、1000 个工作区文件 | 超过时备份失败，不生成部分快照 |
| 单个工作区 | 没有应用级上限 | 只受设备存储限制 |
| 单条消息附件 | 4 个 | 导入与记录校验共用同一上限 |
| 单张图片 | 原始 20 MB、8000 万像素；保存后 4 MB | 最长边缩到 1600 px、JPEG 质量 85 |
| 单份文档 | 8 MB | 抽取为文本后按文本附件保存 |
| 会话文件 | 没有条数上限 | 每个会话一个独立文件 |
| 用量账本 | 没有条数上限 | 每页 256 条，按需追加 |
| 诊断日志 | 每份约 4 MiB，保留两份 | 约 5 秒一批，超出时轮转 |

## 生命周期与清除

| 路径 | 写入时机 | 清除方式 | 进入备份 |
| --- | --- | --- | --- |
| `sessions-v2/index.json` | 任何会话或全局配置提交 | 清除应用数据 | 是 |
| `sessions-v2/<uuid>.json` | 该会话内容变化 | 清单切换后删除旧文件；删除会话时移除引用 | 是 |
| `usage-records/*` | 每次请求与工具结束后异步写入 | 无入口，随应用数据清除 | 否 |
| `attachments/*` | 导入附件、截图、批注、手绘 | 无自动回收，随应用数据清除 | 是 |
| `workspace/<id>/*` | 文件工具写入、文件页编辑 | 删除会话不清理；随应用数据清除 | 是 |
| `workspace/<id>/.tinybot-review` | 首次修改文件前 | 接受修改或恢复后删除 | 否 |
| `tinybot-backups/*.json` | 手动备份 | 单份删除或系统清理 | — |
| `performance-*.jsonl` | 开发者模式采集期间 | 清除诊断数据 | 否 |
| `cacheDir/*` | 导出、分享、诊断包 | 系统缓存回收或清除诊断数据 | 否 |

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/model/ConversationStore.ets` | v2 清单、独立会话文件、原子提交与旧版迁移 |
| `entry/src/main/ets/model/WorkspaceStore.ets` | 工作区根目录、目录创建与校验 |
| `entry/src/main/ets/model/Workspace.ets` | `workspaceId` 到目录名的推导 |
| `entry/src/main/ets/services/UsageLedger.ets` | 用量分块、清单与旧账本迁移 |
| `entry/src/main/ets/services/Attachments.ets` | 附件保存、导入、压缩与读取上限 |
| `entry/src/main/ets/services/Backup.ets` | 快照打包、脱敏、恢复与本地导出 |
| `entry/src/main/ets/services/CloudBackup.ets` | 云目录、上传状态、下载与单份删除 |
| `entry/src/main/ets/services/NativeWorkspaceFiles.ets` | 工作区写入、版本哈希与修改基线 |
| `entry/src/main/ets/services/DeveloperDiagnostics.ets` | 诊断日志轮转、导出与清除 |
| `entry/src/main/ets/services/NativeActions.ets` | 分享副本与本地导出临时文件 |
