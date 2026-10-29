///|
fn main {
  try {
    let data = [b"abc", b"def"]
    let torrent = @swarm.create_torrent(
      [{ path: ["a"], length: 3L, }, { path: ["b"], length: 3L, }],
      {
        ..@swarm.create_options("offline-bundle"),
        mode: @swarm.Hybrid,
        piece_length: 16384,
      },
      fn(file, offset, n) {
        data[file][offset.to_int():offset.to_int() + n].to_owned()
      },
    )
    // Locators are opaque keys in this in-memory storage adapter.
    let manifest = @swarm.parse_batch_manifest(
      b"{\"schema\":\"swarmcrate.audit-manifest.v1\",\"tasks\":[{\"id\":\"release\",\"metainfo\":\"seed\",\"payload\":\"stable\"},{\"id\":\"unavailable\",\"metainfo\":\"missing\",\"payload\":\"stable\"},{\"id\":\"selected\",\"metainfo\":\"seed\",\"payload\":\"stable\",\"files\":[\"a\"]},{\"id\":\"corrupt\",\"metainfo\":\"seed\",\"payload\":\"damaged\"},{\"id\":\"later\",\"metainfo\":\"seed\",\"payload\":\"stable\"}]}",
    )
    let audit = @swarm.audit_batch(
      manifest,
      fn(_, task) raise @swarm.CrateError {
        if task.metainfo == "missing" {
          raise @swarm.CrateError("io", "metadata unavailable")
        }
        torrent
      },
      fn(_, _, _) { [Some(3L), Some(3L)] },
      fn(task, file, offset, n) {
        if task == 3 {
          Bytes::make(n, 0)
        } else {
          data[file][offset.to_int():offset.to_int() + n].to_owned()
        }
      },
    )
    let text = @swarm.batch_audit_json_text(audit)
    let value = @json.parse(text)
    let fields = match value {
      Object(fields) => fields
      _ => abort("invalid summary")
    }
    assert_eq(fields.get("processed_tasks"), Some(Json::number(5)))
    assert_eq(fields.get("pass_tasks"), Some(Json::number(2)))
    assert_eq(fields.get("partial_pass_tasks"), Some(Json::number(1)))
    assert_eq(fields.get("failed_tasks"), Some(Json::number(1)))
    assert_eq(fields.get("error_tasks"), Some(Json::number(1)))
    assert_eq(@swarm.batch_audit_exit_code(audit), 1)
    println(text)
    println(
      "BATCH EXAMPLE PASS: later tasks survived an unavailable and a damaged input",
    )
  } catch {
    error => abort("batch example failed: \{error}")
  }
}
