///|
fn main {
  try {
    let content = Bytes::make(20000, 7)
    let torrent = @swarm.create_torrent(
      [{ path: ["a"], length: 20000L, }],
      { ..@swarm.create_options("bundle"), piece_length: 16384, },
      fn(_, o, n) { content[o.to_int():o.to_int() + n].to_owned() },
    )
    let manifest = @swarm.parse_batch_manifest(
      b"{\"schema\":\"swarmcrate.audit-manifest.v1\",\"tasks\":[{\"id\":\"first\",\"metainfo\":\"seed\",\"payload\":\"data\"},{\"id\":\"later\",\"metainfo\":\"seed\",\"payload\":\"data\"}]}",
    )
    let audit = @swarm.audit_batch_with_control(
      manifest,
      fn(_, _) { torrent },
      fn(_, _, _) { [Some(20000L)] },
      fn(_, _, o, n) { content[o.to_int():o.to_int() + n].to_owned() },
      fn(event) {
        println(@swarm.batch_progress_json(event).stringify())
        true
      },
    )
    assert_eq(@swarm.batch_audit_exit_code(audit), 0)
    let mut completed = 0
    let cancelled = try {
      ignore(
        @swarm.audit_batch_with_control(
          manifest,
          fn(_, _) { torrent },
          fn(_, _, _) { [Some(20000L)] },
          fn(_, _, o, n) { content[o.to_int():o.to_int() + n].to_owned() },
          fn(event) {
            completed = event.completed_tasks
            event.phase != "finalize"
          },
        ),
      )
      false
    } catch {
      @swarm.CrateError("cancelled", _) => true
      error => raise error
    }
    assert_true(cancelled && completed == 2)
    println(
      "BATCH CONTROL PASS: completed counters still permit cancellation without a summary",
    )
  } catch {
    error => abort("batch control example failed: \{error}")
  }
}
