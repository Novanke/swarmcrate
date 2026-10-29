# 离线批量巡检：清单、隔离与身份绑定

从 0.12.0 起，`audit-batch` 用一份清单顺序核验多个发布包或镜像目录，将成功、损坏、缺失与无法执行的任务放在同一份可保存汇总中。无需逐个运行命令后手工拼接 stdout；一个任务的种子不可读、格式错误、选择无效或来源变化不会中断后续任务。业务逻辑、清单解析、调度、错误归类和汇总由 MoonBit 实现，Node 桥仅做 OS I/O。

## 使用

准备 `jobs.json`（以下路径替换为自己的实际文件）：

```json
{
  "schema": "swarmcrate.audit-manifest.v1",
  "tasks": [
    { "id": "release-linux", "metainfo": "seeds/linux.torrent", "payload": "mirror/linux" },
    { "id": "manual-only", "metainfo": "seeds/docs.torrent", "payload": "mirror/docs", "files": ["guide.pdf"] },
    { "id": "release-windows", "metainfo": "seeds/windows.torrent", "payload": "mirror/windows" }
  ]
}
```

```sh
moon build --target js --release --deny-warn
node scripts/swarmcrate.mjs audit-batch ./jobs.json ./audit-summary.json
```

相对输入以 **清单所在目录** 为基准，不取决于当前工作目录；绝对路径也可使用。清单内的 Windows `C:relative` / `C:` 形式依赖环境中的驱动器当前目录，因此拒绝，改用 `C:\absolute\path` 或普通相对路径。命令的清单路径及汇总输出路径仍按普通 CLI 的当前目录解释。单文件种子的 `payload` 指向文件，多文件种子指向包含元数据相对路径的目录。

`id` 必须唯一、非空、不含控制字符，UTF-8 长度不超过 128 字节。清单最大 1 MiB、JSON 深度最多 8、1..64 项；拒绝重复 JSON 键和未知字段，便于及时发现拼写错误。`metainfo` / `payload` 为非空字符串，各不超过 4096 UTF-8 字节。`files` 省略表示全量，存在时必须为非空路径数组；重复选择归一化，路径使用与 `inspect` 一致的 `/` 形式。路径在种子中不存在属于该任务的 `ERROR`。

## 状态和退出码

| 每项 `outcome` | 含义 |
| --- | --- |
| `PASS` | 全量范围核验通过，完成来源复查。 |
| `PARTIAL_PASS` | 所选范围通过，包含必要的 v1 邻居字节；不能代表整个载荷通过。 |
| `FAIL` | 已完成该范围核验，发现缺失、尺寸错误、哈希不一致或不可读分片。 |
| `ERROR` | 加载、解析、选择、观测或来源复查失败，或汇总预算不足以接受该结果；不保留候选核验结果或凭据摘要。 |

所有预定任务均尝试执行，结果保持清单顺序、原始任务索引和 ID。`pass_tasks`、`partial_pass_tasks`、`failed_tasks`、`error_tasks` 分别计数；`verified_tasks` 是被汇总接受的前三类数量。`all_tasks_processed=true` 只表示处理了所有任务，不能当作通过证明。`all_full_pass` 仅在每项都是全量 `PASS` 时为真。

`ok` 表示所有请求范围均成功，因此允许局部成功；`all_scopes_complete` 还要求每项都成功执行了完整范围，但不代表完整范围的哈希一定通过。整体 `outcome` 按 `ERROR`、`FAIL`、`PARTIAL_PASS`、`PASS` 的优先级确定。退出码：有 `ERROR` 为 **1**，否则有 `FAIL` 为 **2**，其余为 **0**（包含局部成功，与原 `verify` 一致）。有任务错误/损坏时仍保存完整汇总；清单/输出预检或最终保存失败时返回全局错误 JSON，不把候选汇总当作已保存结果。

## 身份与范围

`swarmcrate.audit-batch.v1` 顶层绑定原始清单字节的 SHA-256 和长度。每项绑定：

- 清单中的任务索引、ID，及被接受任务的请求选择；完整清单摘要也绑定了输入定位符和声明顺序。
- 实际加载种子原始字节的 SHA-256、长度；解析成功后再记录两套 infohash、名称和模式。
- 实际所选及必需文件索引，以及范围是否完整。这些索引只能按同项摘要对应的原始种子文件表解释，不能套用其他种子的文件顺序。
- 核验计数、文件尺寸问题数量、详情截断状态，以及同次不可变核验凭据的 SHA-256 和字节数。

