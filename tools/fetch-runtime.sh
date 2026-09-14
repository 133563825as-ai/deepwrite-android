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
cp -r "$WEB_OUT/renderer" "$APKROOT/assets/web/renderer"
cp -r "$WEB_OUT/main" "$APKROOT/assets/web/main"
cp "$WEB_OUT/server.mjs" "$APKROOT/assets/web/server.mjs"
cp "$WEB_OUT/server-workspace.mjs" "$APKROOT/assets/web/server-workspace.mjs"
cp "$WEB_OUT/server-dialog.mjs" "$APKROOT/assets/web/server-dialog.mjs"
cp "$WEB_OUT/api-commands.json" "$APKROOT/assets/web/api-commands.json"
[ -f "$WEB_OUT/package.json" ] && cp "$WEB_OUT/package.json" "$APKROOT/assets/web/package.json"
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
import json, os, sys
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
manifest = {"version": 1, "total": total, "files": files}
json.dump(manifest, open(os.path.join(assets, "manifest.json"), "w"),
          ensure_ascii=False, separators=(",", ":"))
print(f"   清单 {len(files)} 个文件，{total/1048576:.1f} MB")
PY

echo
echo "⑤ 完成"
echo "   lib/          $(du -sh "$APKROOT/lib" | cut -f1)"
echo "   assets/runtime $(du -sh "$APKROOT/assets/runtime" | cut -f1)"
echo "   assets/web     $(du -sh "$APKROOT/assets/web" | cut -f1)"
echo "   合计          $(du -sh "$APKROOT" | cut -f1)"
