#!/bin/bash
# DeepWrite Android（独立版）APK · 可移植构建脚本。
# 本地（Android 上的 Ubuntu 容器）与 GitHub Actions 共用这一份逻辑，
# 唯一需要区分的是 ANDROID_SDK_ROOT。
#
# 用法：
#   bash build.sh                                  # 用默认 SDK 路径
#   ANDROID_SDK_ROOT=/usr/lib/android-sdk bash build.sh
#
# 为什么用 aapt2：早先以为「容器里没有 arm64 的 aapt2」，于是手写 AXML 生成器
# （tools/make_manifest.py）。实测那个前提是错的 —— apt 的 aapt 包顺带提供
# 原生 aarch64 的 aapt2 / zipalign（见 pick_tool）。手写那套必须绕开 resources.arsc，
# 代价是：没有图标（系统只给默认图标）、应用详情页读不出完整包信息（占用空间显示 0）、
# 还得自己维护 Res_value / 资源映射表这些容易写错位的二进制细节。
# 换成 aapt2 之后 manifest 恢复成明文 src 文件，资源与图标走正规编译。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$ROOT/tools"
WORK="${WORK_DIR:-$ROOT/build}"
OUT_APK="${OUT_APK:-$ROOT/out/DeepWrite-Android.apk}"

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/root/wk/android-sdk}}"
if [ ! -d "$SDK" ]; then
  echo "❌ 找不到 Android SDK：$SDK（用 ANDROID_SDK_ROOT 指定）"
  exit 1
fi

BT="$(find "$SDK/build-tools" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)"
PLATFORM_DIR="$(find "$SDK/platforms" -maxdepth 1 -mindepth 1 -type d -name 'android-*' 2>/dev/null | sort -V | tail -1)"
PLATFORM="$PLATFORM_DIR/android.jar"
[ -n "$BT" ] || { echo "❌ SDK 里没有 build-tools：$SDK/build-tools"; exit 1; }
[ -f "$PLATFORM" ] || { echo "❌ 缺少 android.jar：$PLATFORM"; exit 1; }
[ -f "$BT/lib/d8.jar" ] || { echo "❌ 缺少 d8.jar：$BT/lib/d8.jar"; exit 1; }

# aapt2 / zipalign：SDK 里带的是 x86_64，在这台 aarch64 容器上跑不了（bad machine）。
# Debian/Ubuntu 的 aapt 包顺带提供原生 aarch64 版本，优先用能跑的那份。
pick_tool() {
  local name="$1" candidate
  for candidate in "$(command -v "$name" 2>/dev/null || true)" \
                   "/usr/lib/android-sdk/build-tools/debian/$name" \
                   "$BT/$name"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}
AAPT2="$(pick_tool aapt2 || true)"
ZIPALIGN="$(pick_tool zipalign || true)"
[ -n "$AAPT2" ] || { echo "❌ 找不到能执行的 aapt2（apt-get install -y aapt）"; exit 1; }
[ -n "$ZIPALIGN" ] || { echo "❌ 找不到能执行的 zipalign（apt-get install -y zipalign）"; exit 1; }

echo "SDK        : $SDK"
echo "build-tools: $(basename "$BT")"
echo "platform   : $(basename "$PLATFORM_DIR")"
echo "aapt2      : $AAPT2 ($("$AAPT2" version | head -1))"
echo "zipalign   : $ZIPALIGN"

KS="${KEYSTORE:-$ROOT/deepwrite.keystore}"
KS_PASS="${KEYSTORE_PASS:-deepwrite}"
KS_ALIAS="${KEYSTORE_ALIAS:-deepwrite}"

# 注意：不要清空整个 $WORK —— 里面的 apk/ 是 fetch-runtime.sh 产出的资产目录
rm -rf "$WORK/classes" "$WORK/dex" "$WORK/aligned.apk" "$WORK/base.apk" "$WORK/unsigned.apk"
mkdir -p "$WORK/classes" "$WORK/dex" "$(dirname "$OUT_APK")"

echo "① 编译资源与清单（aapt2）"
rm -rf "$WORK/res.zip" "$WORK/gen"
"$AAPT2" compile --dir "$ROOT/res" -o "$WORK/res.zip"
# versionCode / versionName / uses-sdk 都写在 AndroidManifest.xml 里，这里不重复指定，
# 免得两处各说各话。--min-sdk-version 只影响资源限定符的裁剪。
"$AAPT2" link -o "$WORK/base.apk" -I "$PLATFORM" \
  --manifest "$ROOT/AndroidManifest.xml" \
  "$WORK/res.zip" \
  --min-sdk-version 24 --java "$WORK/gen"

echo "② 编译 Java"
# ⚠️ 必须把 aapt2 生成的 R.java（第 ① 步的 --java "$WORK/gen"）一起交给 javac。
# 漏了它，任何用 R.* 引用资源的代码都会报 "package R does not exist" ——
# 之前没有代码用 R，所以这条一直没暴露（本轮 TaskDescription 取图标时才踩到）。
javac -encoding UTF-8 -source 17 -target 17 \
  -classpath "$PLATFORM" \
  -d "$WORK/classes" \
  $(find "$ROOT/src" "$WORK/gen" -name "*.java")

