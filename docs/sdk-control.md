# SDK 核验进度与协作取消

从 0.10.0 起，`verify_with_control(torrent, sizes, read, on_progress, ...)` 在原有核验、凭据和按文件诊断之上提供同步的进度回调。它返回同样的 `(VerificationReport, VerificationReceipt)`，原核验 API、CLI 标准输出和凭据格式保持兼容。

```moonbit
let (report, receipt) = @swarm.verify_with_control(
  torrent, sizes, read,
  fn(progress) {
    // 示例：在第一次完整读取回调结束后取消。
    !(progress.phase == "after_read" && progress.read_calls >= 1)
  },
)
```

回调返回 `false` 时抛出 `CrateError("cancelled", ...)`，该调用不返回报告或凭据。调用者处理此分支，不应把它当成文件损坏或完整核验失败报告。回调也可抛出自己的 `CrateError`，其代码、详情会传出，不会被分片读取异常处理吞掉。

## 检查点与进度快照

`VerificationProgress` 只有标量和可选标量字段，收到的是当次快照，外部不能通过事件数组改写内部范围或计数。

| `phase` | 含义与可取消位置 |
| --- | --- |
| `start` | 元数据、选择、映射和参数已校验，尚未读取载荷。此处取消不会调用载荷读取回调。 |
| `before_read` | 即将请求一个真实数据块，`file` / `offset` / `length` 有值；尚未增加本次 `read_calls`。 |
| `after_read` | 一次真实读取尝试结束，`read_ok` 表示是否返回了完整的正确长度；取消会在处理下一块或形成该片结论前传出。 |
| `check` | 完成一次哈希比较，计数已更新。大小不符或不可用文件也可在没有实际读取时产生检查进度。 |
| `finalize` | 所选检查均已结束，尚未构造并返回不可变凭据；此处仍可取消。只有 API 成功返回后，才可保存其返回值。 |

`total_checks` 只统计所选范围需要执行的哈希检查，`checked_pieces` 从零单调增加，最终与报告相等。混合格式每个物理片有两套检查；最终诊断仍维持原有 SHA-1、SHA-256 分组顺序，进度则按实际比较顺序通知。

`failed_pieces` 包含不可读检查；`unreadable_pieces` 单独计数。检查达到 100% 不表示通过，更不表示文件已保存。所选空文件可使 `total_checks=0`，但其缺失仍会导致最终失败，不应直接除以零或将零片解释为成功。

`read_calls` 是真实数据读取回调的尝试次数，不是 OS 系统调用次数。`validated_read_bytes` 只累计完整、长度正确的返回数据；部分读取、异常、元数据读取和虚拟补零不计入。它不是磁盘流量或已认证字节数。真实读取请求仍不超过 1 MiB，原有单遍混合核验保持不变。

`complete_scope`、`selected_file_count`、`required_file_count` 描述选择范围，包含所选空文件及 v1 必需邻居；范围完整与结果通过仍是不同概念。读取事件的文件索引对应 `inspect_torrent(...).files`。非读取事件的 `file` / `offset` / `length` / `read_ok` 均为空。

## 取消、异常与宿主责任

取消和观察者异常通过独立控制状态保留，在内层读取/哈希异常被处理后立即重新传出。普通 `read` 回调异常仍按照原规则记录不可读分片并继续，即使它的错误代码恰好叫 `cancelled`。只有进度回调的返回值或异常决定控制中止。

取消发生在检查点，不会抢占正在执行的读取、元数据解析、哈希计算或凭据序列化，也不回滚调用方自定义回调的副作用。当前 API 是同步的；同一 JS 主线程上，普通 DOM 事件不能在它执行期间抢占代码。异步存储、浏览器 Worker 适配、超时/信号接入和断点恢复仍未实现。取消后重新调用是一次全新的核验，不能把上次进度当作缓存通过。

库本身不操作文件系统。宿主应保证读取稳定、关闭句柄，成功返回后复查来源再独占保存输出。取消或回调错误时，不保存完整凭据。这个协议不创建原子文件系统快照，也不认证发布者。

## 可运行消费方

本节描述核验控制。0.11.0 另提供独立的创建控制与受控磁盘发布接口，见 [创建进度与取消](creation-control.md)；核验进度类型不用于冒充创建完成，异步/浏览器宿主适配及恢复仍属后续范围。

纯 MoonBit 示例在两个后端实际执行：

```sh
moon run examples/controlled --target wasm-gc --release --deny-warn
moon run examples/controlled --target js --release --deny-warn
```

它先观察一个完整核验，再在一次全新调用的首个读取后取消。Node 单文件消费方示例 `examples/controlled_io` 使用公共 `host` API，在核验成功返回及来源复查后才调用 `write_new`：

```sh
moon build --target js --release --deny-warn
node _build/js/release/build/examples/controlled_io/controlled_io.js input.torrent payload.bin new-receipt.json full
node _build/js/release/build/examples/controlled_io/controlled_io.js input.torrent payload.bin cancelled.json cancel-read
python scripts/control_interop.py
```

该示例的退出码 3 表示取消；0/2 为已完成的成功/失败检查，1 为输入、I/O 或观察者错误。演示控制方式还包括 `cancel-start`、`cancel-check`、`cancel-finalize` 与 `observer-error`。这不是为现有 CLI 增加全局信号处理；其用途是复现 SDK 的宿主集成契约。

测试覆盖全部阶段的返回值取消和观察者异常、普通读错与短读、大小不可用和空选择、全量/局部范围、单调计数、混合格式去重读取、最终阶段取消不落盘、已有输出保护及读后变化拦截。检查计数完成仍不产生取消凭据的情况，也由真实文件消费方验证。
