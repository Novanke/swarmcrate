# SwarmCrate

**基于 MoonBit 的离线 BitTorrent 元数据制作与文件完整性核验工具。**

SwarmCrate 直接读取本地文件或目录，生成可被 BitTorrent 客户端读取的 v1、v2 或混合格式 `.torrent` 和磁力链接；也能读取已有种子、核对实际文件，并把损坏分片映射到文件与字节偏移。可用于开源发布包制作、数据集交付、离线镜像巡检和已有种子的发布地址维护。

```text
真实文件/目录 → 分片读取 → MoonBit SHA-1/SHA-256 哈希 → .torrent + magnet
已有 .torrent + 真实文件 → 格式/布局/哈希核验 → JSON + 离线 HTML 报告
```

核心算法和命令处理由 MoonBit 实现，CLI 的 Node.js 适配层仅负责操作系统 I/O，不调用外部种子生成程序、系统哈希命令或网络服务。库可在 Wasm GC、JavaScript 后端使用，文件系统 CLI 需要 Node.js **22.16+**。没有下载、做种或 Tracker 服务功能。

## 快速使用

安装官方 [MoonBit 工具链](https://www.moonbitlang.com/download/)，并安装 Node.js。克隆后执行：

```sh
git clone https://github.com/Novanke/swarmcrate.git
cd swarmcrate
moon update
moon build --target js --release
node scripts/swarmcrate.mjs help
```

制作真实目录的混合格式种子（Tracker 是可选项，示例地址不提供服务）：

```sh
node scripts/swarmcrate.mjs create ./release ./release.torrent --mode hybrid --piece-length 262144
node scripts/swarmcrate.mjs inspect ./release.torrent
node scripts/swarmcrate.mjs magnet ./release.torrent
node scripts/swarmcrate.mjs verify ./release.torrent ./release --html ./verification.html
node scripts/swarmcrate.mjs edit ./release.torrent ./release-new.torrent --tracker https://example.org/announce
```

`create` 输出 JSON，包含真实输出文件、内容标识和磁力链接。`verify` 输出逐片核验 JSON，可同时生成不依赖网络、脚本和外部样式的 HTML 报告。返回码 **0** 表示成功，**1** 表示输入或 I/O 错误，**2** 表示核验失败。损坏报告中的分片索引和文件偏移从零开始。

单文件种子的 `PAYLOAD` 参数直接指向文件；多文件种子指向包含元数据所列相对路径的目录，不额外拼接种子名称。输出必须是新文件，CLI 不覆盖已有文件。`edit` 用所给参数**整体替换** Tracker 和 Web Seed 列表；修改后保留原始 `info` 字节，内容哈希不会改变。

可重复的完整演示：

```sh
node scripts/demo.mjs
```

会在 `artifacts/demo/` 生成演示文件、三种格式种子、正确与损坏核验报告。该目录不纳入源码统计或发布包。演示会使用新的临时工作区，不改动用户文件。

## 在 MoonBit 工程中使用

```sh
moon add Novanke/swarmcrate@0.1.0
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

## 已实现

- 有界、规范 bencode 编解码，保留原始字节区间，拒绝重复/未排序字典键、非规范整数、截断、超深与过大输入。
- v1 跨文件 SHA-1 分片，v2 16 KiB 区块 Merkle 树、零哈希补齐及认证分片层。
- v1/v2/混合格式创建与严格读取；混合格式使用虚拟补零，并核对两种格式的路径、顺序、长度和对齐一致性。
- 文件大小、缺失、读取异常、损坏分片及文件偏移报告；混合格式同时核验两套哈希。
- SHA-1 十六进制/Base32、SHA-256 multihash 磁力链接解析与输出，UTF-8 百分号编码。
- Tracker 分层、Web Seed、私有标志、注释，以及保留 `info` 精确字节的分发地址编辑。
- 文件扫描、分段读取、源文件变更检测、拒绝符号链接和特殊文件、独占创建输出。
- 无损尺寸字符串 JSON、离线 HTML 核验报告和五个真实文件命令。

## 验证与规模

```sh
moon fmt --check
moon info
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon build --target js --deny-warn
python scripts/source_audit.py
python -m pip install libtorrent==2.1.1 torf==4.3.1
python scripts/interop.py
```

当前有 **11 个核心测试块**，JS 加文件系统/CLI 测试共 **13 个测试块**。独立互操作脚本通过 **67 个真实文件场景**，涵盖 libtorrent 接收输出、反向读取 libtorrent 生成的数据、torf 校验 v1、Python 独立 SHA-1/Merkle 根、损坏/缺失/截断、磁力链接和编辑保持身份。

仅根目录自写库代码：**2,002 行非空非注释源码，1,265 行保守函数体统计**；已排除测试、文档、生成接口、依赖、CLI 和 JS 桥接。该统计是透明复核材料，不替代主办方计数。实际功能提交见 [实现记录](docs/implementation-record.md)。

## 范围和资源边界

元数据最大 16 MiB、深度 64、20 万 bencode 节点；文件集合最多 65,536 个文件、32 层路径；总字节数最多 `2^53-1`，分片最多 400,000；分片大小为 16 KiB 至 16 MiB 的二次幂。载荷必须至少包含一个非空文件，可以同时包含空文件。哈希按块/片读取，不把整个载荷装入内存。元数据、分片哈希和有界诊断保存在内存中。

采用可移植安全路径子集：拒绝遍历、Windows 设备名、大小写冲突、文件/目录冲突和保留 `.pad` 源路径。读取已有种子时对不受支持的路径、文件属性和符号链接明确报错，不尝试静默改名。支持 HTTP(S) Tracker/Web Seed 和 UDP Tracker；不接收 URL 用户凭据或片段。只处理 BitTorrent 元数据与文件核验，不提供签名认证、网络传输、下载续传或完整客户端功能。

## 来源、原创性和许可证

这是遵循 [BEP 3](https://www.bittorrent.org/beps/bep_0003.html)、[BEP 52](https://www.bittorrent.org/beps/bep_0052.html)、[BEP 47](https://www.bittorrent.org/beps/bep_0047.html)、[BEP 9](https://www.bittorrent.org/beps/bep_0009.html) 的独立工程实现，不宣称发明 BitTorrent 或哈希算法。SHA-1/SHA-256 来自官方纯 MoonBit 包 `moonbitlang/x/crypto@0.5.5`，依赖源码不计入本项目代码量。libtorrent 和 torf 仅用于独立测试，不参与运行时输出。

功能与作者已有的 QuireLoom 拼版库、moonmorph JSON 迁移工具不同；公开生态检索范围与相关项目见 [方向核对记录](docs/ecosystem-check.md)。代码、测试和文档由 AI 辅助编写并执行验证，使用前可依据源码和复现步骤审阅。

Apache-2.0，见 [LICENSE](LICENSE)。后续供评审使用的功能更新须同步发布 Mooncakes 新版本，见 [发布流程](docs/releasing.md)。
