#!/bin/bash
# 准备「独立运行」所需的全部运行时资产。
#
# 干什么：
#   1. 从 Termux 源下载 arm64 的 Node 与它的依赖库（bionic 链接，可直接在 Android 上 exec）
#   2. 组织成 APK 需要的形状：node 进 lib/（可执行），其余库进 assets/（首次启动解压）
#
# 为什么用 Termux 的二进制：Node 官方不发 Android 构建；容器里那个 node 链的是 glibc，
# Android 上没有。Termux 的构建 PT_INTERP 是 /system/bin/linker64，普通 App 可以 exec。
#
# 用法：
#   bash fetch-runtime.sh
#   WEB_OUT=/path/to/out-web bash fetch-runtime.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${RUNTIME_CACHE:-$ROOT/build/runtime-cache}"
EXTRACT="${RUNTIME_EXTRACT:-$ROOT/build/runtime-extract}"
APKROOT="${APK_ROOT:-$ROOT/build/apk}"
WEB_OUT="${WEB_OUT:-/root/wk/deepwrite/apps/desktop/out-web}"

BASE=https://packages.termux.dev/apt/termux-main

# node 的运行期依赖（Termux 的 Depends 字段给出的闭包）
PACKAGES=(
  "pool/main/n/nodejs/nodejs_26.4.0-1_aarch64.deb"
  "pool/main/libc/libc++/libc++_29_aarch64.deb"
  "pool/main/o/openssl/openssl_1:3.6.3_aarch64.deb"
  "pool/main/c/c-ares/c-ares_1.34.8_aarch64.deb"
  "pool/main/libi/libicu/libicu_78.3_aarch64.deb"
  "pool/main/libs/libsqlite/libsqlite_3.53.4_aarch64.deb"
  "pool/main/z/zlib/zlib_1.3.2_aarch64.deb"
  "pool/main/libf/libffi/libffi_3.8.0_aarch64.deb"
  "pool/main/liba/libandroid-support/libandroid-support_29-1_aarch64.deb"
  "pool/main/c/ca-certificates/ca-certificates_1:2026.08.13_all.deb"
)

echo "① 下载运行时包（有缓存就跳过）"
mkdir -p "$CACHE"
for entry in "${PACKAGES[@]}"; do
  name="$(basename "$entry")"
  if [ -s "$CACHE/$name" ]; then
    echo "   已有 $name"
    continue
  fi
  echo "   下载 $name"
  curl -fsS --max-time 300 -o "$CACHE/$name" "$BASE/$entry"
done
echo "   共 $(du -sh "$CACHE" | cut -f1)"

