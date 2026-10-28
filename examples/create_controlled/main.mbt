///|
fn main {
  try {
    let content = Bytes::make(2097169, 7)
    let files : Array[@swarm.SourceFile] = [
      { path: ["example.bin"], length: content.length().to_int64(), },
    ]
    let options = {
      ..@swarm.create_options("example.bin"),
      single_file: true,
      piece_length: 2097152,
    }
    let read = fn(
      _ : Int32,
      offset : Int64,
      size : Int32,
    ) raise @swarm.CrateError {
      if offset < 0L ||
        size < 1 ||
        offset + size.to_int64() > content.length().to_int64() {
        raise @swarm.CrateError("example", "invalid read")
      }
      content[offset.to_int():offset.to_int() + size].to_owned()
    }
    let torrent = @swarm.create_torrent_with_control(files, options, read, fn(
      _,
    ) {
      true
    })
    println(@swarm.info_json(@swarm.inspect_torrent(torrent)).stringify())
    let mut observed_bytes = 0L
    let cancelled = try {
      ignore(
        @swarm.create_torrent_with_control(files, options, read, fn(event) {
          observed_bytes = event.validated_read_bytes
          event.phase != "before_encode"
        }),
      )
      false
    } catch {
      @swarm.CrateError("cancelled", _) => true
      error => raise error
    }
    if !cancelled || observed_bytes != content.length().to_int64() {
      abort(
        "expected cancellation after all payload reads without returned metainfo",
      )
    }
    println(
      "CREATION SDK PASS: validated metainfo created; 100% reads do not bypass cancellation",
    )
  } catch {
    @swarm.CrateError(code, detail) => abort(code + ": " + detail)
  }
}
