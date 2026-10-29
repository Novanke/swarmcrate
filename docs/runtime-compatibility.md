# 运行环境、I/O 故障与独立复现

SwarmCrate 的根库支持 MoonBit Wasm GC 与 JS；磁盘适配和 CLI 使用 Node.js，最低兼容基线为 [22.16.0](https://nodejs.org/en/blog/release/v22.16.0)。最低兼容测试不是要求用户固定使用旧版本；CI 同时覆盖 Node 24。编译器仍要求稳定 moonc ≥ 0.10.14。

## 0.11.1 修复的实际问题

- SDK 的 `sha1_pieces` 过去会在读取很多内容后才拒绝第 400,001 个分片。现在先验证路径、分片宽度和总分片数，再创建缓冲区及调用读取回调。16 KiB 分片下，6,553,600,000 字节恰好允许，增加一个字节就提前返回 `limit`。回归使用首次读取即抛错的回调，不创建或读取巨型文件。
- 过去普通读取/写入在 `finally` 中关闭文件；关闭抛错会越过 I/O 错误转换，CLI 可能退出且不输出 JSON。现在关闭发生在成功返回之前，失败转换为 `CrateError("io", detail)`；核验将其视为不可读分片，继续检查后续分片。普通输出写入失败清理本操作的输出，原子创建在关闭成功前不链接目标。
- 本机 Windows NTFS 的 Node 22.16.0 实测：同一文件的 `lstat.dev=0`，`fstat.dev` 为卷编号，inode、大小和纳秒时间相同。旧代码因设备字段不同而拒绝稳定输入。现在 Windows 使用路径观测到的设备字段比较句柄的其他身份字段，并另行核对路径快照；设备字段可用时仍比较它。Linux 保留完整句柄字段。没有删除大小、inode、时间或完成前来源复查，也没有为只读规划增加载荷打开操作。

关闭失败可能意味着操作系统已经释放句柄；实现先放弃本次句柄所有权再关闭，不重试可能被复用的编号。故障测试在真实关闭后注入异常，验证没有二次关闭。不能据此承诺所有 OS 关闭失败都必定释放资源，也不把正常文件系统检查宣称为原子快照。

## 可复现链路

在一个全新检出目录，按 README 的安装、构建和示例顺序执行。实际磁盘测试依赖 Python 3；独立互操作额外安装固定测试依赖：

```sh
node --version
python scripts/check_toolchain.py
moon update
moon info
moon fmt --check
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon build --target js --release --deny-warn
node scripts/demo.mjs --output ./artifacts/runtime-check
python -m pip install libtorrent==2.1.1 torf==4.3.1
python scripts/interop.py --cli _build/js/release/build/cmd/main/main.js
python scripts/control_interop.py
python scripts/creation_interop.py
python scripts/io_faults.py
```

替换 PATH 中的 Node 即可测试其他版本；三个 Python 控制/故障脚本也支持 `--node /absolute/path/to/node`。`io_faults.py` 的 21 个场景分别覆盖三种格式的成功基准、种子读取关闭失败、创建读取关闭失败、核验读取关闭失败及后续片继续、普通种子输出关闭失败、凭据输出关闭失败、原子暂存关闭失败。它只操作新建的合成临时文件，不修改用户数据。

CI 在 Windows/Linux × Node 22.16.0/24 上执行相同测试链路及双后端可移植示例。发布后另在全新消费工程安装精确 Mooncakes 版本，实际调用公共 API 并与发布档案核对；本文件不代替对应 Git 提交的公开 CI 和精确版本下载证据。

## 后续有价值但尚未交付的方向

0.12.0 已交付[离线批量巡检](batch-audit.md)、逐项失败隔离和原始身份/范围绑定汇总。浏览器 Worker、异步存储、信号适配和断点恢复仍需要真实消费端设计与验证。现阶段优先保持单项及批量离线链路可靠。无网络下载器、自动修复或签名认证能力。
