# 开发与验证

App 内隐藏开发者模式的开启方式、指标口径、诊断导出及采样限制见[性能诊断](developer-diagnostics.md)。

[文档索引](README.md) · [项目首页](../README.md)

## 环境与构建

需要 DevEco Studio API 26 SDK、DevEco CLI，以及真机调试所需的华为开发者账号。以下命令均从仓库根目录执行。架构分层见[架构与运行管理](architecture.md)。

```powershell
# 首次克隆时创建本机配置；已有文件时不要覆盖
if (-not (Test-Path build-profile.json5)) { Copy-Item build-profile.template.json5 build-profile.json5 }
devecocli check arkts
devecocli build
.\scripts\test.ps1
```

若 `devecocli` 不在 PATH，可用 `& "$env:APPDATA\npm\devecocli.cmd"` 代替。`test.ps1` 优先读取 `DEVECO_STUDIO_HOME`，默认使用 `C:\Program Files\Huawei\DevEco Studio`；不依赖工作区中的下载技能。

未配置签名时，构建生成 `entry/build/default/outputs/default/entry-default-unsigned.hap`。真机调试：

```powershell
devecocli device list
devecocli auth login
devecocli signature generate
devecocli run --device <设备名称或序列号>
```

签名命令会修改 `build-profile.json5` 并在本机保存签名材料。该文件已加入 `.gitignore`；版本库使用不含签名的 `build-profile.template.json5`，修改 SDK 或模块配置时需同步模板。工程当前不自动生成发布签名。

## 华为账号配置与验证

入口模块 `module.json5` 的模块级 `metadata` 配置公开的 `client_id`，值为 AppGallery Connect 中该 HarmonyOS 应用的 Client ID，不使用 Client Secret。调试和发布包须分别在华为平台配置实际签名证书的 SHA-256 指纹，并核对包名 `com.sudojacky.tinybot`；配置生效时间以平台提示为准。普通登录不申请手机号、头像或其他用户资料权限。

`node scripts/test-huawei-account.cjs` 验证实际账号服务、安全存储和 SessionService/ProviderRegistry 路径：登录成功/取消、错误码脱敏、重启恢复、账号切换、退出与迟到回调、存储失败及未登录请求拦截。真机仍需验证平台配置、用户主动登录、重启恢复、退出后拦截与重新登录。该接入不代表实名审核已通过。

