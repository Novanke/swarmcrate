///|
/// Portable synchronous SDK example: observe a complete check, then cancel a new one.
fn main {
  try {
    let content = Bytes::make(2097169, 7)
    let read = fn(
      _ : Int32,
      offset : Int64,
      size : Int32,
    ) raise @swarm.CrateError {
      if offset < 0L ||
        size < 1 ||
        offset + size.to_int64() > content.length().to_int64() {
        raise @swarm.CrateError("example", "invalid read range")
      }
      content[offset.to_int():offset.to_int() + size].to_owned()
    }
    let torrent = @swarm.create_torrent(
      [{ path: ["example.bin"], length: content.length().to_int64(), }],
      {
        ..@swarm.create_options("example.bin"),
        single_file: true,
        piece_length: 2097152,
      },
      read,
    )
    let mut final_reads = 0
    let mut final_bytes = 0L
    let (report, receipt) = @swarm.verify_with_control(
      torrent,
      [Some(content.length().to_int64())],
      read,
      fn(event) {
        final_reads = event.read_calls
        final_bytes = event.validated_read_bytes
        true
      },
    )
    if !report.ok ||
      final_reads != 3 ||
      final_bytes != content.length().to_int64() {
      abort("controlled example progress mismatch")
    }
    println(@swarm.receipt_diagnostics_json_text(receipt))
    let mut cancel_reads = 0
    let cancelled = try {
      ignore(
        @swarm.verify_with_control(
          torrent,
          [Some(content.length().to_int64())],
          read,
          fn(event) {
            cancel_reads = event.read_calls
            event.phase != "after_read"
          },
        ),
      )
      false
    } catch {
      @swarm.CrateError("cancelled", _) => true
      error => raise error
    }
    if !cancelled || cancel_reads != 1 {
      abort("cancellation did not stop after one read")
    }
    println(
      "CONTROLLED SDK PASS: completed receipt verified; cancelled call returned no receipt",
    )
  } catch {
    @swarm.CrateError(code, detail) => abort(code + ": " + detail)
  }
}
