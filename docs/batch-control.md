# 批量进度、全局取消与完整汇总发布

从 0.13.0 起，`audit_batch_with_control` 为离线批量巡检提供同步进度与协作取消。原 `audit_batch`、普通 `audit-batch` 命令、汇总格式和任务错误隔离继续兼容。

## SDK

```moonbit
let audit = @swarm.audit_batch_with_control(
  manifest, load, observe, read,
  fn(event) { event.phase != "finalize" },
  finish=Some(check_storage),
)
```

回调返回 `false` 时抛 `CrateError("cancelled", ...)`；回调抛出的 `CrateError` 保留 code/detail。两者都终止 **整个批次**，不返回 `BatchAudit` 或已完成任务的候选汇总。即使所有任务已完成、候选 `all_full_pass=true`、汇总已序列化，最后检查点仍可取消。

进度错误通过私有状态记录来源，在单任务错误捕获后重新检查，不会被降级成一个任务 `ERROR` 后继续。普通存储错误即使名为 `cancelled`，仍沿用原语义：加载/观测/完成复查错误使该项 `ERROR`；普通读取错误成为不可读分片 `FAIL`，之后任务继续。区分错误来源，而非仅比较错误代码。

## 检查点

| `BatchProgress.phase` | 含义 |
| --- | --- |
| `start` | 全局参数已校验，尚未加载任务元数据。清单解析发生在此前。 |
| `before_task` | 即将开始某任务，尚未调用其 loader。 |
| `after_load` | 有界元数据字节已加载，尚未解析/哈希身份。 |
| `before_observe` | 元数据和选择已解析，即将观测 required 文件尺寸。 |
| `verification` | 单任务的核验检查点，嵌套 `verification` 含 start、before/after_read、check、finalize 及计数。 |
| `before_finish` | 核验及同次凭据形成，尚未调用来源完成复查。 |
| `task_complete` | 本项已接受为最终结果行，包括 `summary_limit` 降级后的 ERROR；此处取消仍不返回整批结果。 |
| `before_summary` | 所有任务处理完，尚未序列化汇总。 |
| `finalize` | 汇总已序列化并通过字节预算检查，尚未返回。 |
| `before_write` | 仅受控 CLI 适配器发出，尚未创建暂存区/目标，是磁盘发布最后取消点。 |

快照没有可变数组，嵌套 `VerificationProgress` 也只有不可变值。`manifest_sha256` 标识此批次；任务内事件带索引/ID，`task_outcome` 仅在 `task_complete` 有值。全局事件的任务和核验字段为空。

`completed_tasks` 统计已接受的结果行，包含 PASS、PARTIAL_PASS、FAIL 和 ERROR；四类计数之和与它相同。**完成不等于通过，也不等于已返回或已保存。** 进度 JSON 使用独立 schema `swarmcrate.batch-progress.v1`，没有 `all_full_pass` 证书字段。消费方只应接受正常返回并成功保存的最终汇总；取消/异常应使 UI 的进度结果失效。

累计 `read_calls` 统计实际开始的载荷读取回调，`validated_read_bytes` 仅累计完整正确返回的字节，不包含元数据读取、失败/短读的实际 OS 流量、虚拟补零、编码或写盘。每任务核验计数重置，全批次按其增量累加，不把上一任务的读取再次相加。后续元数据尚未加载时不存在可靠的全批次总字节分母；不伪造百分比。两项相同输入仍重新核验，各自读取均计入总量。

## 受控磁盘命令

JS 宿主可调用 `Novanke/swarmcrate/cli.execute_batch_with_control(args, callback)`，其中 `args` 包含 `"audit-batch"`、清单和新汇总路径。正常完成沿用原 0/1/2 结果；全局取消返回 **3**，其他全局异常为 **1**。取消/全局异常的 stdout 只有错误 JSON，不返回候选 `tasks` 或 `all_full_pass`，目标和暂存区尚未创建。