参考：[Account Kit](https://developer.huawei.com/consumer/cn/sdk/account-kit)、[系统账号状态查询与登录事件](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/account-login-state-V14)。

## 中英文词条

维护方式见 [locales/README.md](../locales/README.md)。修改双语 JSON 后运行 `node scripts/build-locales.cjs` 生成同步词条，`--check` 验证词条、占位符和代码引用完整性。

内置 Skill 的文本源与打包、升级和验证方式见 [网页、搜索与 Skills](web-and-skills.md#内置-skills)。修改 `skills/` 后运行 `node scripts/build-builtin-skills.cjs`，并维护内置显示名称和简介的双语词条；打包检查已纳入 `scripts/test.ps1`。

## 应用图标

HarmonyOS 图标源文件为 `assets/app-icon.svg`，背景铺满正方形，不预裁圆角、不加外边距或外框；内部 Logo 沿用原有比例。应用与桌面入口引用 `tinybot_layered_icon`，由系统合成前景、背景并裁切外形。启动窗口、关于页和交付素材使用同源合成 PNG；模块的 `dark/media/tinybot_icon.png` 按深色启动背景与正文色生成，由系统资源匹配选择。资源均为 1024×1024；只修改本项目源文件，不覆盖桌面版图标。

修改源文件后，在项目根目录重新导出（渲染工具仅安装在忽略的缓存目录）：

```powershell
npm install --prefix .cache/icon-tools --no-save --package-lock=false --ignore-scripts @resvg/resvg-js@2.6.2
node scripts/build-app-icons.cjs .cache/icon-tools/node_modules/@resvg/resvg-js
```

## 自动化验证

构建后运行 `node scripts/test-legal-documents.cjs`，验证用户协议与隐私政策的实际编译读取路径、完整 Markdown 正文及缺失、空白和无效编码资源的错误展示；已纳入 `scripts/test.ps1`。模拟器中从“设置 → 关于 Tinybot”分别打开两个文档，检查全文滚动和返回。阅读页面不写入同意记录。

- ArkTS 本地测试覆盖流式分帧和工具参数组装、多轮执行、取消、步数限制、执行前落盘失败、工具错误恢复、历史协议还原及工作区路径边界，也覆盖 provider 注册、配置快照、事件顺序和运行收尾。

原生文件迁移、云备份、MCP 传输与确认流程还有可复现的适配测试：

`node scripts/test-productivity-native.cjs`（可用 `DEVECO_STUDIO_HOME` 指定 SDK 位置）。

`node scripts/test-tool-schemas.cjs` 用 SDK 自带的 JSON Schema 校验器检查原生对象/数组参数、编辑必填字段及三种模型协议的实际请求结构，并执行表单、计划、图表、记忆、Skill、MCP 审批和沙箱输入路径；已纳入 `scripts/test.ps1`。

`node scripts/test-tool-discovery.cjs` 检查 BM25 排序与中英文分词、递归参数检索、5 个默认初始工具、按需 schema/预览规则、权限撤销、串行执行、团队交接和真实 SessionService 的多步加载路径；覆盖未展开的目录/文件搜索工具通过现有编排执行、子回执保存与路径/修改前读取保护，并在同一工具目录下比较全量与按需请求体积；已纳入 `scripts/test.ps1`。报告字符数及本地 Token 估算，不将其等同于服务端计费。

构建后运行 `node scripts/test-send-motion.cjs`，验证发送动效的实际编译后生命周期、输入区坐标换算、首条消息、历史恢复、切换会话、发送未被接受及后续队列消息隔离；动画观感和列表裁剪仍需在真机验证。

画板使用 Pen Kit 的 `HandwriteComponent` 和 `HandwriteController`；`EntryAbility` 按官方接入要求设置 `_brushEngineContext`。系统组件管理笔迹和工具栏，`getContentRange` 与 `getThumbnail` 导出笔迹区域，`Attachments.saveDrawing` 使用 ArkGraphics2D 合成白底后编码 JPEG，避免透明笔迹变黑底。构建后运行 `node scripts/test-drawing-board.cjs`，验证实际编译的初始化和加载回调、空白校验、原生导出失败、像素释放、重复保存防护、弹层隔离，以及草稿附件保存和会话切换隔离；已纳入 `test.ps1`。系统笔刷、橡皮擦和撤销重做需在真机验证。

Release 混淆规则必须保留 `globalThis` 全局名，避免 Pen Kit 的 ambient namespace 声明被顶层混淆改写，导致 `EntryAbility.onCreate` 引用不存在的变量。运行 `devecocli build --build-mode release` 后，以 `node scripts/test-release-models.cjs` 检查实际混淆产物的 Ability 初始化、全局画板上下文与模型数据兼容性；安装后还需确认应用实际进入页面，启动命令返回成功本身不代表页面已加载。

浏览器批注的原生 `PixelMap` 以普通组件参数传递并在批注页退出时释放，不使用 `@Prop` 复制或代理原生句柄；标题和截图尺寸单独作为响应式参数。批注页显示截图、圈画后添加到消息及发送附件，需在真机验证。

构建后运行 `node scripts/test-thinking-motion.cjs`，验证思考状态的循环、结束交叉渐变、历史静态挂载、快速切换文案、离屏暂停与卸载清理；配合 `test-chat-disclosures.cjs` 确认手动展开状态不受影响。呼吸、扫光与展开效果在真机使用实际推理响应验证。

构建后运行 `node scripts/test-turn-workflow.cjs`，验证整轮真实阶段、并行工具、重试/停止/失败、保留节点的最新步骤、完成收束及手动展开和预览保留。

流式富文本的新增片段以 240ms ease-out 从透明淡入，不延迟接收或按空格切分中文，不对已读前文重复播放。回复结束后保留最后一批文字的淡入，历史挂载静态显示；离屏或卸载停止计时。正文、表格和代码均复用原生 Span，保留排版、链接和复制，不使用整段模糊。

构建后运行 `node scripts/test-markdown-performance.cjs`，验证增量 Markdown 与全文解析在逐字符边界的一致性、稳定块复用、代码预览与展开、实际编译渲染回调的最新文本，以及离屏高度占位、重新测量、回复结束的渐显收尾和计时器清理；该项与 `test-stream-reveal.cjs` 均纳入 `test.ps1`。真机性能比较使用同一固定负载、采样窗口和构建类型，先回到空对话并重启进程，分别记录 UI 任务分布和内存工具口径。

构建后运行 `node scripts/test-project-tree.cjs`，用真实会话服务与视图模型验证侧栏项目分组、普通聊天、空项目、同名项目、置顶顺序、搜索展开、归档、独立分页及新建会话归属；分支线和折叠动效在真机验证。

`node scripts/test-history-drawer.cjs` 验证编译后的侧栏关闭动画、拖动和中断恢复。关闭动画完成后停止渲染列表内容，保留搜索和分页状态，避免隐藏侧栏随聊天流式输出持续重建。真机性能复现使用 `Generate an SVG of a pelican riding a bicycle.`，分别检查等待模型、工具执行和预览发布期间的主线程延迟与 CPU Profile。

`node scripts/test-custom-tools.cjs` 验证完整版/自定义选择、12 项能力对 30 个可选工具的完整覆盖、旧的部分禁用配置迁移、记忆/Skills 重复禁用记录清除与专门设置生效、组内所有入口的目录与执行限制，以及基础文件权限、编排与团队继承和会话恢复。构建后运行 `node scripts/test-custom-tools-renderer.cjs`，验证能力行的实际编译回调、浏览器/预览/团队/MCP 联动、开关计数、批量操作及忙碌/归档/保存错误时的禁用状态；两项已纳入 `test.ps1`。

`node scripts/test-thread-list-renderer.cjs` 使用编译后的回调与稳定分组节点，验证会话改名、删除、归档、恢复、置顶/取消置顶的排序与菜单、新建及项目改名后的即时刷新和计数，也验证从搜索、归档页面创建项目后显示新分组；只执行读取了变化状态的更新回调，防止分组闭包保留旧数组。

`node scripts/test-appearance.cjs` 验证外观偏好、保存回滚与启动初始化顺序：明暗模式和字号在 `EntryAbility.onCreate` 中、首屏创建前应用；`loadContent` 后仅激活 ArkUI 主题，避免启动图退出时重新配置窗口而出现从左上角展开的矩形。设备验证需连续冷启动并检查启动图到会话的过渡帧。

设置的编辑、管理与外观选择使用原生导航子页。构建后运行 `node scripts/test-settings-navigation.cjs`，验证实际编译的表单草稿、保存失败与重试、MCP 凭据保留及警告返回、模型子页返回时的密钥生命周期和外观保存后的返回行为；已纳入 `test.ps1`。模拟器检查右侧进入、系统返回、表单键盘避让与模型草稿，测试时不覆盖已有服务凭据。用量筛选和开发者模式验证继续使用临时弹层。

系统启动页使用 `startup_wordmark.svg` 的居中 Tinybot 文字，浅色与深色资源分别使用柔和灰色和低亮度灰绿色，背景沿用对应的 `start_window_background`。文字已转成矢量轮廓，不依赖设备字体；桌面和应用内图标继续使用原资源。验证需分别切换系统浅色/深色并冷启动；系统启动资源的明暗选择与应用页面内的强制明暗设置应分别检查。

`node scripts/test-i18n-native.cjs` 验证语言偏好与持久化；`node scripts/test-chat-disclosures.cjs` 验证流式更新、过程重开、消息隔离和历史加载时的展开状态。`node scripts/test-tool-details.cjs` 验证分类回执、失败状态与无损分页；构建后运行 `node scripts/test-team-renderer.cjs`，检查 DevEco 实际生成的 Team、工具详情及编排子调用更新回调。`node scripts/test-message-actions-renderer.cjs` 验证改写、重新生成、分支按钮在会话结束后恢复可用，再次忙碌或保存出错时禁用；复制保持可用。

构建后运行 `node scripts/test-onboarding.cjs`，验证首次使用判断、完成记录持久化、旧草稿保护、重复点击与保存失败重试，以及六幕引导第一步的华为账号同意/登录/稍后登录、唤醒中断、拖动边界和回弹、后台/覆盖页暂停、卸载清理、真实服务编辑路由与可编辑首条草稿。模拟器中从“设置 → 使用帮助 → 首次使用指引”重新体验，检查能力卡片的点按与左右滑动、模型配置页取消后返回、键盘出现时底部操作，以及完成后仅准备独立草稿、跳过不改动原聊天。画板模块只在确认设备支持系统手写、用户点击入口后动态导入；不支持时明确提示，不加载 Pen Kit 或创建原生控制器。`lazy import` 仍会遍历共享模块依赖，无法避免模拟器缺少 Pen Kit 时的启动失败。

`node scripts/test-answer-speech-native.cjs` 验证回答朗读的分段、取消、后台释放、系统失败和快捷入口分发；构建后运行 `node scripts/test-launch-actions-renderer.cjs`，用实际生成的页面方法验证快捷入口保存草稿、创建独立会话、忙碌拒绝及听写单次触发。

本地测试覆盖指令顺序、整批工具边界、无工具回答后的追加、取消、落盘失败、上下文和步数限制、历史回放与压缩、会话隔离和重启恢复。真机使用本地模拟模型验证追加后连续执行多个任务，以及停止、错误、重启、撤回编辑和恢复执行。

## 历史验证记录

以下为原 README 保留的 2026-10-02 阶段记录，测试数量及设备结果属于当时版本，不代表当前版本的完整验证状态。

2026-10-02 验证：154 项 Hypium 测试、16 项原生适配测试通过；81 个 ArkTS 源文件检查无错误。Mate 70 Pro+ 真机验证表单提交后续跑、计划更新、原生图表、文件创建/唯一替换/搜索/按行读取、差异预览与恢复。OAuth、图片接口和模型发现使用模拟服务验证协议、取消/确认及凭据边界；尚未完成实际 OAuth 服务与图片模型的端到端联调。

记忆按钮修正后：Hypium 增至 158 项全部通过，83 个 ArkTS 文件检查无错误；新增覆盖候选不落盘、空/无效结果不回退原文、取消、来源与范围、去重及保存失败回滚。真机确认临时内容返回空候选，长期偏好从多段回答提炼为独立短条目。

2026-10-02 自动测试：88 个 ArkTS 源文件检查无错误；186 项 Hypium 与 16 项原生适配测试通过。覆盖运行中追加与第二批招募、权限与会话隔离、持久化交接、等待和取消、产物变化检测、同轮整合及重启恢复。

同日已在 Mate 90 Pro 模拟器使用已配置的 DeepSeek `deepseek-flash` 验证：从 `/team` 命令启用，主 Agent 自主招募两名员工并行写入独立文件，读取已提交产物后亲自生成报告；下一轮继续向同一团队追加只读审阅员工并汇总其交接，原任务不变。收拢聊天界面后再次验证菜单入口移除、历史团队卡片展开及任务交接/执行记录查看；新版本安装与启动冒烟检查通过。

## 本地资料与品牌资源

`docs/local/` 保存本机工具资料和验证证据，不发布到 GitHub。Tinybot 品牌图形来自桌面项目；脚手架中的华为版权声明保留。
