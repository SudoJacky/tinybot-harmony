# 词条与本地化

界面文案、错误提示和设置说明都来自两张双语 JSON，运行时同步查表，不发起网络请求。这一页说明词条文件的结构、占位符规则、生成脚本做了什么，以及新增一条文案要改哪些地方。日常维护流程见[词条维护](/dev/i18n)。

## 文件与职责

| 路径 | 职责 |
| --- | --- |
| `locales/zh-CN.json` | 简体中文词条，同时是消息 ID 的来源 |
| `locales/en.json` | 英文词条，键必须与中文表完全一致 |
| `scripts/build-locales.cjs` | 校验两张表并生成 `LocaleCatalog.ets` |
| `entry/src/main/ets/model/LocaleCatalog.ets` | 生成产物，导出 `ZH_MESSAGES` 与 `EN_MESSAGES` |
| `entry/src/main/ets/model/I18n.ets` | `t()` 查表、语言解析与参数替换 |

两张 JSON 都是扁平的“键到字符串”映射，没有嵌套对象，也不带注释。键就是中文原文（gettext 风格），所以改英文译文不会影响调用点，也不会让代码里的 `t('…')` 失效。

`locales/zh-CN.json`：

```json
{ "全部关闭": "全部关闭", "展开全部 {0} 行": "展开全部 {0} 行" }
```

`locales/en.json`：

```json
{ "全部关闭": "Disable all", "展开全部 {0} 行": "Expand all {0} lines" }
```

当前两张表各 2062 条，其中 129 条含编号占位符。

## 双语 JSON 规则

- 一个键在两张表里都必须存在，且值必须是字符串；缺键、多键或非字符串都会让生成脚本失败。
- 中文表的值通常与键相同，因为键就是中文原文；这不是冗余，删掉值就无法生成中文查表。
- 源文件的顺序不要求排序，生成脚本按键排序后写入 `LocaleCatalog.ets`，因此生成文件的差异只反映内容变化。
- 消息可以包含换行，例如多段提示语；值里的 `\n` 是转义后的换行，不是两个字符。
- 只收录应用自有文案。用户消息、模型回答、自定义提示词、文件名、已保存内容都不进词条表。

## 占位符

```ts
import { t } from '../model/I18n';

t('保存');
t('{0} 行', [lineCount]);
t('已开启 {0} / {1} 项能力', [enabled, total]);
```

- 使用带编号的整句，`{0}`、`{1}` 在两种语言里必须完全一致；译者可以调整顺序，但不能增删或改名。
- 传数组参数，不要把数字或名称拼进消息 ID：`t('{0} 行', [n])`，而不是 `t(n + ' 行')`。
- 替换由回调完成，参数里的 `$&`、花括号等字符按字面保留；值缺失时保留原占位符，不会输出 `undefined`。
- `{{input}}` 属于提示词模板占位，按字面保留，不参与编号占位符检查；当前有 3 条词条包含它。
- 查表顺序是当前语言 → 中文表 → 原始消息 ID，因此漏译不会显示空白。

## 复数与语序

代码里没有复数规则或 ICU 消息语法：一条消息就是一个完整句子，数字通过 `{0}` 传入。需要区分单复数时，写法是换一句完整表述，而不是在词条里写 `one/few/other` 分支。语序差异通过调整 `{0}`、`{1}` 在句中的位置解决，这也是占位符必须使用编号的原因。

## 生成脚本

```powershell
node scripts/build-locales.cjs
node scripts/build-locales.cjs --check
node scripts/test-i18n-native.cjs
```

`build-locales.cjs` 依次做四件事：

1. 读取两张 JSON，比较排序后的键集合，不一致直接报 `Locale keys differ`。
2. 检查每个值都是字符串，否则报 `Invalid locale value`。
3. 比较每条消息里 `{n}` 占位符的排序集合，不一致报 `Placeholder mismatch`。
4. 扫描 `entry/src/main/ets` 下除生成文件外的所有 `.ets`，提取字面量 `t('…')` 的键；表里没有就报 `Missing message in <file>`。

通过后把两张表按键排序写入 `entry/src/main/ets/model/LocaleCatalog.ets`，并打印校验的条数。加 `--check` 时只比较生成内容与现有文件（忽略 CRLF 差异），过期则报 `Generated catalog is stale`；这一项已纳入 `scripts/test.ps1`。生成文件不要手改，下次生成会覆盖。

## 新增词条步骤