echo "③ 转 dex"
java -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --min-api 24 --lib "$PLATFORM" --output "$WORK/dex" \
  $(find "$WORK/classes" -name "*.class")

echo "④ 组装 APK（aapt2 产物 + dex + lib/ + assets/）"
cp "$WORK/dex/classes.dex" "$WORK/classes.dex"
APKROOT="${APK_ROOT:-$ROOT/build/apk}"
if [ ! -d "$APKROOT/assets" ]; then
  echo "❌ 缺少 $APKROOT —— 先跑一次： bash tools/fetch-runtime.sh"
  exit 1
fi

# 技能广场 / 官方公开数据服务的地址与 Key（见 NodeRunner.applyPublicDataConfig）。
# 真实值放 public-data.local（已 .gitignore），这里只复制成 APK 资源，
# 所以仓库里不出现密钥，而设备上仍可从解压后的 web/public-data.properties 读到。
# 源文件不存在就**显式删掉产物**：留着上一轮的会把「没配置」伪装成「配好了」。
#
# ⚠️ 复制之后**必须登记进 assets/manifest.json**：RuntimeInstaller 是按清单解压的，
# 不进清单的文件在 APK 里躺着、却永远落不到设备上。2026-09-15 就是这么栽的 ——
# 装的是 vc42 新版、渲染层 bundle 都换名了，技能广场却照旧报「无法解析服务器地址」，
# 因为设备上根本没有那个配置文件。
PUBLIC_DATA_SRC="$ROOT/public-data.local"
PUBLIC_DATA_DST="$APKROOT/assets/web/public-data.properties"
if [ -f "$PUBLIC_DATA_SRC" ]; then
  cp "$PUBLIC_DATA_SRC" "$PUBLIC_DATA_DST"
  python3 "$TOOLS/register-public-data.py" "$APKROOT" present
else
  rm -f "$PUBLIC_DATA_DST"
  python3 "$TOOLS/register-public-data.py" "$APKROOT" absent
  echo "   ⚠️ 没有 public-data.local —— 技能广场会回落到占位域 .invalid，"
  echo "      用户在界面上会看到「无法解析技能广场服务器地址，请检查 DNS 或网络连接」"
fi

python3 - "$WORK" "$APKROOT" <<'PY'
import os, sys, zipfile

work, apkroot = sys.argv[1], sys.argv[2]
base = os.path.join(work, "base.apk")
out_path = os.path.join(work, "unsigned.apk")
# AndroidManifest.xml 与 resources.arsc 必须不压缩（后者是 targetSdk 30+ 的硬要求，
# 前者沿用一直能装的形态），缩过的 res/ 保持压缩。
STORED = {"AndroidManifest.xml", "resources.arsc"}
total = 0
with zipfile.ZipFile(base) as src, \
     zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as out:
    for item in src.infolist():
        if item.filename.endswith("/"):
            continue
        data = src.read(item.filename)
        if item.filename in STORED:
            out.writestr(zipfile.ZipInfo(item.filename), data, zipfile.ZIP_STORED)
        else:
            out.writestr(item.filename, data, zipfile.ZIP_DEFLATED)
        total += 1
    out.write(os.path.join(work, "classes.dex"), "classes.dex", zipfile.ZIP_DEFLATED)
    for zip_prefix, src_dir in (("lib", os.path.join(apkroot, "lib")),
                                ("assets", os.path.join(apkroot, "assets"))):
        if not os.path.isdir(src_dir):
            continue
        for dirpath, _dirs, names in os.walk(src_dir):
            for name in names:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, src_dir)
                arc = zip_prefix + "/" + rel.replace(os.sep, "/")
                out.write(full, arc, zipfile.ZIP_DEFLATED)
                total += 1
print(f"  已组装 unsigned.apk（{total} 个条目，{os.path.getsize(out_path)/1048576:.1f} MB）")
PY

echo "⑤ 对齐"
# 必须在签名之前：apksigner 之后再加 v2 签名块，对齐就被破坏了。
"$ZIPALIGN" -f -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c -p 4 "$WORK/aligned.apk" && echo "   对齐校验通过"

echo "⑥ 签名"
if [ ! -f "$KS" ]; then
  echo "   未找到 keystore，生成一个临时签名密钥：$KS"
  echo "   （临时密钥每次构建都不同，只能全新安装，不能覆盖升级）"
  keytool -genkeypair -v -keystore "$KS" -alias "$KS_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=DeepWrite Mobile, OU=Dev, O=DeepWrite, C=CN" >/dev/null 2>&1
fi

java -jar "$BT/lib/apksigner.jar" sign \
  --ks "$KS" --ks-key-alias "$KS_ALIAS" \
  --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --min-sdk-version 24 \
  --v1-signing-enabled true \
  --out "$OUT_APK" "$WORK/aligned.apk"

java -jar "$BT/lib/apksigner.jar" verify --min-sdk-version 24 --print-certs "$OUT_APK" | head -3
ls -la "$OUT_APK"
echo "APK_OK $OUT_APK"
