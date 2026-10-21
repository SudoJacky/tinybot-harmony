# 发布清单

这页把 `scripts/prepare-distribution.ps1` 的产物、正式签名与上传、平台资料和回归检查串成一条可执行路径。版本号与包名以 `AppScope/app.json5` 和各模块 `module.json5` 为准。

## 版本与产物

当前版本线：`1.0.3` / `versionCode=1000003`，包名 `com.sudojacky.tinybot`，设备类型 `phone`，最低与目标 HarmonyOS API 26，发布包仅 `arm64-v8a`（模拟器使用单独构建的调试包，不随正式包分发）。

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
| `policies/` | 应用实际使用的隐私政策与用户协议原文 |
| `RELEASE-NOTES.txt`、`STORE-LISTING.txt`、`CLOUD-TEST.txt`、`RELEASE-GAPS.txt` | 版本文案与验证资料 |
| `package-info.json`、`SHA256SUMS.txt` | 从实际包读取的元数据、大小、原生 Build ID 与 SHA-256 |

脚本先做 ArkTS 检查，再构建 Release APP，验证版本、`app.debug=false`、包内容、arm64 沙箱库与符号 Build ID，最后产出目录和 ZIP。已有输出不覆盖；可用 `-OutputDirectory` 指定新目录。`-SkipBuild` 仅打包既有产物，仍校验结构与版本，但不能证明包含最新代码。

## 签名与上传

本地自动签名使用调试 Profile，**Release 编译不等于发布签名**；UNSIGNED 文件必须正式签名才能安装或发布。

1. 在 DevEco Studio 的 Build > Upload Product 中选择工程原始产物 `build\outputs\default\tinybot-harmony-default-unsigned.app`。
2. 关联现有包名 `com.sudojacky.tinybot`，核对版本号与 versionCode。
3. 使用对应发布证书或云管理签名，附带本版符号表。
4. 最终签名包的哈希会变化，以最终文件重新记录。

创建应用、申请证书、上传、云测试与审核结果都必须在平台完成，本地准备不包含这些结论。

## 平台资料

- 主体与联系方式、政策公开地址、备案与分类资料按平台当前字段填写。
- 商店截图必须来自本版，且不含密钥、私有地址或个人聊天。
- 审核需要完整 AI 体验时，在平台私有审核备注提供专用、限额且可撤销的服务配置；不要把凭据写进代码、交付包或截图。
- 应用内已接入用户协议、隐私政策的完整离线阅读与首次使用协议流程，公开地址仍需在平台补充。

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
