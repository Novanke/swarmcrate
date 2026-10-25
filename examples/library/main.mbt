///|
/// Self-contained public-API example; no filesystem, external service or FFI.
fn main {
  try {
    let content = b"hello from SwarmCrate\n"
    let files : Array[@swarm.SourceFile] = [
      { path: ["hello.txt"], length: content.length().to_int64(), },
    ]
    for mode in [@swarm.V1, @swarm.V2, @swarm.Hybrid] {
      let options = {
        ..@swarm.create_options("hello.txt"),
        mode,
        piece_length: @swarm.recommend_piece_length(files, mode~),
        single_file: true,
      }
      let read = fn(
        index : Int32,
        offset : Int64,
        size : Int32,
      ) raise @swarm.CrateError {
        if index != 0 ||
          offset < 0L ||
          size < 0 ||
          offset > content.length().to_int64() - size.to_int64() {
          raise @swarm.CrateError(
            "example_read", "invalid requested byte range",
          )
        }
        content[offset.to_int():offset.to_int() + size].to_owned()
      }
      let torrent = @swarm.create_torrent(files, options, read)
      let summary = @swarm.inspect_torrent(torrent)
      let report = @swarm.verify_payload(
        torrent,
        [Some(content.length().to_int64())],
        read,
      )
      if !report.ok || !report.scope.complete {
        abort("intact example failed verification")
      }
      let corrupt = @swarm.verify_payload(
        torrent,
        [Some(content.length().to_int64())],
        fn(_, _, size) { Bytes::make(size, 0) },
      )
      if corrupt.ok || corrupt.failed_pieces == 0 {
        abort("example did not detect corruption")
      }
      println(@swarm.info_json(summary).stringify())
      println(@swarm.torrent_magnet(torrent))
      println(@swarm.verification_json(report).stringify())
    }
    println(
      "PASS: all three modes created, inspected and verified; corruption detected",
    )
  } catch {
    @swarm.CrateError(code, detail) => abort(code + ": " + detail)
  }
}