echo "② 解包"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
for deb in "$CACHE"/*.deb; do
  target="$EXTRACT/$(basename "$deb" .deb)"
  mkdir -p "$target"
  dpkg-deb -x "$deb" "$target"
done

PREFIXDIR="$EXTRACT/nodejs_26.4.0-1_aarch64/data/data/com.termux/files/usr"

echo "③ 组织 APK 目录"
rm -rf "$APKROOT"
mkdir -p "$APKROOT/lib/arm64-v8a" "$APKROOT/assets/runtime/lib" "$APKROOT/assets/web"

# node 本体：必须放在 lib/<abi>/ 下才有执行权限（Android 10+ 禁止 exec 可写目录）
cp "$PREFIXDIR/bin/node" "$APKROOT/lib/arm64-v8a/libnode.so"
chmod 755 "$APKROOT/lib/arm64-v8a/libnode.so"
echo "   libnode.so $(du -h "$APKROOT/lib/arm64-v8a/libnode.so" | cut -f1)"

# 依赖库：真实文件进 assets，符号链接关系单独记成 links.json
find "$EXTRACT" -name "*.so*" -type f -exec cp -n {} "$APKROOT/assets/runtime/lib/" \;
python3 - "$EXTRACT" "$APKROOT" <<'PY'
import json, os, sys
extract, apkroot = sys.argv[1], sys.argv[2]
links = {}
for dirpath, _dirs, files in os.walk(extract):
    for name in files:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            target = os.path.basename(os.readlink(path))
            links[name] = target
libdir = os.path.join(apkroot, "assets/runtime/lib")
present = set(os.listdir(libdir))
# 只保留「链接目标也在包里」的那些链接
links = {k: v for k, v in links.items() if v in present}
json.dump(links, open(os.path.join(apkroot, "assets/runtime/links.json"), "w"),
          indent=2, sort_keys=True)
print(f"   库文件 {len(present)} 个，符号链接 {len(links)} 条")
PY

# CA 证书：Node 调 HTTPS 接口要用
CERT="$(find "$EXTRACT/ca-certificates"* -name "cert.pem" | head -1)"
[ -n "$CERT" ] && cp "$CERT" "$APKROOT/assets/runtime/cacert.pem" && \
  echo "   cacert.pem $(du -h "$APKROOT/assets/runtime/cacert.pem" | cut -f1)"

echo "④ 收进 Web 产物（$WEB_OUT）"
[ -d "$WEB_OUT/renderer" ] || { echo "❌ 找不到 $WEB_OUT/renderer，先构建 Web 产物"; exit 1; }
# ⚠️ 必须排除 *.apk：renderer/ 目录同时被 8790 当作 APK 的分发目录（放着一份
# DeepWrite-Android.apk 供手机下载）。不排除就会把上一版 APK 整份打进新 APK ——
# 实测能给包里塞进 37MB 的死重量，装到手机上还会白占空间。
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude='*.apk' "$WEB_OUT/renderer" "$APKROOT/assets/web/"
else
  mkdir -p "$APKROOT/assets/web/renderer"
  (cd "$WEB_OUT/renderer" && find . -type f ! -name '*.apk' -exec cp --parents {} "$APKROOT/assets/web/renderer/" \;)
fi
cp -r "$WEB_OUT/main" "$APKROOT/assets/web/main"
cp "$WEB_OUT/server.mjs" "$APKROOT/assets/web/server.mjs"
cp "$WEB_OUT/server-workspace.mjs" "$APKROOT/assets/web/server-workspace.mjs"
cp "$WEB_OUT/server-dialog.mjs" "$APKROOT/assets/web/server-dialog.mjs"
cp "$WEB_OUT/api-commands.json" "$APKROOT/assets/web/api-commands.json"
[ -f "$WEB_OUT/package.json" ] && cp "$WEB_OUT/package.json" "$APKROOT/assets/web/package.json"

# 许可与归属：assets/web/ 是上游 DeepWrite 的渲染层（Apache-2.0），再分发必须
# 随附许可证副本（第 4(a) 条）并声明修改（第 4(b) 条），所以两份都放进包里 ——
# 只放在仓库里的话，单独下载 APK 的人拿不到。
# ⚠️ 必须写在这一步：$APKROOT 每轮开头被 rm -rf 重建，写在 build.sh 里会被冲掉。
# ⚠️ Apache-2.0 正文必须**原样**复制，一个字都不能改。
cp "$ROOT/LICENSE-APACHE-2.0.txt" "$APKROOT/assets/web/LICENSE-APACHE-2.0.txt"
# 归属说明加一行抬头，因为里面的仓库相对路径在包内不解析。
{
  printf '<!-- 本文件随 APK 分发（位于 assets/web/ 下），是仓库根 THIRD-PARTY.md 的副本。\n'
  printf '     文中指向 tools/ 等仓库路径的引用在包内不解析，完整仓库：\n'
  printf '     https://github.com/133563825as-ai/deepwrite-android -->\n\n'
  cat "$ROOT/THIRD-PARTY.md"
} > "$APKROOT/assets/web/THIRD-PARTY.md"
echo "   已随包附上 LICENSE-APACHE-2.0.txt 与 THIRD-PARTY.md"
# Electron 兼容层与桥：server.mjs 里 import "electron"，用软链目录顶替
mkdir -p "$APKROOT/assets/web/node_modules/electron"
cp "$WEB_OUT/node_modules/electron/index.js" "$APKROOT/assets/web/node_modules/electron/index.js" 2>/dev/null || \
  cp /root/wk/dwbuild/runtime/electron-shim.js "$APKROOT/assets/web/node_modules/electron/index.js"
cp "$WEB_OUT/node_modules/electron/package.json" "$APKROOT/assets/web/node_modules/electron/package.json" 2>/dev/null || \
  printf '{"name":"electron","version":"0.0.0-web","main":"index.js"}\n' > "$APKROOT/assets/web/node_modules/electron/package.json"
cp "$WEB_OUT/node_modules/electron/utility-parent-port.cjs" "$APKROOT/assets/web/node_modules/electron/utility-parent-port.cjs" 2>/dev/null || true

# 运行期依赖（electron-updater / typebox / zod / @earendil-works …）
# ⚠️ 必须 -L 跟随软链：out-web 里这些是 pnpm 的软链，手机上没有那个路径，
# 直接复制软链只会得到一堆断链 —— 上一版正是因此漏掉了 electron-updater，
# 主进程一上来就 Cannot find module。
for entry in "$WEB_OUT/node_modules"/*; do
  [ -e "$entry" ] || continue
  name="$(basename "$entry")"
  [ "$name" = "electron" ] && continue   # electron 由上面的兼容层顶替
  cp -rL "$entry" "$APKROOT/assets/web/node_modules/$name"
done
echo "   node_modules: $(ls "$APKROOT/assets/web/node_modules" | tr '\n' ' ')"

# ⚠️ 上面那份是「手工清单」，只挑了直接依赖。pi-ai / pi-agent-core 自己声明的依赖
# （partial-json、http-proxy-agent…）不在清单里 —— 容器里跑得通，是因为 node 会沿目录
# 向上找到仓库根的 node_modules，**手机上根本没有那一层**，于是 agent utility 一 fork
# 就 ERR_MODULE_NOT_FOUND、退出码 1，前端只看到 utility.not_running。
# 这里按声明的 dependencies 递归补齐闭包（从仓库根的 node_modules 解析，-L 跟随软链）。
echo "④a 补齐依赖闭包"
node "$ROOT/tools/copy-runtime-deps.mjs" "$APKROOT" "$WEB_OUT"

# ⚠️ 光补齐还不够，必须**证明**它补齐了。资产树没有向上逃逸的 node_modules，
# 模块解析行为和真机一致，所以在这里 fork 三个 utility 就能提前抓到
# 「又缺了一个包」——否则要等用户装到手机上、截图、再猜一轮（5 分钟）。
echo "④a2 校验 utility 能否在真机同等条件下加载"
node "$ROOT/tools/verify-utilities.mjs" "$APKROOT/assets/web"

cat > "$APKROOT/assets/runtime/version.json" <<JSON
{
  "node": "26.4.0",
  "source": "termux-packages (aarch64)",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# 资产清单：Java 端按它解压并报进度。
# 不靠 AssetManager.list 猜目录还是文件 —— 空目录和文件在它眼里长得一样。
echo "④b 生成资产清单"
python3 - "$APKROOT" <<'PY'
import json, os, sys, hashlib
root = sys.argv[1]
assets = os.path.join(root, "assets")
files, total = [], 0
for dirpath, _dirs, names in os.walk(assets):
    for name in names:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, assets)
        if rel in ("manifest.json",):
            continue
        size = os.path.getsize(full)
        files.append({"p": rel, "s": size})
        total += size
files.sort(key=lambda item: item["p"])
# version 由内容算出来，不是手工 +1 的常量。
# 客户端拿它跟自己的安装指纹比，不一致就重新解压 —— 覆盖安装新包必须能铺下新资产。
digest = hashlib.sha256()
for item in files:
    digest.update(f'{item["p"]}:{item["s"]}\n'.encode("utf-8"))
version = digest.hexdigest()[:16]
manifest = {"version": version, "total": total, "files": files}
json.dump(manifest, open(os.path.join(assets, "manifest.json"), "w"),
          ensure_ascii=False, separators=(",", ":"))
print(f"   清单 {len(files)} 个文件，{total/1048576:.1f} MB，指纹 {version}")
PY

echo
echo "⑤ 完成"
echo "   lib/          $(du -sh "$APKROOT/lib" | cut -f1)"
echo "   assets/runtime $(du -sh "$APKROOT/assets/runtime" | cut -f1)"
echo "   assets/web     $(du -sh "$APKROOT/assets/web" | cut -f1)"
echo "   合计          $(du -sh "$APKROOT" | cut -f1)"
