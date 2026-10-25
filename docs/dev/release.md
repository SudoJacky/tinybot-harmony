# 发布清单

这页把 `scripts/prepare-distribution.ps1` 的产物、正式签名与上传、平台资料和回归检查串成一条可执行路径。版本号与包名以 `AppScope/app.json5` 和各模块 `module.json5` 为准。

## 版本与产物

当前版本线：`1.0.6` / `versionCode=1000006`，包名 `com.sudojacky.tinybot`，设备类型 `phone`，最低与目标 HarmonyOS API 26，发布包仅 `arm64-v8a`（模拟器使用单独构建的调试包，不随正式包分发）。

运行准备脚本后生成独立目录与 ZIP：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare-distribution.ps1 -StudioRoot "C:\Program Files\Huawei\DevEco Studio"
```

| 产物 | 说明 |
| --- | --- |
| `packages/Tinybot-<版本>-<code>-release-UNSIGNED.app` | 待云签名的完整发布包 |
| `packages/...-release-UNSIGNED.hap` | 同一 APP 内的 entry 模块 |
| `symbols/app-symbol.zip` | ArkTS 符号表 |
| `symbols/native/arm64-v8a/` | 与发布包 Build ID 一致的未裁剪原生沙箱库 |
| `assets/tinybot-icon.png` | 工程使用的图标 |
| `screenshots/` | 本机已准备的商店截图，需单独核对版本 |
| `licenses/` | Apache-2.0 与随包第三方许可证 |
| `policies/` | 随包用户协议原文；隐私政策由华为托管 |
| `RELEASE-NOTES.txt`、`STORE-LISTING.txt`、`CLOUD-TEST.txt`、`RELEASE-GAPS.txt` | 版本文案与验证资料 |
| `package-info.json`、`SHA256SUMS.txt` | 从实际包读取的元数据、大小、原生 Build ID 与 SHA-256 |

脚本先做 ArkTS 检查，再构建 Release APP，验证版本、`app.debug=false`、包内容、arm64 沙箱库与符号 Build ID，最后产出目录和 ZIP。已有输出不覆盖；可用 `-OutputDirectory` 指定新目录。`-SkipBuild` 仅打包既有产物，仍校验结构与版本，但不能证明包含最新代码。

当前独立 ArkTS 检查器可能无法解析构建生成的 `BuildProfile` 模块；v1.0.5 的完整 Debug / Release 构建可正常解析。遇到该错误时保留错误记录，先用 `devecocli build --product default --build-mode release` 完成真实构建与包检查，再对本次产物使用 `prepare-distribution.ps1 -SkipBuild` 整理资料；不要复用旧版本产物或放宽隐私授权条件。此方式不代表独立检查器通过。

## 签名与上传

交付脚本生成 ZIP 后会自动将未签名 APP、`pack.info`、`pac.json` 和符号表同步到主工程的 `build/outputs/default/`。在 Git worktree 中运行时，通过 Git 公共目录定位主工程，不共用各 worktree 的构建缓存。

已有交付包时，双击主工程根目录 `prepare-upload.cmd`，或执行：

```powershell
.\prepare-upload.ps1
# 指定交付目录；也可用于同步独立 worktree 生成的交付包
.\prepare-upload.ps1 -DistributionDirectory "<交付目录>"
```

默认按交付资料中的 `preparedAt` 选择主工程 `artifacts/distribution/` 中当前版本的最新完整交付包。同步前核对主工程版本、包名、实际 APP/HAP 的 Release 标志和版本，以及 APP/符号表的 SHA-256；不匹配则报错，原检测目录不变。已有输出在替换前整体备份到 `artifacts/upload-backups/`；内容一致时跳过替换，保留已有签名与上传结果。该脚本只整理已有交付包，不触发重新编译或平台上传。

本地自动签名使用调试 Profile，**Release 编译不等于发布签名**；UNSIGNED 文件必须正式签名才能安装或发布。

1. 在 DevEco Studio 的 Build > Upload Product 中选择工程原始产物 `build\outputs\default\tinybot-harmony-default-unsigned.app`。
2. 关联现有包名 `com.sudojacky.tinybot`，核对版本号与 versionCode。
3. 使用对应发布证书或云管理签名，附带本版符号表。
4. 最终签名包的哈希会变化，以最终文件重新记录。

创建应用、申请证书、上传、云测试与审核结果都必须在平台完成，本地准备不包含这些结论。

### 发布 Profile 与 ACL

项目共享文件夹声明了 `ohos.permission.FILE_ACCESS_PERSIST`，保存和激活目录授权依赖该权限。发布前需确认 API 26 手机场景的开放范围，按平台要求获取授权后的发布 Profile。

最终签名后，对实际上传 APP 中的每个 HAP 检查嵌入的 Profile：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check-release-package.ps1 -HapPath "<最终签名的 entry.hap>" -RequireReleaseProfile
```

检查会验证 HAP 签名、包内 Profile 的签名完整性、发布类型、包名、有效期，以及本次平台明确要求的 `FILE_ACCESS_PERSIST` 授权，并拒绝 Profile 中未在包内声明的 ACL。SDK 的 `provisionEnable=true` 不能单独用于判定哪些权限必须进入 ACL。此检查不是所有权限的通用分类器，也不代表平台已授权、证书链在线状态或审核通过。未传 `-RequireReleaseProfile` 时仅检查包结构，不能视为可上架。不要用调试 Profile、旁边另存的 Profile 或手工改写的 `.p7b` 代替最终签名包内的材料。

## 平台资料

- 主体与联系方式、政策公开地址、备案与分类资料按平台当前字段填写。
- 商店截图必须来自本版，且不含密钥、私有地址或个人聊天。
- 审核需要完整 AI 体验时，在平台私有审核备注提供专用、限额且可撤销的服务配置；不要把凭据写进代码、交付包或截图。
- 隐私政策由华为托管及系统弹窗管理，用户协议保留本地阅读和独立同意流程。正式分发前核对平台托管版本与系统签署状态。

## 回归检查

1. 用相同签名从旧版覆盖升级，检查会话、模型配置、草稿、工作区与附件。
2. 在干净的独立环境检查全新安装与首次使用引导。
3. 检查长回答滚动、工具调用与审批、交互预览、沙箱限额恢复、云备份恢复。
4. 至少在一台 API 26 arm64 真机与一台模拟器上验证启动、首屏与退出。
5. 记录实际设备、构建类型与时间；历史截图和设备结果不能代替本版验证。

## 验证边界

- 模拟器与本地测试结果不代表 AGC 云测试、审核或真实设备验证通过。
- 华为云空间真实上传、同账号跨设备恢复、实际人声识别、外部 MCP OAuth 服务需要对应设备、账号或服务才能验证。
- JavaScript 沙箱是同进程 QuickJS 解释器隔离，通过已授权工具访问工作区，沿用权限与确认，不提供任意外部目录、Python 或 Shell。
- 删除会话保留工作区文件；附件和用量记录不会逐条即时回收；备份不导出模型与 MCP 凭据。

## 交付前清单

| 检查项 | 命令或位置 |
| --- | --- |
| ArkTS 无错误 | `devecocli check arkts` |
| 测试通过 | `scripts/test.ps1` |
| 词条同步 | `node scripts/build-locales.cjs --check` |
| 内置 Skill 最新 | `node scripts/build-builtin-skills.cjs --check` |
| 版本号与更新说明 | `AppScope/app.json5`、`docs/distribution/RELEASE-NOTES.txt` |
| Release 产物校验 | `node scripts/test-release-models.cjs` |
| 交付包生成 | `scripts/prepare-distribution.ps1` |
