///|
// Node-only single-file consumer. Writes only after SDK return and source recheck.
fn main {
  let mut reads = 0
  let mut bytes = 0L
  let mut checked = 0
  let mut total = 0
  try {
    let args = @cli.arguments()
    if args.length() != 4 {
      raise @swarm.CrateError(
        "usage", "TORRENT PAYLOAD NEW_RECEIPT full|cancel-start|cancel-read|cancel-check|cancel-finalize|observer-error",
      )
    }
    let mode = args[3]
    if ![
        "full", "cancel-start", "cancel-read", "cancel-check", "cancel-finalize",
        "observer-error",
      ].contains(mode) {
      raise @swarm.CrateError("usage", "unknown control example mode")
    }
    let output_key = @host.resolve(args[2]).to_lower()
    if output_key == @host.resolve(args[1]).to_lower() ||
      output_key == @host.resolve(args[0]).to_lower() ||
      @host.stat(args[2]).kind != "missing" {
      raise @swarm.CrateError(
        "usage", "output must be a new file separate from both inputs",
      )
    }
    if @host.stat(@host.resolve(args[2]) + "/..").kind != "directory" {
      raise @swarm.CrateError("usage", "output parent must exist")
    }
    let torrent = @host.read_metainfo(args[0])
    let info = @swarm.inspect_torrent(torrent)
    if !info.single_file {
      raise @swarm.CrateError(
        "usage", "this example accepts a single-file torrent",
      )
    }
    let snapshot = @host.stat(args[1])
    let (report, receipt) = @swarm.verify_with_control(
      torrent,
      [if snapshot.kind == "file" { Some(snapshot.length) } else { None }],
      (_, offset, size) => {
        @host.read_range(args[1], offset, size, stamp=snapshot.stamp)
      },
      fn(event) raise @swarm.CrateError {
        reads = event.read_calls
        bytes = event.validated_read_bytes
        checked = event.checked_pieces
        total = event.total_checks
        if mode == "observer-error" && event.phase == "before_read" {
          raise @swarm.CrateError("observer", "example observer failure")
        }
        !(mode == "cancel-start" && event.phase == "start") &&
        !(mode == "cancel-read" && event.phase == "after_read") &&
        !(mode == "cancel-check" && event.phase == "check") &&
        !(mode == "cancel-finalize" && event.phase == "finalize")
      },
    )
    @host.check_unchanged(args[1], snapshot)
    @host.write_new(args[2], @utf8.encode(@swarm.receipt_json_text(receipt)))
    println(
      Json::object(
        Map([
          ("ok", Json::boolean(report.ok)),
          ("read_calls", Json::number(reads.to_double())),
          ("validated_read_bytes", Json::string(bytes.to_string())),
          ("checked_pieces", Json::number(checked.to_double())),
          ("total_checks", Json::number(total.to_double())),
        ]),
      ).stringify(),
    )
    @cli.set_exit_code(if report.ok { 0 } else { 2 })
  } catch {
    @swarm.CrateError(code, detail) => {
      println(
        Json::object(
          Map([
            ("error", Json::string(code)),
            ("detail", Json::string(detail)),
            ("read_calls", Json::number(reads.to_double())),
            ("validated_read_bytes", Json::string(bytes.to_string())),
            ("checked_pieces", Json::number(checked.to_double())),
            ("total_checks", Json::number(total.to_double())),
          ]),
        ).stringify(),
      )
      @cli.set_exit_code(if code == "cancelled" { 3 } else { 1 })
    }
  }
}
