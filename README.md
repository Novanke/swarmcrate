# SwarmCrate

**基于 MoonBit 的离线 BitTorrent 元数据制作与文件完整性核验工具。**

SwarmCrate 直接读取本地文件或目录，生成可被 BitTorrent 客户端读取的 v1、v2 或混合格式 `.torrent` 和磁力链接；也能读取已有种子、核对实际文件，并把损坏分片映射到文件与字节偏移。可用于开源发布包制作、数据集交付、离线镜像巡检和已有种子的发布地址维护。

```text
真实文件/目录 → 分片读取 → MoonBit SHA-1/SHA-256 哈希 → .torrent + magnet
已有 .torrent + 真实文件 → 格式/布局/哈希核验 → JSON + 离线 HTML 报告
```

核心算法和命令处理由 MoonBit 实现，CLI 的 Node.js 适配层仅负责操作系统 I/O，不调用外部种子生成程序、系统哈希命令或网络服务。库可在 Wasm GC、JavaScript 后端使用，文件系统 CLI 需要 Node.js **22.16+**。没有下载、做种或 Tracker 服务功能。

长期按三条主线推进：**开源发布与数据集交付、离线镜像巡检、MoonBit 可复用 SDK**。优先级、下一项交付与验收标准见 [开发路线图](docs/ROADMAP.md)。

## 快速使用

