///|
extern "js" fn now_ms() -> Double =
  #| () => Number(process.hrtime.bigint()) / 1e6

///|
fn measure(
  label : String,
  files : Array[@lib.SourceFile],
  mode : @lib.TorrentMode,
) -> Unit raise @lib.CrateError {
  let mut reads = 0
  let mut bytes = 0L
  let start = now_ms()
  let torrent = @lib.create_torrent(
    files,
    { ..@lib.create_options("benchmark"), mode, },
    fn(_, _, n) {
      reads += 1
      bytes += n.to_int64()
      Bytes::make(n, 7)
    },
  )
  let elapsed = now_ms() - start
  let info = @lib.inspect_torrent(torrent)
  println(
    Json::object(
      Map([
        ("case", Json::string(label)),
        ("files", Json::number(files.length().to_double())),
        ("milliseconds", Json::number(elapsed)),
        ("read_calls", Json::number(reads.to_double())),
        ("read_bytes", Json::string(bytes.to_string())),
        ("metainfo_bytes", Json::number(torrent.length().to_double())),
        ("info_hash_v1", Json::string(info.info_hash_v1.unwrap_or(""))),
        ("info_hash_v2", Json::string(info.info_hash_v2.unwrap_or(""))),
      ]),
    ).stringify(),
  )
}

///|
fn main {
  try {
    for count in [1000, 5000] {
      let files = Array::makei(count, fn(i) {
        @lib.SourceFile::{
          path: ["file-" + i.to_string()],
          length: if i == count - 1 {
            1L
          } else {
            0L
          },
        }
      })
      measure("flat-v2", files, @lib.V2)
    }
    measure(
      "hybrid-8MiB",
      [{ path: ["data.bin"], length: 8388611L, }],
      @lib.Hybrid,
    )
  } catch {
    @lib.CrateError(code, detail) =>
      abort("benchmark failed: " + code + ": " + detail)
  }
}
