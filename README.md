# DeepWrite 独立版（Android）

一个**自带 Node 运行时**的 DeepWrite Android 应用：APK 里装着 Node 与应用本体，
点开图标就自己起服务、自己加载界面，**不依赖任何外部容器或服务**。

## 为什么不用 WebView 壳

早期版本是个 16 KB 的壳，只负责打开一个窗口指向容器里的 Web 服务 ——
容器一停它就白屏，也没法分发给别人。独立版把运行时一起打进去，解掉这个依赖。

## 它是怎么跑起来的

```
APK
├─ lib/arm64-v8a/libnode.so     Termux 的 Node 26.4.0（动态链接器是 /system/bin/linker64，
│                               所以普通 App 能 exec 它；改名是为了拿到 lib/ 的执行权限）
├─ assets/runtime/lib/          libc++ / ICU / OpenSSL 等 18 个依赖库
├─ assets/web/                  DeepWrite 本体 + node_modules
└─ assets/manifest.json         解压清单（3642 个文件，约 115 MB）

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

`fetch-runtime.sh` 从 Termux 源下载 arm64 的 Node 与依赖并组织成 APK 形状；
`build.sh` 编译 Java、转 dex、把 `lib/` 与 `assets/` 一并打包并签名。

⚠️ `build.sh` **不能清空整个 `build/`** —— 里面的 `apk/` 是资产目录。

### 关于签名

没有 `deepwrite.keystore` 时会生成**临时**密钥：能装，但换台机器构建的签名不同，
装第二次会提示「应用未安装」。要覆盖升级就得固定 keystore。

CI 里配 `KEYSTORE_BASE64`（+ `KEYSTORE_PASS`）即可用固定签名。
**keystore 绝不能提交进仓库。**

### 为什么不用 aapt2

容器里没有 arm64 的 aapt2（官方只发 x86_64），所以 manifest 由
`tools/make_manifest.py` 手写二进制 AXML。代价是**没有 resources.arsc**：

- 图标只能用系统默认的（`res/` 里的图标目前没被引用）
- 系统读不出应用占用空间

要补齐这两项，需要把构建挪到有完整 Android SDK 的机器上（如 GitHub Actions），
用官方 `aapt2` 编译资源。

## 调试

没有 adb、也没有无障碍权限，所以**启动失败的日志会直接显示在 App 屏幕上**
（node 的 stdout/stderr 尾巴）。这是目前唯一可靠的排错通道。

日志文件本身在 `/data/data/ai.deepwrite.mobile/files/logs/node.log`。

## 数据在哪

| 用途 | 路径 |
| --- | --- |
| 作品（用户可见） | `/sdcard/Documents/DeepWrite` |
| 配置 / 密钥 | `/data/data/ai.deepwrite.mobile/files/data` |

因为要按真实路径读写作品，需要 `MANAGE_EXTERNAL_STORAGE`（所有文件访问）。

## 目录

```
src/ai/deepwrite/mobile/    MainActivity / RuntimeInstaller / NodeRunner
tools/fetch-runtime.sh      运行时资产准备
tools/make_manifest.py      手写 AXML manifest
tools/android_resource.py   最小 AXML / resources.arsc 工具
build.sh                    构建与签名
```
