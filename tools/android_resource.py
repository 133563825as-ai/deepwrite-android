#!/usr/bin/env python3
"""最小的 Android 二进制 XML（AXML）与 resources.arsc 生成器。

这个容器里没有 arm64 原生 aapt2，x86_64 版本又受沙箱限制跑不起来，
所以直接按 AOSP 的 ResChunk 结构手写 manifest 与资源表。
输出会再用本文件的 reader 读回来校验，确保结构自洽。
"""
import struct

# ---------------------------------------------------------------- 常量
RES_STRING_POOL_TYPE = 0x0001
RES_XML_TYPE = 0x0003
RES_XML_START_NAMESPACE_TYPE = 0x0100
RES_XML_END_NAMESPACE_TYPE = 0x0101
RES_XML_START_ELEMENT_TYPE = 0x0102
RES_XML_END_ELEMENT_TYPE = 0x0103
RES_XML_CDATA_TYPE = 0x0104
RES_XML_RESOURCE_MAP_TYPE = 0x0180
RES_TABLE_TYPE = 0x0002
RES_TABLE_PACKAGE_TYPE = 0x0200
RES_TABLE_TYPE_TYPE = 0x0201
RES_TABLE_TYPE_SPEC_TYPE = 0x0202

UTF8_FLAG = 1 << 8

TYPE_NULL = 0x00
TYPE_REFERENCE = 0x01
TYPE_STRING = 0x03
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11
TYPE_INT_BOOLEAN = 0x12

# Res_value.size 恒为 8（H + B + B + I）
RES_VALUE_SIZE = 8

NO_ENTRY = 0xFFFFFFFF

# android 命名空间下常用属性的资源 id
ATTR_IDS = {
    "theme": 0x01010000,
    "label": 0x01010001,
    "icon": 0x01010002,
    "name": 0x01010003,
    "permission": 0x01010006,
    "exported": 0x01010010,
    "windowSoftInputMode": 0x0101022B,
    "configChanges": 0x0101001F,
    "launchMode": 0x0101001D,
    "hardwareAccelerated": 0x010102D3,
    "supportsRtl": 0x010103AF,
    "usesCleartextTraffic": 0x010104EC,
    "versionCode": 0x0101021B,
    "versionName": 0x0101021C,
    "minSdkVersion": 0x0101020C,
    "targetSdkVersion": 0x01010270,
    "windowBackground": 0x01010054,
    "statusBarColor": 0x01010451,
    "navigationBarColor": 0x01010452,
    "windowLightStatusBar": 0x010104B3,
    "screenOrientation": 0x0101001E,
    "allowBackup": 0x01010280,
    # 以下条目取自官方包 DeepWrite_1.1.3.apk 的清单资源映射（aapt2 产物），
    # 用于原样重建一个复杂清单；数值已与官方逐条比对一致。
    "protectionLevel": 0x01010009,
    "enabled": 0x0101000E,
    "authorities": 0x01010018,
    "initOrder": 0x0101001A,
    "grantUriPermissions": 0x0101001B,
    "value": 0x01010024,
    "resource": 0x01010025,
    "mimeType": 0x01010026,
    "scheme": 0x01010027,
    "maxSdkVersion": 0x01010271,
    "required": 0x0101028E,
    "extractNativeLibs": 0x010104EA,
    "fullBackupContent": 0x010104EB,
    "directBootAware": 0x01010505,
    "roundIcon": 0x0101052C,
    "compileSdkVersion": 0x01010572,
    "compileSdkVersionCodename": 0x01010573,
    "appComponentFactory": 0x0101057A,
    "dataExtractionRules": 0x0101063E,
    "enableOnBackInvokedCallback": 0x0101066C,
}


def _pad(data, multiple=4):
    if len(data) % multiple:
        data += b"\x00" * (multiple - len(data) % multiple)
    return data


class StringPool:
    """UTF-8 编码的字符串池。"""

    def __init__(self, strings):
        self.strings = list(strings)
        self.index = {}
        for position, value in enumerate(self.strings):
            self.index.setdefault(value, position)

    def add(self, value):
        if value in self.index:
            return self.index[value]
        self.index[value] = len(self.strings)
        self.strings.append(value)
        return self.index[value]

    def encode(self):
        encoded = []
        offsets = []
        cursor = 0
        for value in self.strings:
            raw = value.encode("utf-8")
            # UTF-8 池：u16 字符数 + u8 字节数，再跟数据与 0 结尾
            char_len = len(value)
            chunk = struct.pack("<BB", char_len, len(raw)) + raw + b"\x00"
            offsets.append(cursor)
            encoded.append(chunk)
            cursor += len(chunk)
        body = b"".join(encoded)
        offsets_data = b"".join(struct.pack("<I", offset) for offset in offsets)
        strings_start = 28 + len(offsets_data)
        header = struct.pack(
            "<HHI",
            RES_STRING_POOL_TYPE,
            28,
            strings_start + len(body),
        )
        header += struct.pack("<IIIII", len(self.strings), 0, UTF8_FLAG, strings_start, 0)
        return header + offsets_data + body


