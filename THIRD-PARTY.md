# 许可范围与第三方来源

## 0. 先读：本仓库的许可范围

[`LICENSE`](LICENSE) 里的 **MIT 只覆盖本项目作者编写的部分**：

- `src/`（Android 外壳的 Java 代码）
- `build.sh`、`tools/`（打包与校验脚本）
- `res/` 中由本项目编写的资源（如 `res/values/*.xml`、`res/mipmap-anydpi-v26/*.xml`）

**不在 MIT 授权范围内的部分**（版权归各自原作者，本项目无权以此授权）：

- `res/mipmap-*/ic_launcher*.png` —— 应用图标，提取自 DeepWrite 官方原版 APK（见第 2 节）
- `assets/web/` —— DeepWrite 渲染层，Apache-2.0（见第 1 节）；构建时从上游收进来，
  不随本仓库分发

> 为什么把范围说明放在这里而不是 `LICENSE` 里：`LICENSE` 必须是**规范原文**，
> GitHub 才能识别出仓库的许可类型；加了自己的说明就会被判成 `NOASSERTION`。

---

## 1. DeepWrite 渲染层（应用本体）

| 项 | 内容 |
| --- | --- |
| 来源 | 上游 [swjybky/deepwrite](https://github.com/swjybky/deepwrite) |
| 版本 | 1.5.0 |
| 许可 | **Apache License 2.0** —— 全文见 [`LICENSE-APACHE-2.0.txt`](LICENSE-APACHE-2.0.txt) |
| 版权 | 归 DeepWrite 原作者所有 |

- **不在本仓库里**：渲染层的源码与构建产物都不随本仓库分发。`build.sh` 需要先在上游工作区
  构建出 `apps/desktop/out-web`，再由 `tools/fetch-runtime.sh` 收进 `assets/web/`
  —— 所以本仓库的 CI 构建不出这个 APK（见 README「构建」）。
- **再分发时的义务**（Apache-2.0 第 4 条）：随 APK 一并提供许可证副本、保留版权声明。
  本仓库已附 `LICENSE-APACHE-2.0.txt`，Release 说明里也指向它。
- 上游**没有 `NOTICE` 文件**，故第 4(d) 条不适用。
- ⚠️ 第 4(b) 条要求声明修改：**我们改动过渲染层** —— 手机端布局从注入式补丁搬进渲染层、
  输入框卡片「书籍」半边可点切书、朱雀检测在手机端改走系统浏览器等。
  完整改动清单见 [133563825as-ai/deepwrite-ui](https://github.com/133563825as-ai/deepwrite-ui)
  的 `MOBILE-UI-WORK.md`。

## 2. 应用图标

| 项 | 内容 |
| --- | --- |
| 位置 | `res/mipmap-*/ic_launcher*.png`（hdpi ~ xxxhdpi 五套密度） |
| 来源 | 提取自 DeepWrite **官方原版 APK**（`DeepWrite 1.1.3`）；混淆名 → 资源名的映射见 `tools/import-official-icon.sh` |
| 版权 | 归 DeepWrite 原作者所有 |
| 许可状态 | ⚠️ **不在本仓库 MIT 许可的授权范围内**。项目作者已与原作者确认允许二次修改与分发；如原作者另有要求，以其要求为准 |

## 3. Node 运行时（Termux aarch64）

| 项 | 内容 |
| --- | --- |
| 来源 | Termux 官方仓库的 aarch64 包（`nodejs 26.4.0-1`，下载地址见 `tools/fetch-runtime.sh`） |
| 位置 | `lib/arm64-v8a/libnode.so`（改名以获得 `lib/` 下的执行权限）+ `assets/runtime/lib/` |
| Node.js 本体许可 | MIT |
| 附带原生库 | 18 个：`libc++_shared`、`libcrypto` / `libssl`（OpenSSL 3）、`libicudata` / `libicui18n` / `libicuio` / `libicutest` / `libicutu` / `libicuuc`（ICU 78）、`libsqlite3`、`libz`、`libcares`、`libffi`、`libandroid-support`，以及 OpenSSL 的 `capi` / `legacy` / `loader_attic` 模块等 |
| 各库许可 | 以各上游项目为准（常见情况：OpenSSL = Apache-2.0、ICU = Unicode 许可、zlib = zlib 许可、libc++ = Apache-2.0 with LLVM exception、SQLite = 公有领域、c-ares 与 libffi = MIT）。需要完整许可文本时请向对应上游获取 |

## 4. 打包进 APK 的 JS 依赖

`assets/web/node_modules/` 下的 JavaScript 依赖（pi-ai、pi-agent-core、zod、typebox、
`@anthropic-ai/sdk`、`@aws-sdk/*` 等）**各自带着自己的许可文件，随 APK 一并分发** ——
当前构建里有 **88 个**许可类文件。依赖清单与来源见 `tools/copy-runtime-deps.mjs`
与上游的 `pnpm-lock.yaml`。

---

## 5. 本仓库自己写的那部分

见第 0 节。