即使只改 Tracker、infohash 没变，完整种子摘要仍不同；不会按 infohash 合并任务、复用检查或跳过重新读取。损坏种子若已加载可保留原始摘要，但不会虚构 infohash；无法加载时 `subject=null`。`ERROR` 项的 `scope`、`verification` 和 `receipt_sha256` 均为空，避免把来源变化前的候选 PASS 留作有效结果。

汇总不内嵌所有完整凭据、分片详情或文件诊断，`details_included=false`。需要定位具体文件及候选字节范围时，对相应清单项使用既有命令：

```sh
node scripts/swarmcrate.mjs verify ./seeds/docs.torrent ./mirror/docs --detail-limit 128 --diagnostics ./docs-files.json --receipt ./docs-receipt.json
```

摘要指向的是同次生成的凭据，默认详情上限 128（SDK 可设置）。摘要不是可下载附件、签名或发布者身份认证；之后重新核验的文件、范围、版本及详情上限均相同时，确定性序列化才可用于对照。重新运行不能证明过去文件状态。

## 保存保护和时间边界

读取载荷前，检查新汇总目标与清单、**所有任务**的种子路径及声明载荷根是否重叠；包括后面的、未选择、缺失及种子无法加载的任务。保守禁止在任意载荷根以内或其祖先位置保存汇总，已有目标不覆盖。父目录须已存在，输出使用暂存、完整写入/fsync/关闭、硬链接原子不覆盖发布；需要文件系统支持硬链接，不支持则失败。

每任务完成后复查其种子文件与 required payload 文件；变化将该项变为 `ERROR`，之后继续。发布汇总前再次复查清单，清单变化则整份不保存。这些是顺序一致性检查，**不是全批次同一时刻的原子快照**：早先完成的任务可能在后续任务运行期间再次改变。记录描述各任务完成时的观测。使用稳定镜像或文件系统快照可减少变化；本项目不创建 OS 快照。

强制终止或清理失败仍可能留下隐藏暂存目录；本操作不会发布半成品目标，不承诺断电持久性。多个任务顺序执行，不提供线程并发、异步存储、全批次进度/取消、断点恢复、自动修复或签名认证。

## SDK 与内存边界

`parse_batch_manifest(Bytes)` 生成不可外部构造的 `BatchManifest`；`batch_manifest_tasks` 返回副本。`audit_batch(manifest, load, observe, read, finish=Some(...))` 是纯 MoonBit：

- `load(taskIndex, taskCopy)` 返回元数据字节，核心在解析和回调前捕获原始身份。
- `observe(taskIndex, infoCopy, scopeCopy)` 仅观测 required 文件，返回与整个 inspected 文件表等长的 `Array[Int64?]`。
- `read(taskIndex, fileIndex, offset, length)` 返回指定真实文件块；普通读错作为不可读分片处理，后续片继续。
- `finish(taskIndex)` 在结果被接受前检查来源；抛 `CrateError` 只使该任务成为 `ERROR`。CLI 强制执行种子和载荷复查；纯 SDK 的存储稳定性由适配方负责，省略 `finish` 不产生磁盘稳定性保证。

任务定义及传出数组有快照保护；结果 `BatchAudit` 只提供不可变 JSON 文本和退出码。仅捕获声明的 `CrateError`，不掩盖程序 panic。

默认/最大汇总预算 16 MiB，可设置 `max_summary_bytes`，最低为 `(任务数+1)×4096`，预留后续错误行。某项超预算时用紧凑 `summary_limit` 错误行替代并继续，不能因大小不足丢掉后续项或保留 PASS。该预算限制序列化汇总，**不等于整个进程内存上限**：当前任务的元数据、哈希、报告和完整凭据仍会临时生成；不会累积所有完整凭据。

## 可运行证据

```sh
moon run examples/batch --target wasm-gc --release --deny-warn
moon run examples/batch --target js --release --deny-warn
moon run examples/batch_disk --target js --release --deny-warn
```

前两个展示无文件系统 SDK，后一个用真实合成文件演示清单目录基准、错误后继续及汇总保存，并清理自己创建的临时目录。它们故意包含失败项，示例自身会断言预期结果。核心回归覆盖三种格式、同 infohash 不同原始身份、大小/读取错误、回调修改、完成复查和汇总预算；MoonBit CLI 回归覆盖跨任务保护、来源/清单变化、已有及竞争输出。CI 在 Windows/Linux、Node 22.16.0/24 上执行。
