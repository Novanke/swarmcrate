# 核验凭据：身份、范围与结果

从 0.8.0 起，可将一次核验保存为 `swarmcrate.receipt.v1` JSON，随资料交付或用于离线巡检记录。凭据把同一次核验的种子身份、文件映射、观测大小和实际结果放在一起，避免把只有分片计数的报告误配给另一份种子。

```sh
node scripts/swarmcrate.mjs verify ./release.torrent ./release --receipt ./receipt.json --html ./report.html
node scripts/swarmcrate.mjs verify ./release.torrent ./release --file docs/manual.pdf --receipt ./manual-receipt.json
```

输出路径必须是新文件，父目录必须存在。默认标准输出仍为原有 `swarmcrate.verify.v2`；退出码仍为 0（所选范围通过）、2（核验失败）、1（输入、I/O 或一致性错误）。失败检查也保存凭据，不能只凭文件存在判断通过。

## 字段及其含义

| 字段 | 含义 |
| --- | --- |
| `schema` | `swarmcrate.receipt.v1`，与旧核验 JSON 的版本独立。 |
| `producer` | 生成工具名和版本；普通自述字段，不是来源认证。 |
| `subject.metainfo_sha256` | 本次读取的完整 `.torrent` 原始字节的 SHA-256 十六进制值。 |
| `subject.metainfo_bytes` | 原始种子字节数，十进制字符串。 |
| `subject.info_hash_v1` / `info_hash_v2` | 原始 `info` 字节的内容标识；该模式不存在的标识为 `null`。 |
| `subject.name` / `mode` / `piece_length` / `single_file` | 同一解析结果中的名称、格式、分片大小和文件布局。 |
| `subject.files` | 全部真实文件的 `{index, path, length}` 映射。索引与核验回调、范围及错误详情对应；路径为组件数组，长度为字符串。虚拟补零不占真实文件索引。 |
| `observations` | 仅包含 `required_files` 的 `{file, actual_bytes}`。大小为字符串；`null` 表示调用方或 CLI 未提供可用普通文件。未检查文件不列入此数组。 |
| `verification` | 完整嵌入既有 `swarmcrate.verify.v2`：范围、计数、文件问题、分片失败、偏移和详情截断标记，与该次 CLI 标准输出一致。 |
| `outcome` | `FAIL`：所选范围失败；`PARTIAL_PASS`：局部范围通过；`PASS`：全部列出文件均被选中且通过。 |
| `is_digital_signature` / `publisher_authenticated` | 均为 `false`，明确本格式不提供签名或发布者身份认证。 |

例如，选择 v1 的文件 `a`，它与 `b` 共用一个分片时，`selected_files=[0]`，`required_files=[0,1]`，`observations` 也含两个文件；这只检查 `b` 在共享分片内的字节，不能说明 `b` 的其余内容通过。v2 和经过布局校验的混合格式通常不需要相邻真实文件。缺失的所选空文件即使 `checked_pieces=0` 也必须失败。

混合格式的计数包含 SHA-1 与 SHA-256 两套检查，不能视为不同物理分片数。`details_truncated=true` 时汇总计数仍完整，但保存的失败片段不是全部问题清单。文件映射本身也不代表这些文件都已检查。

## 身份和有效范围

接收者可对手中的种子原始字节计算 SHA-256，并与 `metainfo_sha256` 比较，再根据文件映射、`complete`、选择/依赖集合和检查/跳过数解释结果。仅改 Tracker 仍保留 infohash，但完整 metainfo 摘要会改变，旧凭据只能对应修改前的精确输入。当前没有导入凭据并重新验证其内容的 API；哈希比较也不能证明普通 JSON 未被人修改。

凭据描述一次检查，不能证明载荷之后未改变，也不替代再次读取和哈希。没有可信时间戳、签名、发布者认证或按时间戳复用的核验缓存。未记录本机绝对路径、文件身份/时间令牌、Tracker、Web Seed 或注释；仍会包含种子名称和全部相对文件名，分享前按资料本身的权限处理。

## MoonBit API 与一致性

`verify_with_receipt(torrent, lengths, read, detail_limit=4096, selected_files=None)` 返回 `(VerificationReport, VerificationReceipt)`；`receipt_json_text(receipt)` 导出快照字符串。`VerificationReceipt` 字段私有，外部调用方不能用一份任意报告与另一份元数据手工组装它。

工厂先解析同一份种子并捕获完整摘要，复制调用方的大小映射，再执行原有核验流程；回调修改原始大小数组不会改写本次映射。返回前序列化结果，因此之后修改返回报告的数组也不会改变凭据。库依赖调用方提供稳定、真实的内容和大小；内存快照不构成不可信调用方的真实性保证。旧 `verify_payload`、JSON 和 HTML 接口继续可用。完整可运行示例见 `examples/library`，在 Wasm GC 和 JS 执行。

CLI 在读取载荷前检查所有指定输出：拒绝已有文件、经绝对路径规范化和大小写折叠后重复的目标、不存在的父目录，以及与任意列出载荷文件重叠的目标，包括未选择或缺失的文件。这个保守的路径比较可能拒绝区分大小写文件系统上的某些名称组合。

核验结束后先复查所需文件身份，再写凭据，最后写 HTML；检测到源文件变化时不写两种输出。每个文件都独占新建并完整写入，但多个输出不是一个原子事务：后一个输出遇到不可预见的 I/O 错误时，先前完整输出可能保留。路径和文件复查也是顺序检查，不能消除最终检查后的并发变化；交付时使用稳定源文件。

## 复现证据

双后端测试覆盖不可变快照、回调修改原始映射、全量/局部/失败、空文件和截断详情。真实文件互操作用 Python 计算完整 SHA-256，用 libtorrent 对照 infohash/文件布局，并验证三种模式、共享片邻居、错误输出保护与读后变化拦截。原有单遍读取观测也导出凭据，验证保存记录不会重复读取载荷，读取失败仍保存准确的失败结果。
