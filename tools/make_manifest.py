#!/usr/bin/env python3
"""生成 DeepWrite 手机壳的 AndroidManifest.xml（AXML）。

只使用系统资源（@android:style/...），因此不需要 resources.arsc，
这样就能绕开容器里没有 arm64 aapt2 的限制。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from android_resource import (  # noqa: E402
    AxmlBuilder,
    AxmlReader,
    TYPE_INT_BOOLEAN,
    TYPE_INT_DEC,
    TYPE_INT_HEX,
    TYPE_REFERENCE,
)

ANDROID_NS = "http://schemas.android.com/apk/res/android"
PACKAGE = "ai.deepwrite.mobile"

# 系统主题的资源 id
THEME_DEVICE_DEFAULT_LIGHT_NO_ACTION_BAR = 0x01030237
# 系统权限字符串（manifest 里用全名写法）
PERMISSION_INTERNET = "android.permission.INTERNET"
PERMISSION_NETWORK_STATE = "android.permission.ACCESS_NETWORK_STATE"
# 作品存在 /sdcard/Documents/DeepWrite，Node 需要按真实路径读写 —— 只能要这个权限。
PERMISSION_MANAGE_EXTERNAL_STORAGE = "android.permission.MANAGE_EXTERNAL_STORAGE"
# 配置变更掩码
CONFIG_CHANGES = 0x00004FB0  # orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize|uiMode
SOFT_INPUT_ADJUST_RESIZE = 0x00000010
LAUNCH_MODE_SINGLE_TASK = 0x00000003
# <uses-sdk>：Android 14 起，targetSdkVersion < 23 的包会被系统直接拒装
# （INSTALL_FAILED_DEPRECATED_SDK_VERSION）。缺省时 targetSdk 会退化成 1，装不上。
# 与 build-apk.sh 里的 d8 --min-api / apksigner --min-sdk-version 保持一致。
MIN_SDK_VERSION = 24
TARGET_SDK_VERSION = 34


def android(name, raw, typed=None):
    return (ANDROID_NS, name, raw, typed)


def build_manifest():
    builder = AxmlBuilder()
    builder.start_namespace("android", ANDROID_NS)
    builder.start_element(
        "manifest",
        [
            (None, "package", PACKAGE, None),
            android("versionCode", "3", (TYPE_INT_DEC, 3)),
            android("versionName", "2.0.0", None),
        ],
    )

    builder.start_element(
        "uses-sdk",
        [
            android("minSdkVersion", str(MIN_SDK_VERSION), (TYPE_INT_DEC, MIN_SDK_VERSION)),
            android("targetSdkVersion", str(TARGET_SDK_VERSION), (TYPE_INT_DEC, TARGET_SDK_VERSION)),
        ],
    )
    builder.end_element("uses-sdk")

    builder.start_element(
        "uses-permission",
        [android("name", PERMISSION_INTERNET, None)],
    )
    builder.end_element("uses-permission")
    builder.start_element(
        "uses-permission",
        [android("name", PERMISSION_NETWORK_STATE, None)],
    )
    builder.end_element("uses-permission")
    builder.start_element(
        "uses-permission",
        [android("name", PERMISSION_MANAGE_EXTERNAL_STORAGE, None)],
    )
    builder.end_element("uses-permission")

    builder.start_element(
        "application",
        [
            android("label", "DeepWrite", None),
            android("usesCleartextTraffic", "true", (TYPE_INT_BOOLEAN, 0xFFFFFFFF)),
            android("hardwareAccelerated", "true", (TYPE_INT_BOOLEAN, 0xFFFFFFFF)),
            android("supportsRtl", "true", (TYPE_INT_BOOLEAN, 0xFFFFFFFF)),
            # 必须为 true：libnode.so 要落到 nativeLibraryDir 才能被 exec
            # （Android 10+ 禁止执行应用可写目录里的文件）。
            android("extractNativeLibs", "true", (TYPE_INT_BOOLEAN, 0xFFFFFFFF)),
            android(
                "theme",
                "@android:style/Theme.DeviceDefault.Light.NoActionBar",
                (TYPE_REFERENCE, THEME_DEVICE_DEFAULT_LIGHT_NO_ACTION_BAR),
            ),
        ],
    )

    builder.start_element(
        "activity",
        [
            android("name", ".MainActivity", None),
            android("exported", "true", (TYPE_INT_BOOLEAN, 0xFFFFFFFF)),
            android("launchMode", None, (TYPE_INT_HEX, LAUNCH_MODE_SINGLE_TASK)),
            android("configChanges", None, (TYPE_INT_HEX, CONFIG_CHANGES)),
            android("windowSoftInputMode", None, (TYPE_INT_HEX, SOFT_INPUT_ADJUST_RESIZE)),
            android(
                "theme",
                "@android:style/Theme.DeviceDefault.Light.NoActionBar",
                (TYPE_REFERENCE, THEME_DEVICE_DEFAULT_LIGHT_NO_ACTION_BAR),
            ),
        ],
    )
    builder.start_element("intent-filter", [])
    builder.start_element(
        "action",
        [android("name", "android.intent.action.MAIN", None)],
    )
    builder.end_element("action")
    builder.start_element(
        "category",
        [android("name", "android.intent.category.LAUNCHER", None)],
    )
    builder.end_element("category")
    builder.end_element("intent-filter")
    builder.end_element("activity")
    builder.end_element("application")
    builder.end_element("manifest")
    builder.end_namespace("android", ANDROID_NS)
    return builder.build()


if __name__ == "__main__":
    # 可选参数：输出路径。不给就落在脚本目录下的 build/（保持原行为）。
    target = (
        Path(sys.argv[1])
        if len(sys.argv) > 1
        else Path(__file__).parent / "build/AndroidManifest.xml"
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    data = build_manifest()
    target.write_bytes(data)
    reader = AxmlReader(data)
    print(f"已写出 {target}（{len(data)} 字节）")
    for element in reader.elements:
        attrs = ", ".join(
            f"{a['name']}={a['raw']!r}" for a in element["attributes"] if a["name"]
        )
        print(f"  <{element['name']} {attrs}>")
    print("属性资源 id:", [hex(i) for i in reader.resource_map()])