原有跨任务输入保护先于所有回调执行。输出在入口即固定为预检的绝对路径，观察者切换当前工作目录不会改变写入位置；受控创建也补齐同样的保护。普通任务内来源复查失败继续隔离；成功的 `task_complete`、`before_summary`、`finalize` 回调返回后，受控适配器额外复查当前已完成任务的来源。若观察者自身使其失效，整批发布中止。回调为 false 时优先按取消处理，不尝试回滚调用方的副作用。

核心返回候选汇总后，复查清单、发出 `before_write`，回调成功后再复查清单和当前来源，随后才进入既有暂存/fsync/关闭/原子不覆盖发布。发布开始后 **不再发可取消回调**，避免把已提交的完整文件报告为取消。已有/竞争目标不覆盖。

这仍是各任务完成时的顺序观测，不是全批次原子快照。不会保留所有旧任务的完整文件快照，也不承诺最后一刻重查所有旧载荷；更早完成的任务在后续时间可以改变。纯 SDK 的存储稳定性由 `finish` 适配方负责，未提供 `finish` 时没有磁盘复查保证。

## 运行示例

```sh
moon run examples/batch_controlled --target wasm-gc --release --deny-warn
moon run examples/batch_controlled --target js --release --deny-warn
moon build --target js --release --deny-warn
node _build/js/release/build/examples/batch_controlled_io/batch_controlled_io.js full audit-batch jobs.json summary.json
node _build/js/release/build/examples/batch_controlled_io/batch_controlled_io.js cancel-before_write audit-batch jobs.json cancelled.json
node _build/js/release/build/examples/batch_controlled_io/batch_controlled_io.js --cancel-file ./cancel.flag audit-batch jobs.json cancel-file-summary.json
python scripts/batch_control_interop.py
```

文件消费方将 `batch_progress_json(event)` 写到 stderr，stdout 留给最终结果。演示支持 `cancel-PHASE` / `error-PHASE`；嵌套核验用 `verification/after_read` 等名称。

实际运行可选 `--cancel-file`：开始前使用一个不存在、位于载荷外且不同于汇总的新标记路径；另一终端在同一目录创建 `cancel.flag`（PowerShell：`New-Item -ItemType File ./cancel.flag`，POSIX：`touch ./cancel.flag`）。适配器在每个检查点查询固定的绝对标记路径，路径出现就返回 false；即使文件读取已经完成，最后写入门槛仍检查它。标记由调用方管理，程序不删除它；查询失败会中止发布。该方式不依赖同一 JS 线程接收异步事件，也不抢占阻塞 I/O。

## 实际保证与边界

- 所有核心检查点、最后一项计数已完成、序列化后和写入前取消，都验证不返回/保存汇总；读取错误恢复中的观察者失败也会终止整批。
- 48 个真实子进程场景覆盖三种格式的成功、取消、观察者异常、最后回调修改来源/清单，以及暂存写入、同步、关闭、链接失败、竞争输出和发布前后强制退出。
- 协作取消在发布前结束，因此不会留下本操作的半成品汇总。强制杀进程不是协作取消：暂存中退出可能留下隐藏暂存目录，目标不存在；提交后退出可能留下完整且有效的汇总。已有或竞争者的文件逐字节保留，不保证竞争者写的是合法 JSON。不承诺断电目录持久性。
- 回调是同步检查点，不能抢占 loader、尺寸扫描、阻塞 I/O、哈希或序列化。普通浏览器 UI 事件、Ctrl-C 信号适配、异步存储、Worker 和断点恢复尚未实现。调用方自行写文件的副作用不由 SDK 回滚。

0.14.0 为新发布暂存增加本机所有权记录、只读识别和指定单个孤立操作的保守清理；正式汇总不删除，旧版/无记录或未知内容保留。见[暂存识别与安全清理](staging-cleanup.md)。