def _chunk(chunk_type, header_size, payload):
    return struct.pack("<HHI", chunk_type, header_size, 8 + len(payload)) + payload


class AxmlBuilder:
    def __init__(self):
        self.pool = StringPool([])
        self.chunks = []
        self.attr_name_ids = []

    # ---- 工具
    def s(self, value):
        return self.pool.add(value)

    def _attr_id(self, name):
        return ATTR_IDS.get(name, 0)

    # ---- 元素
    def start_namespace(self, prefix, uri):
        payload = struct.pack("<II", self.s(prefix), self.s(uri)) + struct.pack("<I", 0xFFFFFFFF) + struct.pack("<I", 0xFFFFFFFF)
        self.chunks.append(_chunk(RES_XML_START_NAMESPACE_TYPE, 16, payload))

    def end_namespace(self, prefix, uri):
        payload = struct.pack("<II", self.s(prefix), self.s(uri)) + struct.pack("<I", 0xFFFFFFFF) + struct.pack("<I", 0xFFFFFFFF)
        self.chunks.append(_chunk(RES_XML_END_NAMESPACE_TYPE, 16, payload))

    def _node_header(self, extra_bytes=0):
        # lineNumber=1, comment=0xFFFFFFFF
        return struct.pack("<II", 1, 0xFFFFFFFF) + b"\x00" * extra_bytes

    def start_element(self, name, attributes, namespace=None):
        """attributes: [(ns, name, raw_value, typed_value_or_None)]"""
        attr_count = len(attributes)
        # ns/name 之后的扩展区：attributeStart, attributeSize, attributeCount,
        # idIndex, classIndex, styleIndex
        extension = struct.pack(
            "<II", self.s(namespace) if namespace else 0xFFFFFFFF, self.s(name)
        )
        extension += struct.pack("<HHHHHH", 0x0014, 0x0014, attr_count, 0, 0, 0)
        attr_data = b""
        for ns, attr_name, raw_value, typed in attributes:
            ns_id = self.s(ns) if ns else 0xFFFFFFFF
            name_id = self.s(attr_name)
            attr_id = self._attr_id(attr_name)
            if attr_id and attr_id not in self.attr_name_ids:
                self.attr_name_ids.append(attr_id)
            # Res_value 布局：size(H) res0(B) dataType(B) data(I)。
            # size 恒为 8；dataType 必须写在第 3 个字节上。
            # 之前把 dataType 写进了 size 字段、dataType 留成 TYPE_NULL(0)，
            # 系统读到的 typed value 全是 null —— usesCleartextTraffic /
            # exported / theme / targetSdkVersion 这些属性统统失效。
            if typed is None:
                if raw_value is None:
                    value = struct.pack("<HBBI", RES_VALUE_SIZE, 0, TYPE_NULL, 0xFFFFFFFF)
                    raw_index = 0xFFFFFFFF
                else:
                    raw_index = self.s(str(raw_value))
                    value = struct.pack("<HBBI", RES_VALUE_SIZE, 0, TYPE_STRING, raw_index)
            else:
                value_type, value_data = typed
                raw_index = self.s(str(raw_value)) if raw_value is not None else 0xFFFFFFFF
                value = struct.pack("<HBBI", RES_VALUE_SIZE, 0, value_type, value_data)
            attr_data += struct.pack("<III", ns_id, name_id, raw_index) + value
        payload = self._node_header() + extension + attr_data
        self.chunks.append(_chunk(RES_XML_START_ELEMENT_TYPE, 16, payload))

    def end_element(self, name):
        payload = self._node_header() + struct.pack("<II", 0xFFFFFFFF, self.s(name))
        self.chunks.append(_chunk(RES_XML_END_ELEMENT_TYPE, 16, payload))

    def build(self):
        body = b"".join(self.chunks)
        pool = self.pool.encode()
        resource_map = b""
        # RES_XML_RESOURCE_MAP 是按字符串池下标对齐的：
        # 第 i 项 = 池里第 i 个字符串对应的资源 id，非属性名记 0。
        # 之前是把「见过的属性 id」按首次出现顺序排成一列，与池完全错位，
        # 结果 getAttributeNameResource() 对每个属性都返回错的 id（对照组：官方 aapt2 产物）。
        entries = [ATTR_IDS.get(value, 0) for value in self.pool.strings]
        while entries and entries[-1] == 0:
            entries.pop()
        if entries:
            resource_map = _chunk(
                RES_XML_RESOURCE_MAP_TYPE, 8, b"".join(struct.pack("<I", i) for i in entries)
            )
        payload = pool + resource_map + body
        return _chunk(RES_XML_TYPE, 8, payload)