安装官方 [MoonBit 工具链](https://www.moonbitlang.com/download/)，要求 **moonc ≥ 0.10.14**，本版验证使用 **0.10.16**；另安装 Node.js 22.16+。CI 会检查编译器版本下限。克隆后执行：

```sh
git clone https://github.com/Novanke/swarmcrate.git
cd swarmcrate
moon update
python scripts/check_toolchain.py  # 可选的本机版本检查；需要 Python 3
moon build --target js --release
node scripts/swarmcrate.mjs help
```

发布前可先只读规划，不打开载荷文件、不计算内容哈希，也不生成输出文件：

```sh
node scripts/swarmcrate.mjs plan ./release --mode hybrid --piece-length auto
```

规划显示真实字节、逻辑布局字节、虚拟补零、两套分片数、v1 哈希字节和 v2 分片层字节上限。`storage_bytes` 不等于磁盘占用或流量，哈希层上限不等于完整种子大小；最终格式/节点限制仍由实际创建校验。计划不能替代载荷核验。

制作真实目录的混合格式种子（Tracker 是可选项，示例地址不提供服务）：

```sh
node scripts/swarmcrate.mjs create ./release ./release.torrent --mode hybrid --piece-length 262144
node scripts/swarmcrate.mjs inspect ./release.torrent
node scripts/swarmcrate.mjs magnet ./release.torrent
node scripts/swarmcrate.mjs verify ./release.torrent ./release --html ./verification.html
node scripts/swarmcrate.mjs edit ./release.torrent ./release-new.torrent --tracker https://example.org/announce
```

`create` 输出 JSON，包含真实输出文件、内容标识和磁力链接。`verify` 输出逐片核验 JSON，可同时生成不依赖网络、脚本和外部样式的 HTML 报告。返回码 **0** 表示成功，**1** 表示输入或 I/O 错误，**2** 表示核验失败。损坏报告中的分片索引和文件偏移从零开始。

`create` 默认自动选择分片大小，也可显式使用 `--piece-length auto`；选择结果见输出的 `info.piece_length`。目标约 4,096 个分片，同时考虑 v2/混合格式的每文件对齐与硬上限。需要固定布局和内容标识时，传入明确的字节数。`create --help`、`verify --help` 等子命令可直接查看用法。

只复核资料包中的指定文件（可重复 `--file`，路径与 `inspect` 一致）：

```sh
node scripts/swarmcrate.mjs verify ./release.torrent ./release --file docs/manual.pdf --html ./manual-check.html
```

局部成功在 HTML 中标记为 **PARTIAL PASS**，JSON 的 `complete=false`，不能作为整个资料包通过的证明。v1 跨文件分片还需要相邻文件的部分字节；`required_files` 列出这些依赖。其他分片跳过读取和哈希；不指定 `--file` 则检查全部文件。v2 单片读取失败仅影响该片，后续分片仍会检查。

创建前会复查已扫描的文件和目录清单，空目录也参与检查；新增文件、移除或重命名目录等变化会中止创建，不写出新种子。枚举顺序变化不影响结果。检查仍是顺序执行，制作发布物时请使用稳定源目录。

单文件种子的 `PAYLOAD` 参数直接指向文件；多文件种子指向包含元数据所列相对路径的目录，不额外拼接种子名称。输出必须是新文件，CLI 不覆盖已有文件。`edit` 用所给参数**整体替换** Tracker 和 Web Seed 列表；修改后保留原始 `info` 字节，内容哈希不会改变。

可重复的完整演示：

```sh
node scripts/demo.mjs
# 再次演示时选择新的输出目录
node scripts/demo.mjs --output ./artifacts/demo-0.7.0
```

默认在 `artifacts/demo/` 生成合成演示文件、三种格式种子、正确与损坏核验报告，以及指定文件的局部校验报告；已有目录不会覆盖，可用 `--output` 指定新目录。演示目录不纳入源码统计或发布包。

## 在 MoonBit 工程中使用

```sh
moon add Novanke/swarmcrate@0.7.0
```

在消费方 `moon.pkg` 导入 `"Novanke/swarmcrate" @swarm`，然后调用：

```moonbit
let content = b"hello"
let options = {
  ..@swarm.create_options("hello.txt"),
  mode: @swarm.Hybrid,
  single_file: true,
}
let torrent = @swarm.create_torrent(
  [{ path: ["hello.txt"], length: 5L }], options,
  fn(_, offset, n) { content[offset.to_int():offset.to_int() + n].to_owned() },
)
let summary = @swarm.inspect_torrent(torrent)
println(@swarm.info_json(summary).stringify(indent=2))
```

调用方处理 `CrateError(code, detail)`。读取回调必须返回请求的完整字节，创建时的文件索引始终对应输入数组，库内部确定性排序不会改变回调映射。核验时的文件索引对应 `inspect_torrent(...).files`。见 [接口约定](docs/API.md) 和自动生成的 [公开接口](pkg.generated.mbti)。

仓库另有完整、可直接运行的纯 MoonBit 示例，无需准备文件或使用文件系统桥：

```sh
moon run examples/library --target wasm-gc --release --deny-warn
moon run examples/library --target js --release --deny-warn
```

示例依次规划并创建 v1、v2、混合种子，输出元数据、磁力链接和完整核验报告，再主动破坏内容并检查能否发现损坏。两个后端都由 CI 实际执行。消费方包的导入方式与示例的 `moon.pkg` 相同。

## 已实现

- 纯 MoonBit 的 `plan_torrent` / `plan_json` 和只读 CLI `plan`；创建复用规划预检，在读取载荷前拒绝超限布局。
- 有界、规范 bencode 编解码，保留原始字节区间，拒绝重复/未排序字典键、非规范整数、截断、超深与过大输入。
- v1 跨文件 SHA-1 分片，v2 16 KiB 区块 Merkle 树、零哈希补齐及认证分片层。
- v1/v2/混合格式创建与严格读取；混合格式使用虚拟补零，并核对两种格式的路径、顺序、长度和对齐一致性。
- 读取独立 v1 的 BEP 47 补零条目，以虚拟零字节参与核验，不需要磁盘上的 `.pad` 文件；局部核验和损坏定位始终使用真实文件索引。
- 所有创建模式只读取一次真实载荷；v2 读取按片边界合并为不超过 1 MiB 的请求，Merkle 叶子仍严格为 16 KiB；多文件树使用目录索引构建。
- 文件大小、缺失、读取异常、损坏分片及文件偏移报告；混合格式在一次真实读取中分别核验两套预期哈希，短片的虚拟补零不读磁盘。读取失败同时影响该片的两套检查，之后的分片继续检查。
- SHA-1 十六进制/Base32、SHA-256 multihash 磁力链接解析与输出，UTF-8 百分号编码。
- Tracker 分层、Web Seed、私有标志、注释，以及保留 `info` 精确字节的分发地址编辑。
- 文件扫描、分段读取、源文件与目录清单复查（含空目录）、拒绝符号链接和特殊文件、独占创建输出。创建期间的新增、移除、重命名与目录替换会触发错误，停止写出过时元数据。
- 无损尺寸字符串 JSON、离线 HTML 核验报告和六个真实文件命令。

## 验证与规模

```sh
moon fmt --check
moon info
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon build --target js --release --deny-warn
python scripts/source_audit.py
python -m pip install libtorrent==2.1.1 torf==4.3.1
python scripts/interop.py --cli _build/js/release/build/cmd/main/main.js
```

当前有 **27 个核心测试块**，JS 加文件系统/CLI 测试共 **34 个测试块**。独立互操作脚本通过 **156 个真实文件场景**，涵盖 libtorrent 接收输出、反向读取 libtorrent 生成的数据、torf 校验 v1、Python 独立 SHA-1/Merkle 根、损坏/缺失/截断、磁力链接、编辑保持身份、三种格式的局部校验、自动分片，超过 1 MiB 的批量读取与末片补齐，以及独立 v1 补零、尾部补零、部分文件未对齐时的邻居依赖和损坏定位。还覆盖真实 OS 读取计数、混合核验单遍读取、1 MiB 内部读取失败后的继续检查，以及三种格式的目录变化拦截、稳定/乱序对照、内容标识保持与目录句柄关闭。规划测试禁止打开载荷，且用实际种子的独立解码对照所有计划计数。

仅根目录自写库代码：**2,532 行非空非注释源码，1,610 行保守函数体统计**；已排除测试、文档、生成接口、依赖、CLI、基准程序和 JS 桥接。该统计是透明复核材料，不替代主办方计数。实际功能提交见 [实现记录](docs/implementation-record.md)，版本变化见 [更新记录](CHANGELOG.md)。

混合核验的 8 MiB + 3 字节合成对照中，相比注册表 0.4.0，读取量从 16,777,222 降至 8,388,611 字节，回调次数由 66 降至 33，两套哈希检查仍共 66 次。该结果说明读取量减少，不等于 CPU 哈希工作减半；性能对照与复现方式见 [基准说明](docs/performance.md)。验收项与仓库证据的对应关系见 [验收自查](docs/review-readiness.md)，关键原理与取舍见 [设计说明](docs/design.md)。

## 范围和资源边界

元数据最大 16 MiB、深度 64、20 万 bencode 节点；文件系统扫描最多 200,000 个后代条目（文件与目录合计，不含输入根目录），按剩余预算逐项枚举并在超限时停止；真实文件集合最多 65,536 个文件、32 层路径，独立 v1 的存储条目上限 65,536 包括补零；总字节数最多 `2^53-1`，分片最多 400,000；分片大小为 16 KiB 至 16 MiB 的二次幂。载荷必须至少包含一个非空文件，可以同时包含空文件。哈希按块/片读取，不把整个载荷装入内存。元数据、分片哈希和有界诊断保存在内存中。

采用可移植安全路径子集：拒绝遍历、Windows 设备名、大小写冲突、文件/目录冲突和保留 `.pad` 源路径。读取已有种子时对不受支持的路径、文件属性和符号链接明确报错，不尝试静默改名。独立 v1 补零只支持 `attr="p"` 且必须填满已有的未满分片，可有尾部补零；补零路径可省略，存在时仍检查安全组件。其他属性组合及符号链接明确拒绝，详细兼容范围见接口约定。支持 HTTP(S) Tracker/Web Seed 和 UDP Tracker；不接收 URL 用户凭据或片段。只处理 BitTorrent 元数据与文件核验，不提供签名认证、网络传输、下载续传或完整客户端功能。

## 来源、原创性和许可证

这是遵循 [BEP 3](https://www.bittorrent.org/beps/bep_0003.html)、[BEP 52](https://www.bittorrent.org/beps/bep_0052.html)、[BEP 47](https://www.bittorrent.org/beps/bep_0047.html)、[BEP 9](https://www.bittorrent.org/beps/bep_0009.html) 的独立工程实现，不宣称发明 BitTorrent 或哈希算法。SHA-1/SHA-256 来自官方纯 MoonBit 包 `moonbitlang/x/crypto@0.5.5`，依赖源码不计入本项目代码量。libtorrent 和 torf 仅用于独立测试，不参与运行时输出。

功能与作者已有的 QuireLoom 拼版库、moonmorph JSON 迁移工具不同；公开生态检索范围与相关项目见 [方向核对记录](docs/ecosystem-check.md)。代码、测试和文档由 AI 辅助编写并执行验证，使用前可依据源码和复现步骤审阅。

Apache-2.0，见 [LICENSE](LICENSE) 和 [依赖与来源说明](THIRD_PARTY.md)。后续供评审使用的功能更新须同步发布 Mooncakes 新版本，见 [发布流程](docs/releasing.md)。
