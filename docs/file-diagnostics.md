# 按文件汇总与待复核范围

从 0.9.0 起，核验凭据附带 `file_diagnostics`，可单独导出为 `swarmcrate.diagnostics.v1` JSON；HTML 自动展示分组范围。

```sh
node scripts/swarmcrate.mjs verify ./release.torrent ./release --diagnostics ./files.json --receipt ./receipt.json --html ./report.html
node scripts/swarmcrate.mjs verify ./release.torrent ./release --file data.bin --diagnostics ./selected.json --detail-limit 100
```

三个输出可分别选择，目标必须是不同的新文件，父目录已存在。标准输出仍为 `swarmcrate.verify.v2`，退出码保持 0/1/2。核验失败也导出诊断；格式、stat/I/O 或源文件变化导致命令中止时返回 1，不写冒充完成的报告。载荷只读，不下载、裁切或自动修复文件。

## 字段与范围

所有区间使用文件内零起始字节偏移，表示 `[offset, offset + length)`。偏移、长度、大小与字节数均为十进制字符串，避免大整数舍入。重叠及相邻区间合并，同一物理范围由两套哈希报告时只计一次。

| 每文件字段 | 含义 |
| --- | --- |
| `file`, `path` | 原始真实文件索引与相对路径组件；虚拟补零不占文件索引。 |
| `expected_bytes`, `actual_bytes` | 期望大小与观测大小；`null` 表示未提供可用普通文件，包括缺失或同路径为目录等情况。 |
| `selected` | 是否直接选择检查；`false` 表示仅作为 v1 共享分片的邻居依赖。 |
| `size_issue` | `missing`、`size_mismatch` 或 `null`；大小问题独立于分片详情上限保留。 |
| `hash_mismatch_ranges`, `hash_mismatch_bytes` | 参与哈希不一致分片的候选范围与并集字节数，不说明其中每个字节都坏了。 |
| `unreadable_ranges`, `unreadable_bytes` | 受不可读分片影响的待复核范围，包括读取失败及因大小不符而未尝试读取的分片。 |
| `missing_ranges`, `missing_bytes` | 不可用文件的整个期望内容，或短文件缺少的尾部。缺失空文件没有字节范围，但仍有问题标记。 |
| `extra_ranges`, `extra_bytes` | 长文件在期望内容之后的额外尾部；独立展示，不自动删除。 |
| `attention_ranges`, `attention_bytes` | 哈希不一致、不可读影响与缺失内容的并集，限于期望内容；额外尾部单列。不同类别可重叠，字节数不能直接相加。 |
| `has_recorded_issue` | 是否有已记录的大小或范围问题。空文件缺失仍为 `true`；详情截断时 `false` 不代表通过。 |
| `ranges_complete` | 是否保留完整失败分片详情；截断时所有行均为 `false`。它不表示整个资料包被选中或通过。 |

例如，一个混合格式分片同时产生 SHA-1、SHA-256 不一致，范围均为 `16384 + 16384`，汇总仍是 16,384 字节。两个相邻失败物理分片则合并为 `16384 + 32768`。

v1 共享分片必须保守解释：`a` 的末尾与 `b` 的开头参与同一失败分片时，两个文件都会列入候选范围，无法凭该片哈希判断哪个文件实际损坏。如果 `b` 不可用，`a` 对应部分也无法完成分片认证，不能据此认定 `a` 的读取本身失败。独立 v2、经过布局校验的混合格式不需要这种邻居真实字节。

短文件缺少尾部也不代表已有前缀通过。当前核验器对大小不符文件跳过内容读取，所以不可读影响可覆盖整个期望内容；`attention_ranges` 合并重叠的缺失尾部，避免重复计数。

## 身份、选择范围和截断

独立 JSON 绑定精确种子原始字节的 `metainfo_sha256` / `metainfo_bytes` 及两套 infohash，与同次凭据的 `file_diagnostics` 完全相同。它保留 `ok`、`complete`、选择/依赖集合及检查/跳过/失败计数。`files` 仅列 `required_files`，按原索引排序；未检查文件不会被列成通过，邻居依赖也不代表检查其整个内容。

`details_truncated=true` 时，`ranges_complete=false`；`omitted_failure_checks` 是遗漏详情的哈希检查数，包括混合格式的两套哈希，不等于遗漏物理范围数。`files_with_recorded_issues`、候选范围与字节数此时只描述已保存内容，可能还有未列出的受影响文件。HTML 明示 `INCOMPLETE`，不得将不完整清单作为全部修复目标。

`--detail-limit N` 支持 1..10000，默认 4096，只限制保存的失败分片详情。实际所选范围仍全部遍历，汇总计数及所有大小问题继续保留。即便未截断，范围也只是待复核候选，不能精确定位每个坏字节或直接作为自动修复依据。

普通 JSON 没有签名、发布者认证、可信时间戳或未来有效性保证，输入变化后需重新核验。CLI 读取载荷前预检全部输出，写出前复查所需文件，依次独占写入凭据、诊断、HTML。多个输出不是原子事务；后续 I/O 失败时此前完整输出可保留。

## MoonBit 与复现

`verify_with_receipt(...)` 捕获同次核验快照；`receipt_diagnostics_json_text(receipt)` 返回独立诊断文本。`receipt_json_text(receipt)` 内的 `file_diagnostics` 是从 0.9.0 起加入 `swarmcrate.receipt.v1` 的附加字段；0.8.0 历史 JSON 不含该字段。独立 JSON 来自同次凭据，未新增任意元数据与报告重配的导出接口，调用方修改返回报告也不会改变快照。既有 HTML API 的调用者仍须保证 `info` 与 `report` 匹配；CLI 自动使用同一输入。

`examples/library` 在 Wasm GC 和 JS 使用新接口；磁盘演示导出诊断并断言两套哈希不会重复计算物理范围。双后端测试用字节位图对照区间并集，覆盖大偏移、邻居、空文件、长短文件及截断；真实文件场景用 Python/libtorrent 对照身份、布局与独立 v1 补零，并注入异常/短读验证范围及单遍读取量。