# ---------------------------------------------------------------- 资源表
def build_resources_arsc(package_name, values):
    """values: {资源名: 字符串值}，全部放在默认配置的 string 类型下。"""
    string_pool = StringPool([package_name] + list(values.values()))
    type_name = "string"
    key_pool = StringPool([type_name] + list(values.keys()))

    value_strings = StringPool(list(values.values()))

    # 1) 值字符串池（TYPE_STRING 指向它）
    value_pool_chunk = value_strings.encode()

    # 2) 字符串资源条目
    entry_offsets = []
    entries_data = b""
    for position, value in enumerate(values.values()):
        entry_offsets.append(len(entries_data))
        string_index = value_strings.index[value]
        entries_data += struct.pack("<HHI", 0x0008, 0, string_index)
    entries_data = _pad(entries_data, 4)

    type_chunk_header_size = 0x54
    type_payload = struct.pack("<BBHI", 0, 0, 0, 1)  # id, flags, reserved, entryCount
    type_payload += struct.pack("<II", 0x00000000, 0x00000000)  # entriesStart 占位, config
    type_payload += b"\x00" * 0x34
    type_chunk = None  # 见下：需要 entriesStart 才能定长度

    offsets_len = len(entry_offsets)
    type_header = struct.pack("<HHI", RES_TABLE_TYPE_TYPE, type_chunk_header_size, 0)
    type_header += struct.pack("<BBHI", 0, 0, 0, len(entry_offsets))
    type_header += struct.pack("<II", 0, 0)
    type_header += b"\x00" * (type_chunk_header_size - len(type_header))
    # 修正 entriesStart
    entries_start = type_chunk_header_size + 4 * offsets_len
    type_header = bytearray(type_header)
    struct.pack_into("<I", type_header, 12, entries_start)
    offsets_data = b"".join(struct.pack("<I", offset) for offset in entry_offsets)
    type_chunk = _chunk(RES_TABLE_TYPE_TYPE, type_chunk_header_size, bytes(type_header[type_chunk_header_size:]) + offsets_data + entries_data)
    type_chunk = struct.pack("<HHI", RES_TABLE_TYPE_TYPE, type_chunk_header_size, 8 + len(type_header[type_chunk_header_size:]) + len(offsets_data) + len(entries_data)) + bytes(type_header[type_chunk_header_size:]) + offsets_data + entries_data

    type_spec = _chunk(RES_TABLE_TYPE_SPEC_TYPE, 16, struct.pack("<BBII", 1, 0, 1, 0))

    # typeStrings 起始偏移 = 包 chunk 头(0x120) + 两个池
    package_header_size = 0x120
    type_strings_offset = package_header_size + len(string_pool) + len(key_pool)
    key_strings_offset = type_strings_offset + len(value_pool_chunk)

    package_payload = struct.pack("<II", 1, type_strings_offset)
    package_payload += struct.pack("<I", key_strings_offset)
    package_payload += struct.pack("<I", 0)  # lastPublicType
    package_payload += struct.pack("<I", 0)  # lastPublicKey
    package_payload += struct.pack("<I", 0)  # typeIdOffset（API 26+）
    package_payload = package_payload.ljust(package_header_size - 8, b"\x00")
    package_payload += string_pool + key_pool + value_pool_chunk + type_spec + type_chunk

    package_chunk = _chunk(RES_TABLE_PACKAGE_TYPE, package_header_size, package_payload)
    table_header = struct.pack("<I", package_header_size)
    return _chunk(RES_TABLE_TYPE, 12, table_header + package_chunk)