1. 在调用点写完整的 `t('中文原文')`，确保是字符串字面量；拼接变量或先算字符串都会绕过脚本检查。
2. 在 `locales/zh-CN.json` 增加同名键，值写中文文案。
3. 在 `locales/en.json` 增加同一个键，值写英文译文，占位符编号与中文保持一致。
4. 运行 `node scripts/build-locales.cjs` 生成同步目录。
5. 运行 `node scripts/build-locales.cjs --check` 与 `node scripts/test-i18n-native.cjs` 验证。
6. 在英文界面检查换行与截断，较长译文可能撑破按钮或列表行。

删除词条时顺序相反：先确认没有代码引用，再同时从两张表删除，最后重新生成。

## 检查规则

| 规则 | 由谁保证 | 失败表现 |
| --- | --- | --- |
| 两张表键集合一致 | 生成脚本 | `Locale keys differ` |
| 值都是字符串 | 生成脚本 | `Invalid locale value` |
| 占位符集合一致 | 生成脚本 | `Placeholder mismatch` |
| 代码里的字面量键都存在 | 生成脚本 | `Missing message in <file>` |
| 生成文件与源表同步 | `--check` 与 `test.ps1` | `Generated catalog is stale` |
| 语言回退、参数替换、特殊字符、持久化与保存失败回滚 | `test-i18n-native.cjs` | 测试失败 |

脚本只识别字面量调用。`t(variable)` 这类动态键不会被校验，也没有运行时补录机制，应避免在业务代码里使用。

## 运行时行为

- 语言偏好取值为 `system`、`zh-CN`、`en`，默认 `system`，保存在 `tinybot-ui` Preferences 的 `language` 键。
- `system` 取系统语言：以 `zh` 开头的变体归为简体中文，其余一律英文。
- 解析结果写入 `AppStorage` 的 `tinybot.language` 与 `tinybot.locale`，界面据此重建；模块级标签集合必须是惰性函数，否则会冻结启动时的语言。
- 启动时先初始化语言再创建首屏；配置变化和前台进入时刷新。
- 切换语言只影响界面文案，不重写模型请求、用户消息或已保存内容；已保存的历史错误与工具记录保持原语言，新错误使用当前语言。
- 自动生成的会话标题按当前语言显示，手动改过的标题保持原文；系统选择器与 Ability 描述使用原生资源，跟随设备语言。

## 词条形态

| 场景 | 键（中文原文） | 英文值 | 要点 |
| --- | --- | --- | --- |
| 按钮 | 保存 | Save | 单词，保持动词原形 |
| 状态 | 执行中 | Running | 与工具状态标签共用同一条 |
| 计数 | {0} 行 | {0} lines | 数字与单位在同一句里 |
| 计数 | {0} 处匹配 | {0} matches | 英文按复数直接写死 |
| 组合 | 已开启 {0} / {1} 项能力 | {0} / {1} capabilities enabled | 两个占位符可换序 |

## 语言解析的边界

- 偏好值不是 `zh-CN` 或 `en` 时按 `system` 处理，包括旧版本写入的其他值。
- 系统语言先转小写、把 `_` 换成 `-`，再取第一段比较：`zh`、`zh-Hans`、`zh-Hant`、`zh-TW` 都落到简体中文，其余落到英文。
- 取不到系统语言时比较结果为空，最终同样落到英文。
- 解析结果只用于词条查表，不改变系统的语言、区域或日期格式。

## 常见失败与处理

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 新文案在英文界面仍显示中文 | 只改了调用点，没有补两张表，或没有重新生成目录 | 补键后运行生成脚本 |
| 英文界面出现中文原句 | 英文值为空或漏译，查表回退到中文 | 补齐 `en.json` 的值 |
| 数字没有替换 | 传的是拼接后的字符串，或参数不是数组 | 改成 `t('… {0} …', [value])` |
| 构建报缺少消息 | 代码引用了新文案，表里没有同名键 | 按报错文件与键补词条 |
| `--check` 报生成文件过期 | 改了 JSON 但没重新生成，或手改了生成文件 | 重新运行生成脚本，不要手改 |
| 占位符数量不一致 | 译文增删了 `{0}`、`{1}` | 保持编号集合完全一致 |

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `locales/zh-CN.json`、`locales/en.json` | 双语词条源文件 |
| `scripts/build-locales.cjs` | 校验与生成 |
| `entry/src/main/ets/model/I18n.ets` | `t()`、`resolveLocale`、`setLocale` |
| `entry/src/main/ets/model/LocaleCatalog.ets` | 生成的同步词条表 |
| `entry/src/main/ets/services/LanguagePreferences.ets` | 语言偏好持久化与应用 |
| `entry/src/main/ets/views/LanguagePanel.ets` | 语言选择界面 |
| `scripts/test-i18n-native.cjs` | 语言偏好与替换行为的原生测试 |
