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

## 中英文词条

维护方式见 [locales/README.md](../locales/README.md)。修改双语 JSON 后运行 `node scripts/build-locales.cjs` 生成同步词条，`--check` 验证词条、占位符和代码引用完整性。

内置 Skill 的文本源与打包、升级和验证方式见 [网页、搜索与 Skills](web-and-skills.md#内置-skills)。修改 `skills/` 后运行 `node scripts/build-builtin-skills.cjs`，并维护内置显示名称和简介的双语词条；打包检查已纳入 `scripts/test.ps1`。

## 应用图标

HarmonyOS 图标源文件为 `assets/app-icon.svg`，背景铺满正方形，不预裁圆角、不加外边距或外框；内部 Logo 沿用原有比例。应用与桌面入口引用 `tinybot_layered_icon`，由系统合成前景、背景并裁切外形。启动窗口、关于页和交付素材使用同源合成 PNG。资源均为 1024×1024；只修改本项目源文件，不覆盖桌面版图标。

修改源文件后，在项目根目录重新导出（渲染工具仅安装在忽略的缓存目录）：

```powershell
npm install --prefix .cache/icon-tools --no-save --package-lock=false --ignore-scripts @resvg/resvg-js@2.6.2
node scripts/build-app-icons.cjs .cache/icon-tools/node_modules/@resvg/resvg-js
```

## 自动化验证

- ArkTS 本地测试覆盖流式分帧和工具参数组装、多轮执行、取消、步数限制、执行前落盘失败、工具错误恢复、历史协议还原及工作区路径边界，也覆盖 provider 注册、配置快照、事件顺序和运行收尾。

原生文件迁移、云备份、MCP 传输与确认流程还有可复现的适配测试：

`node scripts/test-productivity-native.cjs`（可用 `DEVECO_STUDIO_HOME` 指定 SDK 位置）。

构建后运行 `node scripts/test-send-motion.cjs`，验证发送动效的实际编译后生命周期、输入区坐标换算、首条消息、历史恢复、切换会话、发送未被接受及后续队列消息隔离；动画观感和列表裁剪仍需在真机验证。

画板使用 Pen Kit 的 `HandwriteComponent` 和 `HandwriteController`；`EntryAbility` 按官方接入要求设置 `_brushEngineContext`。系统组件管理笔迹和工具栏，`getContentRange` 与 `getThumbnail` 导出笔迹区域，`Attachments.saveDrawing` 使用 ArkGraphics2D 合成白底后编码 JPEG，避免透明笔迹变黑底。构建后运行 `node scripts/test-drawing-board.cjs`，验证实际编译的初始化和加载回调、空白校验、原生导出失败、像素释放、重复保存防护、弹层隔离，以及草稿附件保存和会话切换隔离；已纳入 `test.ps1`。系统笔刷、橡皮擦和撤销重做需在真机验证。

Release 混淆规则必须保留 `globalThis` 全局名，避免 Pen Kit 的 ambient namespace 声明被顶层混淆改写，导致 `EntryAbility.onCreate` 引用不存在的变量。运行 `devecocli build --build-mode release` 后，以 `node scripts/test-release-models.cjs` 检查实际混淆产物的 Ability 初始化、全局画板上下文与模型数据兼容性；安装后还需确认应用实际进入页面，启动命令返回成功本身不代表页面已加载。

浏览器批注的原生 `PixelMap` 以普通组件参数传递并在批注页退出时释放，不使用 `@Prop` 复制或代理原生句柄；标题和截图尺寸单独作为响应式参数。批注页显示截图、圈画后添加到消息及发送附件，需在真机验证。

构建后运行 `node scripts/test-thinking-motion.cjs`，验证思考状态的循环、结束交叉渐变、历史静态挂载、快速切换文案、离屏暂停与卸载清理；配合 `test-chat-disclosures.cjs` 确认手动展开状态不受影响。呼吸、扫光与展开效果在真机使用实际推理响应验证。

构建后运行 `node scripts/test-turn-workflow.cjs`，验证整轮真实阶段、并行工具、重试/停止/失败、保留节点的最新步骤、完成收束及手动展开和预览保留。

构建后运行 `node scripts/test-markdown-performance.cjs`，验证增量 Markdown 与全文解析在逐字符边界的一致性、稳定块复用、代码预览与展开、实际编译渲染回调的最新文本，以及离屏高度占位、重新测量和渐显计时器清理；该项与 `test-stream-reveal.cjs` 均纳入 `test.ps1`。真机性能比较使用同一固定负载、采样窗口和构建类型，先回到空对话并重启进程，分别记录 UI 任务分布和内存工具口径。

构建后运行 `node scripts/test-project-tree.cjs`，用真实会话服务与视图模型验证侧栏项目分组、普通聊天、空项目、同名项目、置顶顺序、搜索展开、归档、独立分页及新建会话归属；分支线和折叠动效在真机验证。

`node scripts/test-custom-tools.cjs` 验证完整版/自定义选择、基础文件工具、执行权限、编排与团队继承、会话恢复和记忆开关。构建后运行 `node scripts/test-custom-tools-renderer.cjs`，验证可选工具行的实际编译回调、开关计数、批量操作及忙碌/归档/保存错误时的禁用状态；两项已纳入 `test.ps1`。

`node scripts/test-thread-list-renderer.cjs` 使用编译后的回调与稳定分组节点，验证会话改名、删除、归档、恢复、置顶/取消置顶的排序与菜单、新建及项目改名后的即时刷新和计数，也验证从搜索、归档页面创建项目后显示新分组；只执行读取了变化状态的更新回调，防止分组闭包保留旧数组。

`node scripts/test-i18n-native.cjs` 验证语言偏好与持久化；`node scripts/test-chat-disclosures.cjs` 验证流式更新、过程重开、消息隔离和历史加载时的展开状态。`node scripts/test-tool-details.cjs` 验证分类回执、失败状态与无损分页；构建后运行 `node scripts/test-team-renderer.cjs`，检查 DevEco 实际生成的 Team、工具详情及编排子调用更新回调。`node scripts/test-message-actions-renderer.cjs` 验证改写、重新生成、分支按钮在会话结束后恢复可用，再次忙碌或保存出错时禁用；复制保持可用。

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