# ---------------------------------------------------------------- 读回校验
class AxmlReader:
    """把生成的 AXML 读回来，用于验证结构自洽（chunk 链、字符串池、属性索引）。"""

    def __init__(self, data):
        self.data = data
        self.pool = []
        self.elements = []
        self.resource_ids = []
        self._scan_chunks()
        self._parse_elements()

    def _read_pool(self, offset):
        chunk_type, header_size, size = struct.unpack_from("<HHI", self.data, offset)
        assert chunk_type == RES_STRING_POOL_TYPE, "not a string pool"
        count, _style_count, flags, strings_start, _styles_start = struct.unpack_from(
            "<IIIII", self.data, offset + 8
        )
        utf8 = bool(flags & UTF8_FLAG)
        strings = []
        for index in range(count):
            string_offset = struct.unpack_from("<I", self.data, offset + header_size + 4 * index)[0]
            base = offset + strings_start + string_offset
            if utf8:
                _chars, byte_len = struct.unpack_from("<BB", self.data, base)
                strings.append(self.data[base + 2 : base + 2 + byte_len].decode("utf-8"))
            else:
                char_len = struct.unpack_from("<H", self.data, base)[0]
                strings.append(self.data[base + 2 : base + 2 + char_len * 2].decode("utf-16-le"))
        return strings, size

    def _scan_chunks(self):
        _type, header_size, total = struct.unpack_from("<HHI", self.data, 0)
        offset = header_size
        while offset < total:
            chunk_type, _h, chunk_size = struct.unpack_from("<HHI", self.data, offset)
            if chunk_type == RES_STRING_POOL_TYPE:
                self.pool, _ = self._read_pool(offset)
            elif chunk_type == RES_XML_RESOURCE_MAP_TYPE:
                count = (chunk_size - 8) // 4
                self.resource_ids = [
                    struct.unpack_from("<I", self.data, offset + 8 + 4 * i)[0] for i in range(count)
                ]
            offset += chunk_size
        assert self.pool, "AXML 缺少字符串池"

    def _parse_elements(self):
        _type, header_size, total = struct.unpack_from("<HHI", self.data, 0)
        offset = header_size
        while offset < total:
            chunk_type, _h, chunk_size = struct.unpack_from("<HHI", self.data, offset)
            if chunk_type == RES_XML_START_ELEMENT_TYPE:
                # 实测起始元素布局（相对 chunk 起点）：
                #   +0x08 lineNumber, +0x0C comment
                #   +0x10 ns, +0x14 name
                #   +0x18 扩展区（12 字节）：attributeStart attributeSize
                #          attributeCount idIndex classIndex styleIndex
                #   +0x24 起为属性条目，每条 20 字节
                ns_index = struct.unpack_from("<I", self.data, offset + 0x10)[0]
                name_index = struct.unpack_from("<I", self.data, offset + 0x14)[0]
                attr_count = struct.unpack_from("<H", self.data, offset + 0x1C)[0]
                attributes = []
                attr_base = offset + 0x24
                for index in range(attr_count):
                    entry = attr_base + index * 20
                    ns_id, name_id, raw_id = struct.unpack_from("<III", self.data, entry)
                    # Res_value 从 entry+12 开始：size(H) res0(B) dataType(B) data(I)
                    value_size, _value_res0, value_type = struct.unpack_from(
                        "<HBB", self.data, entry + 12
                    )
                    value_data = struct.unpack_from("<I", self.data, entry + 16)[0]
                    attributes.append(
                        {
                            "ns": self.pool[ns_id] if ns_id != 0xFFFFFFFF else None,
                            "name": self.pool[name_id] if name_id != 0xFFFFFFFF else None,
                            "raw": self.pool[raw_id] if raw_id != 0xFFFFFFFF else None,
                            "size": value_size,
                            "type": value_type,
                            "data": value_data,
                        }
                    )
                self.elements.append(
                    {
                        "name": self.pool[name_index] if name_index != 0xFFFFFFFF else None,
                        "ns": self.pool[ns_index] if ns_index != 0xFFFFFFFF else None,
                        "attributes": attributes,
                    }
                )
            offset += chunk_size

    def resource_map(self):
        return self.resource_ids


if __name__ == "__main__":
    builder = AxmlBuilder()
    builder.start_namespace("android", "http://schemas.android.com/apk/res/android")
    builder.start_element(
        "manifest",
        [
            (None, "package", "ai.deepwrite.mobile", None),
            ("http://schemas.android.com/apk/res/android", "versionCode", "1", (TYPE_INT_DEC, 1)),
            ("http://schemas.android.com/apk/res/android", "versionName", "1.5.0", None),
        ],
    )
    builder.end_element("manifest")
    builder.end_namespace("android", "http://schemas.android.com/apk/res/android")
    binary = builder.build()
    reader = AxmlReader(binary)
    print("元素:", [(e["name"], [(a["name"], a["raw"]) for a in e["attributes"]]) for e in reader.elements])
    print("属性资源映射:", [hex(i) for i in reader.resource_map()])
    print("字节数:", len(binary))
