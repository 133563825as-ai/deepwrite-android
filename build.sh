#!/bin/bash
# DeepWrite 手机壳 APK · 可移植构建脚本。
# 本地（Android 上的 Ubuntu 容器）与 GitHub Actions 共用这一份逻辑，
# 唯一需要区分的是 ANDROID_SDK_ROOT。
#
# 用法：
#   bash build.sh                                  # 用默认 SDK 路径
#   ANDROID_SDK_ROOT=/usr/lib/android-sdk bash build.sh
#
# 为什么不用 aapt2：容器里没有 arm64 的 aapt2，所以 manifest 走自研 AXML
# 生成器（tools/make_manifest.py）。它只引用系统资源，因此不需要 resources.arsc，
# 也就不需要 aapt2 参与资源编译。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$ROOT/tools"
WORK="${WORK_DIR:-$ROOT/build}"
OUT_APK="${OUT_APK:-$ROOT/out/DeepWrite-mobile.apk}"

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

echo "SDK        : $SDK"
echo "build-tools: $(basename "$BT")"
echo "platform   : $(basename "$PLATFORM_DIR")"

KS="${KEYSTORE:-$ROOT/deepwrite.keystore}"
KS_PASS="${KEYSTORE_PASS:-deepwrite}"
KS_ALIAS="${KEYSTORE_ALIAS:-deepwrite}"

# 注意：不要清空整个 $WORK —— 里面的 apk/ 是 fetch-runtime.sh 产出的资产目录
rm -rf "$WORK/classes" "$WORK/dex" "$WORK/aligned.apk"
mkdir -p "$WORK/classes" "$WORK/dex" "$(dirname "$OUT_APK")"

echo "① 生成 AndroidManifest.xml（AXML）"
python3 "$TOOLS/make_manifest.py" "$WORK/AndroidManifest.xml" | head -3

echo "② 编译 Java"
javac -encoding UTF-8 -source 17 -target 17 \
  -classpath "$PLATFORM" \
  -d "$WORK/classes" \
  $(find "$ROOT/src" -name "*.java")

echo "③ 转 dex"
java -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --min-api 24 --lib "$PLATFORM" --output "$WORK/dex" \
  $(find "$WORK/classes" -name "*.class")

echo "④ 组装 APK（manifest 第一且不压缩；lib/ 与 assets/ 一并收进去）"
cp "$WORK/dex/classes.dex" "$WORK/classes.dex"
APKROOT="${APK_ROOT:-$ROOT/build/apk}"
if [ ! -d "$APKROOT/assets" ]; then
  echo "❌ 缺少 $APKROOT —— 先跑一次： bash tools/fetch-runtime.sh"
  exit 1
fi
python3 - "$WORK" "$APKROOT" <<'PY'
import os, sys, zipfile

work, apkroot = sys.argv[1], sys.argv[2]
out_path = os.path.join(work, "aligned.apk")
total = 0
with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as out:
    out.write(os.path.join(work, "AndroidManifest.xml"), "AndroidManifest.xml", zipfile.ZIP_STORED)
    out.write(os.path.join(work, "classes.dex"), "classes.dex", zipfile.ZIP_DEFLATED)
    for zip_prefix, src in (("lib", os.path.join(apkroot, "lib")),
                            ("assets", os.path.join(apkroot, "assets"))):
        if not os.path.isdir(src):
            continue
        for dirpath, _dirs, names in os.walk(src):
            for name in names:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, src)
                arc = zip_prefix + "/" + rel.replace(os.sep, "/")
                out.write(full, arc, zipfile.ZIP_DEFLATED)
                total += 1
print(f"  已组装 aligned.apk（{total} 个附加条目，{os.path.getsize(out_path)/1048576:.1f} MB）")
PY

echo "⑤ 签名"
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
