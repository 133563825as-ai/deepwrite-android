# DeepWrite 独立版（Android）

一个**自带 Node 运行时**的 DeepWrite Android 应用：APK 里装着 Node 与应用本体，
点开图标就自己起服务、自己加载界面，**不依赖任何外部容器或服务**。

版本号**跟随上游 DeepWrite 的发布号**，不再用早期那套 2.x / 3.x 的自增号 ——
那套号把一个外壳版本炒到了 3.4.0，比它包着的本体（1.5.0）还大，看着像另一个产品。

当前版本以 **`AndroidManifest.xml`** 为准（`versionName` / `versionCode`），本文件不重复写，
免得每发一版就漂一次。

## 素材与内核来源（本仓库不是官方发布）

本仓库**不是** DeepWrite 的官方发布，只是个人自建的 **Android 外壳与运行时打包**。
里面用到的东西来自这些地方，版权归各自原作者：

| 组成 | 来源 |
| --- | --- |
| 渲染层（应用本体） | DeepWrite **官方原版 1.5.0**，上游 [swjybky/deepwrite](https://github.com/swjybky/deepwrite)（Apache-2.0） |
| 应用图标 | 从 DeepWrite **官方原版 APK（`DeepWrite 1.1.3`）** 中提取；混淆名 → 资源名的映射见 `tools/import-official-icon.sh` |
| Node 运行时 | Termux 官方仓库的 aarch64 **Node 26.4.0** 及其 18 个依赖库 |

本仓库只放**外壳**（Java）、**打包脚本**（`tools/`、`build.sh`）与**资源**，
**不含 DeepWrite 本体源码**；渲染层产物由上游仓库构建后收进 `assets/web/`。

## 为什么不用 WebView 壳

早期版本是个 16 KB 的壳，只负责打开一个窗口指向容器里的 Web 服务 ——
容器一停它就白屏，也没法分发给别人。独立版把运行时一起打进去，解掉这个依赖。

## 它是怎么跑起来的

```
APK
├─ lib/arm64-v8a/libnode.so     Termux 的 Node 26.4.0（动态链接器是 /system/bin/linker64，
│                               所以普通 App 能 exec 它；改名是为了拿到 lib/ 的执行权限）
├─ assets/runtime/lib/          libc++ / ICU / OpenSSL 等 18 个依赖库
├─ assets/runtime/cacert.pem    调 HTTPS 模型接口要用
├─ assets/web/                  DeepWrite 本体 + node_modules
└─ assets/manifest.json         解压清单（本次构建 5692 个文件 / 102.8 MB）

启动：解压资产 → exec libnode.so server.mjs → 等 127.0.0.1:18790 就绪 → WebView 加载
```

端口用 **18790** 而非 8790，是为了避开容器里那套 Web 服务（同一个 `127.0.0.1`）。

## 构建

```bash
# 1) 准备运行时资产（首次，之后有缓存）
RUNTIME_CACHE=./build/runtime-cache bash tools/fetch-runtime.sh

# 2) 构建 APK
bash build.sh

# 产物：out/DeepWrite-mobile.apk
```

`fetch-runtime.sh` 从 Termux 源下载 arm64 的 Node 与依赖、收进上游渲染层产物、
补齐依赖闭包并做构建期 utility 冒烟；`build.sh` 编译 Java、转 dex、
把 `lib/` 与 `assets/` 一并打包并签名。

⚠️ **必须先有上游渲染层产物**（`fetch-runtime.sh` 会从 DeepWrite 工作区的
`apps/desktop/out-web` 收资产）。本仓库自带不了这一步，所以**这里的 CI 构建不出 APK**，
只能在有上游工作区的机器上本地构建。

⚠️ `build.sh` **不能清空整个 `build/`** —— 里面的 `apk/` 是资产目录。

⚠️ 版本号只写在 **`AndroidManifest.xml`**（`versionCode` / `versionName`），别处不重复。
`versionCode` 必须**只增不减**，否则覆盖安装会被系统拒掉
（`INSTALL_FAILED_VERSION_DOWNGRADE`）。

### 关于签名

没有 `deepwrite.keystore` 时会生成**临时**密钥：能装，但换台机器构建的签名不同，
装第二次会提示「应用未安装」。要覆盖升级就得固定 keystore。

CI 里配 `KEYSTORE_BASE64`（+ `KEYSTORE_PASS`）即可用固定签名。
**keystore 绝不能提交进仓库。**

### 图标、resources.arsc 与 aapt2

早先的前提是「容器里没有 arm64 的 aapt2」，于是用 `tools/make_manifest.py` 手写二进制
AXML 绕开 aapt2。**那个前提是错的** —— apt 的 `aapt` 包顺带提供原生 aarch64 的
`aapt2` / `zipalign`（见 `build.sh` 的 `pick_tool`）。

手写那套的代价是拿不到 `resources.arsc`：**只能显示系统默认图标**，而且
系统读不出应用占用空间。现在清单是明文、资源走正规编译：

- `res/mipmap-*/` 是**从官方原版 APK 提取**的图标（可选 `import-official-icon.sh` 复现）
- `targetSdk` 提到 **36**（Android 16 强制 edge-to-edge，`MainActivity` 里补了 window insets）

## 调试

没有 adb、也没有无障碍权限，所以**启动失败的日志会直接显示在 App 屏幕上**
（node 的 stdout/stderr 尾巴）。这是目前唯一可靠的排错手段。

日志文件本身在 `/data/data/ai.deepwrite.mobile/files/logs/node.log`。

容器与手机**共享 loopback**，所以手机上的 App 跑起来之后，可以直接从容器读它：

```bash
curl -s http://127.0.0.1:18790/__status     # 主进程是否加载成功
curl -s http://127.0.0.1:18790/__diag       # 三个 utility 的 fork / stderr
```

## 数据在哪

| 用途 | 路径 |
| --- | --- |
| 作品（用户可见） | `/sdcard/Documents/DeepWrite` |
| 配置 / 密钥 | `/data/data/ai.deepwrite.mobile/files/data` |
| 运行时 / 应用（解压出来） | `/data/data/ai.deepwrite.mobile/files/{runtime,web}` |

因为要按真实路径读写作品，需要 `MANAGE_EXTERNAL_STORAGE`（所有文件访问）。
自用没问题，上架 Google Play 会被拒。

## 目录

```
src/ai/deepwrite/mobile/    MainActivity / RuntimeInstaller / NodeRunner
res/                        图标与主题（图标取自官方原版 APK）
tools/fetch-runtime.sh      运行时资产准备（含依赖闭包与 utility 冒烟）
tools/copy-runtime-deps.mjs 依赖闭包 BFS（绕开 exports，只按 node_modules 规则找包）
tools/verify-utilities.mjs  构建期冒烟：三个 utility 能否在无向上逃逸的条件下加载
tools/import-official-icon.sh  从官方原版 APK 提取图标并记录名映射
tools/android_resource.py   最小 AXML / resources.arsc 工具（历史遗留）
tools/make_manifest.py      手写 AXML manifest（历史遗留，已被 aapt2 取代）
build.sh                    构建与签名
```
