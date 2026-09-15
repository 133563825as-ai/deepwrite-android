#!/usr/bin/env python3
"""把 public-data.properties 登记进（或从）assets/manifest.json 移除。

**为什么需要这个脚本** —— 2026-09-15 的一次真事故：

RuntimeInstaller **用清单驱动解压**，不是遍历 assets（见它的类注释：空目录和文件在
AssetManager.list() 眼里长得一样）。所以「文件在 APK 里」≠「文件会落到设备上」。

而 build.sh 复制这份配置的时机**晚于** fetch-runtime.sh 生成清单 ——
于是它成了一个永远不被解压的文件。表现极具误导性：
**装的确是新版**（versionCode 真的涨了、渲染层的 bundle 也换了名字、
连手机上的桥都是新版本号），**界面却还是旧行为**——技能广场照样报
「无法解析技能广场服务器地址」，因为设备上的 NodeRunner 根本找不到那个配置文件。

教训：清单是这台设备上「什么会被铺下来」的**唯一真相**；
往 assets 里加文件，就必须同时登记进清单。

指纹（version）按 fetch-runtime.sh 的**同一算法**重算，两处不会各算一套。

用法：python3 tools/register-public-data.py <apkroot> <present|absent>
"""
import hashlib
import json
import os
import sys

REL = "web/public-data.properties"


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in {"present", "absent"}:
        print(__doc__)
        return 2

    apkroot, mode = sys.argv[1], sys.argv[2]
    manifest_path = os.path.join(apkroot, "assets", "manifest.json")
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)

    files = [item for item in manifest["files"] if item.get("p") != REL]
    if mode == "present":
        target = os.path.join(apkroot, "assets", REL)
        files.append({"p": REL, "s": os.path.getsize(target)})

    # 与 fetch-runtime.sh 生成清单时完全一致：按路径排序 + 同一指纹算法
    files.sort(key=lambda item: item["p"])
    digest = hashlib.sha256()
    for item in files:
        digest.update(f'{item["p"]}:{item["s"]}\n'.encode("utf-8"))

    manifest["files"] = files
    manifest["total"] = sum(item["s"] for item in files)
    manifest["version"] = digest.hexdigest()[:16]

    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, separators=(",", ":"))

    verb = "登记" if mode == "present" else "移除"
    print(f"   清单已{verb} {REL}；{len(files)} 个文件，指纹 {manifest['version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
