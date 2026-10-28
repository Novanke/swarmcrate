# 创建进度、取消与完整种子发布

从 0.11.0 起，纯 MoonBit SDK 提供 `create_torrent_with_control(files, options, read, on_progress)`。回调返回 `false` 时抛出 `CrateError("cancelled", ...)`，观察者或读取异常也直接传出，本次调用不返回任何种子字节。旧 `create_torrent` 保持原签名与格式。

```moonbit
let torrent = @swarm.create_torrent_with_control(files, options, read, fn(event) {
  // 全部载荷已读完，但尚未编码；取消仍然有效。
  event.phase != "before_encode"
})
```

创建预检先验证路径、参数和资源上限，再复制调用方的文件路径及 Tracker/Web Seed 数组，之后才触发回调。文件索引仍指向原始输入顺序，内部规范排序不改变读取映射。混合格式仍只读取一遍真实载荷。

## 检查点与快照

| `CreationProgress.phase` | 含义 |
| --- | --- |
| `start` | 布局预检完成，尚未读取载荷。 |
| `before_read` | 即将读取一个真实块，`file` / `offset` / `length` 有值，本次调用尚未计入 `read_calls`。 |
| `after_read` | 一个正确长度的数据块已返回，读取次数与 `validated_read_bytes` 已更新；该事件只用于成功读取。 |
| `before_encode` | 哈希和布局组件已形成，尚未编码种子。读取字节数可已达到 100%，但创建尚未完成。 |
| `finalize` | 种子已经编码并通过完整解析/布局校验，尚未返回字节；此处仍可取消，`metainfo_bytes` 有值。 |
| `before_write` | 仅由受控 CLI 适配器发出：源快照已复查，尚未创建暂存区或目标。这是磁盘发布的最后取消点。 |

`mode`、`file_count`、`total_bytes` 描述本次固定计划；文件数包含空文件，字节数只含真实内容。虚拟补零、Merkle 零哈希和种子大小不计入读取进度。`read_calls` 统计截至该快照已开始的读取回调；读取失败立即抛错，没有后续成功读取事件，最后一份快照不能当作错误发生后的最终统计。

所有真实读取请求不超过 1 MiB。`validated_read_bytes` 表示完整返回的数据，不表示哈希、编码、文件保存或未来完整性已经完成。非读取事件的文件/偏移/长度为空；`metainfo_bytes` 仅在最终化及磁盘写入前有值。快照只有标量字段，不暴露内部可变数组。

与核验不同，创建过程不把读取错误记录为不可读分片后继续：错误、短读和超长返回都会立即终止，保留错误代码/详情。调用方自定义回调的副作用不回滚。

## 受控命令与安全发布

JavaScript 宿主可调用 `Novanke/swarmcrate/cli.execute_create_with_control(args, callback)`；`args` 包含 `"create"` 以及原有路径和创建选项。成功输出与普通 `create` 一致，取消返回代码 3，其他错误为 1。现有 `execute(args)` 接口和普通 CLI 的退出码保持兼容。

适配器先扫描和校验输入、拒绝已有目标或不存在的父目录，再执行受控创建。返回有效种子后复查扫描快照，发出 `before_write`，回调成功后再次复查，以检测观察者自身新增/修改源文件的情况。取消或观察者错误在开始写入前结束，不创建目标或暂存区。

受控路径使用新的 `host.write_new_atomic`：

1. 在目标父目录新建随机 `.swarmcrate-*` 暂存目录，以独占方式写入其中的 `data` 文件。
2. 完整写入、`fsync` 并关闭文件后，以硬链接原子创建目标名称，不替换已有文件。
3. 清理本次暂存文件和空目录；写入、同步或链接失败时也尝试清理，始终不删除已有或竞争者创建的目标。

此原语要求同一文件系统支持硬链接，已在 Windows NTFS 和 Linux CI 环境验证。不支持时明确失败，不退回会暴露半成品目标的直接写入。它是新增的可选 API；旧 `write_new` 和普通创建路径不增加这项文件系统要求。

开始发布后不再调用可取消回调，避免把已提交的完整文件报告为协作取消。模拟进程在暂存写入中退出时，目标不存在；在链接提交后退出时，目标已完整。强制终止或清理失败可能留下隐藏暂存目录，不能承诺崩溃后没有任何临时数据；只应在确认原操作已结束且暂存区属于自己时清理。该机制不保证断电后的目录持久性，也不构成源文件系统的原子快照。

创建控制是同步检查点，不抢占扫描、规划、阻塞 I/O、哈希或编码；CLI 扫描位于 `start` 之前。浏览器事件循环/Worker、信号适配和断点恢复仍未实现。不要把同一 JS 主线程上的普通 UI 事件当作执行中的抢占取消。

## 实际运行和故障验证

```sh
moon run examples/create_controlled --target wasm-gc --release --deny-warn
moon run examples/create_controlled --target js --release --deny-warn
moon build --target js --release --deny-warn
node _build/js/release/build/examples/create_controlled_io/create_controlled_io.js full create ./payload ./new.torrent --mode hybrid
node _build/js/release/build/examples/create_controlled_io/create_controlled_io.js cancel-before_write create ./payload ./cancelled.torrent
python scripts/creation_interop.py
```

Node 消费方把进度 JSON 写到 stderr，stdout 保持命令结果。演示支持 `cancel-PHASE` 和 `error-PHASE`，用于复现各检查点，适用于文件或目录。

双后端测试对照原有创建字节、原始索引、单遍读取、全部阶段取消/错误、无效预检及输入数组冻结。78 个真实文件场景覆盖三种格式、单/多文件、最后写入点取消、观察者错误、源清单变化、已有目标、读错、部分/零写入、同步和链接失败、竞争目标，以及发布前后模拟进程中断。父进程确认本操作未发布半成品种子，并验证成功输出；已有或竞争目标逐字节保留，不把其他写入者的内容声明为有效种子。
