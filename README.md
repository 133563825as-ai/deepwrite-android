# DeepWrite Android

自带 Node 运行时的 DeepWrite Android 客户端。APK 里装着运行时与应用本体，
装到手机上就能用，**不依赖任何外部服务**。

> ⚠️ **这不是 DeepWrite 官方发布。**
> 渲染层取自 DeepWrite **官方原版 1.5.0**（上游 [swjybky/deepwrite](https://github.com/swjybky/deepwrite)，Apache-2.0），
> 应用图标提取自官方原版 APK。DeepWrite 的版权归其官方原作者所有。

## 下载

到 [Releases](https://github.com/133563825as-ai/deepwrite-android/releases/latest) 下
`DeepWrite-Android-*.apk`。最新版见页面上的 `Latest` 标记。

## 装之前先看这 5 条（都是硬门槛）

| # | 条件 | 说明 |
| --- | --- | --- |
| 1 | **必须是 arm64 手机** | APK 里只有 `lib/arm64-v8a/`，x86 模拟器与 32 位机器**装不上** |
| 2 | Android 7.0 及以上 | `minSdk 24` |
| 3 | 允许「安装未知应用」 | 自签名包、非应用商店渠道，Play Protect 可能弹提示 |
| 4 | **手动授予「所有文件访问」** | Android 11+ 不能在弹窗里给：设置 → 应用 → 特殊应用权限 → 所有文件访问。**不授权，作品落不到 `/sdcard/Download/DeepWrite`** |
| 5 | **自己准备模型 API key** | 密钥不随包分发，装上后在应用里填。不配就跑不了智能体 |

首次启动要解压约 5,700 个文件 / 约 103 MB，会明显卡一下，之后正常。
APK 约 50 MB，装完占空间 200 MB 上下。

## 功能

功能来自 DeepWrite 官方原版 1.5.0，手机端在其上做了界面重排。主要几条：

- **写作工作台**：作品、阶段、人设、剧情结构，短篇与长篇
- **智能体对话**：接自己的模型 Provider（DeepSeek / OpenAI / Anthropic 等），
  也可以配置自定义服务
- 输入框上方那张卡片可以直接**切换作品**与**切换阶段**
- **「朱雀检测」交给系统浏览器打开**
- 手机端界面按手机重排（顶栏 / 抽屉 / 单栏）

## 数据放在哪

| 用途 | 路径 |
| --- | --- |
| 作品（文件管理器可见可改） | `/sdcard/Download/DeepWrite` |
| 配置 / 密钥 | 应用私有目录（卸载会一起清掉） |

作品放公共存储是为了文件管理器能直接看、直接改。代价是需要「所有文件访问」权限，
因此**无法上架 Google Play**，只能这样侧载。

## 已知问题

- 「朱雀检测」跳系统浏览器这一步**没有在真机上验证过**
- 小窗（最近任务）图标在部分定制 ROM 上可能显示系统默认图标
- 导出 / 分享到文件的功能未真机验证
- 应用图标来自官方原版 APK，**版权归原作者**（已获原作者同意二次修改与分发）

## 来源与许可

| 部分 | 来源 | 许可 |
| --- | --- | --- |
| 渲染层（应用本体） | DeepWrite 官方原版 1.5.0 · [swjybky/deepwrite](https://github.com/swjybky/deepwrite) | Apache-2.0 |
| 应用图标 | 提取自官方原版 APK（`DeepWrite 1.1.3`） | 版权归原作者 |
| Node 运行时 | Termux 官方仓库 aarch64 Node 26.4.0 + 18 个依赖库 | 见各上游项目 |
| Android 外壳（本仓库） | 本项目 | MIT |

逐项归属与再分发义务见 [`THIRD-PARTY.md`](THIRD-PARTY.md)；
许可证全文见 [`LICENSE`](LICENSE)（MIT）与
[`LICENSE-APACHE-2.0.txt`](LICENSE-APACHE-2.0.txt)（上游渲染层）。
这两份也随 APK 一起分发，在包内 `assets/web/` 下。

---

本仓库只放 **Android 外壳**与打包定义，**不含 DeepWrite 本体源码**。
