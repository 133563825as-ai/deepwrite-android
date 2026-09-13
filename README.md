# DeepWrite 手机壳

DeepWrite 桌面版（Electron）在本机跑起来之后，这个 Android 壳把它显示成全屏应用。

壳本身**不含**业务代码：它是一个 WebView，加载 `http://127.0.0.1:8790/`，
也就是容器里那个 DeepWrite Web 服务。服务没起时显示引导页，点一下重试即可。

## 构建

本地（Android 上的 Ubuntu 容器）和 GitHub Actions 共用 `build.sh`：

```bash
bash build.sh
# SDK 不在默认路径时：
ANDROID_SDK_ROOT=/path/to/sdk bash build.sh
```

产物：`out/DeepWrite-mobile.apk`。

CI 在 `.github/workflows/build-apk.yml`，推 `main` 或手动触发都会构建并上传 artifact。

### 关于签名

- 没有 `deepwrite.keystore` 时，脚本会生成一个**临时**密钥：能装，但换一台机器构建出来的
  签名不同，装第二次会提示「应用未安装」。要覆盖升级就得用同一个 keystore。
- 想让 CI 用固定签名，把 keystore 转成 base64 存进仓库 secret `KEYSTORE_BASE64`
  （口令存 `KEYSTORE_PASS`）。**keystore 绝不能直接提交进仓库。**

### 为什么不用 aapt2

容器里没有 arm64 的 aapt2（官方只发 x86_64），所以 manifest 用 `tools/make_manifest.py`
自己生成 AXML。它只引用系统资源，不需要 `resources.arsc`，因此整个构建不需要资源编译步骤。
自研 AXML 生成器的字段偏移必须拿官方 aapt2 产物对照验证 —— 历史上有过「自己校验自己，
一直是绿的但其实写错了」的教训。

## 文件选择

页面里的 `<input type="file">` 依赖 `WebChromeClient.onShowFileChooser`。
没有它，点击完全没反应（不报错、不弹窗）——「手机上不能上传文件」多半就是这个原因。
实现在 `MainActivity.openFileChooser`。

注意 `webkitdirectory`（选文件夹）在 Android WebView 里没有实现，所以页面另外留了
「直接填容器内路径」的退路。

## 目录

```
src/ai/deepwrite/mobile/MainActivity.java   WebView 壳 + 文件选择
tools/make_manifest.py                      AXML manifest 生成器
tools/android_resource.py                   最小 AXML / resources.arsc 工具
build.sh                                    构建脚本（可移植）
```
