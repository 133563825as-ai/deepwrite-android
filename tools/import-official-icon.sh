#!/bin/bash
# 从官方发布包里取出品牌图标，铺成我们自己的 res/ 资源。
#
# 背景：我们原先的图标是手画的矢量（一个「图表」图形），跟 DeepWrite 的品牌图标无关。
# 官方包 res/ 里的资源名被混淆成了 res/XX.webp 这种（文件其实是 PNG，扩展名骗人），
# 但 resources.arsc 里 type/id → 文件 的映射还在，可以按下面的对应关系取回来。
#
# 用法：bash tools/import-official-icon.sh [官方 apk 路径]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="${1:-/root/DeepWrite_1.1.3.apk}"
RES="$ROOT/res"

[ -f "$APK" ] || { echo "❌ 找不到官方包：$APK"; exit 1; }

# 官方 mipmap 各密度对应的混淆文件名（由 aapt2 dump resources 得出）
#   0x7f0e0000 mipmap/ic_launcher            → d2 / MO / qs / Sn / sK
#   0x7f0e0001 mipmap/ic_launcher_foreground → Nt / 13 / 9Q / iE / 5c
#   0x7f0e0002 mipmap/ic_launcher_monochrome → _l / mJ / Yu / ae / IG
#   0x7f0e0003 mipmap/ic_launcher_round      → yw / fq / u5 / j_ / -6
DENSITIES=(mdpi hdpi xhdpi xxhdpi xxxhdpi)
LAUNCHER=(d2 MO qs Sn sK)
ROUND=(yw fq u5 j_ -6)
FOREGROUND=(Nt 13 9Q iE 5c)
MONOCHROME=(_l mJ Yu ae IG)

python3 - "$APK" "$RES" <<'PY'
import os, sys, zipfile

apk, res = sys.argv[1], sys.argv[2]
densities = ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]
groups = {
    "ic_launcher": ["d2", "MO", "qs", "Sn", "sK"],
    "ic_launcher_round": ["yw", "fq", "u5", "j_", "-6"],
    "ic_launcher_foreground": ["Nt", "13", "9Q", "iE", "5c"],
    "ic_launcher_monochrome": ["_l", "mJ", "Yu", "ae", "IG"],
}
z = zipfile.ZipFile(apk)
for name, files in groups.items():
    for density, stem in zip(densities, files):
        src = f"res/{stem}.webp"
        try:
            data = z.read(src)
        except KeyError:
            print(f"   ⚠️ 官方包里没有 {src}，跳过 {name}/{density}")
            continue
        if not data.startswith(b"\x89PNG"):
            print(f"   ⚠️ {src} 不是 PNG（头 {data[:4]!r}），跳过")
            continue
        target_dir = os.path.join(res, f"mipmap-{density}")
        os.makedirs(target_dir, exist_ok=True)
        with open(os.path.join(target_dir, f"{name}.png"), "wb") as out:
            out.write(data)
        print(f"   mipmap-{density}/{name}.png  {len(data)}B")
PY

cat > "$RES/values/colors.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- 官方 adaptive icon 的 background：color/iconBackground = #ff34383d -->
    <color name="iconBackground">#ff34383d</color>
</resources>
XML
echo "   values/colors.xml"

cat > "$RES/mipmap-anydpi-v26/ic_launcher.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/iconBackground" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
XML
cp "$RES/mipmap-anydpi-v26/ic_launcher.xml" "$RES/mipmap-anydpi-v26/ic_launcher_round.xml"
echo "   mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml"

# 之前为了「有图标」手画的那套已经没有引用了；anydpi 那份 layer-list 还会
# 盖住密度版 PNG（anydpi 优先于任何密度限定符），一并清掉。
rm -rf "$RES/mipmap-anydpi" "$RES/drawable/ic_launcher_background.xml" \
       "$RES/drawable/ic_launcher_foreground.xml"
echo "   已清掉手画的旧图标资源"

echo "✅ 图标资源就位"
