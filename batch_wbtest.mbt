///|
fn batch_test_task(id : String, files~ : Array[String]? = None) -> Json {
  let fields = [
    ("id", Json::string(id)),
    ("metainfo", Json::string(id + ".torrent")),
    ("payload", Json::string("payload")),
  ]
  if files is Some(files) {
    fields.push(("files", Json::array(files.map(Json::string))))
  }
  j_object(fields)
}

///|
fn batch_test_manifest(tasks : Array[Json]) -> BatchManifest raise CrateError {
  parse_batch_manifest(
    @utf8.encode(
      j_object([
        ("schema", Json::string("swarmcrate.audit-manifest.v1")),
        ("tasks", Json::array(tasks)),
      ]).stringify(),
    ),
  )
}

///|
fn batch_test_json(audit : BatchAudit) -> Json {
  @json.parse(batch_audit_json_text(audit)) catch {
    _ => abort("invalid batch JSON")
  }
}

///|
fn batch_test_field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap()
    _ => abort("expected object")
  }
}

///|
fn batch_test_rows(audit : BatchAudit) -> Array[Json] {
  match batch_test_field(batch_test_json(audit), "tasks") {
    Array(rows) => rows
    _ => abort("expected rows")
  }
}

///|
test "batch isolates task errors from integrity failures and continues in all modes" {
  let data = [b"abc", Bytes::make(32769, 7), b""]
  let files : Array[SourceFile] = [
    { path: ["a"], length: 3L, },
    { path: ["b"], length: 32769L, },
    { path: ["empty"], length: 0L, },
  ]
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      files,
      { ..create_options("bundle"), mode, piece_length: 16384, },
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
    )
    let manifest = batch_test_manifest([
      batch_test_task("first"),
      batch_test_task("load-error"),
      batch_test_task("bad-meta"),
      batch_test_task("bad-selection", files=Some(["absent"])),
      batch_test_task("damaged"),
      batch_test_task("selected", files=Some(["a", "a"])),
      batch_test_task("changed"),
      batch_test_task("unreadable"),
      batch_test_task("last"),
    ])
    let loaded : Array[Int32] = []
    let finished : Array[Int32] = []
    let result = audit_batch(
      manifest,
      fn(i, _) raise CrateError {
        loaded.push(i)
        if i == 1 {
          raise CrateError("io", "could not open")
        }
        if i == 2 {
          b"not bencode"
        } else {
          torrent
        }
      },
      fn(_, _, _) { [Some(3L), Some(32769L), Some(0L)] },
      fn(i, file, offset, n) raise CrateError {
        if i == 7 {
          raise CrateError("io", "payload read failed")
        }
        if i == 4 {
          Bytes::make(n, 0)
        } else {
          data[file][offset.to_int():offset.to_int() + n].to_owned()
        }
      },
      finish=Some(fn(i) raise CrateError {
        finished.push(i)
        if i == 6 {
          raise CrateError("changed", "source changed after last read")
        }
      }),
    )
    let rows = batch_test_rows(result)
    assert_eq(loaded, [0, 1, 2, 3, 4, 5, 6, 7, 8])
    assert_eq(finished, [0, 4, 5, 6, 7, 8])
    assert_eq(
      rows.map(fn(row) { batch_test_field(row, "outcome") }),
      [
        "PASS", "ERROR", "ERROR", "ERROR", "FAIL", "PARTIAL_PASS", "ERROR", "FAIL",
        "PASS",
      ].map(Json::string),
    )
    let root = batch_test_json(result)
    assert_eq(batch_test_field(root, "pass_tasks"), Json::number(2))
    assert_eq(batch_test_field(root, "partial_pass_tasks"), Json::number(1))
    assert_eq(batch_test_field(root, "failed_tasks"), Json::number(2))
    assert_eq(batch_test_field(root, "error_tasks"), Json::number(4))
    assert_eq(batch_test_field(root, "all_full_pass"), Json::boolean(false))
    assert_eq(
      batch_test_field(root, "all_tasks_processed"),
      Json::boolean(true),
    )
    assert_eq(batch_audit_exit_code(result), 1)
    assert_eq(batch_test_field(rows[1], "subject"), Json::null())
    let invalid = batch_test_field(rows[2], "subject")
    assert_eq(
      batch_test_field(invalid, "metainfo_sha256"),
      Json::string(@crypto.bytes_to_hex_string(@crypto.sha256(b"not bencode"))),
    )
    assert_eq(batch_test_field(invalid, "info_hash_v1"), Json::null())
    assert_eq(batch_test_field(rows[6], "verification"), Json::null())
    assert_eq(batch_test_field(rows[6], "receipt_sha256"), Json::null())
    let scope = batch_test_field(rows[5], "scope")
    assert_eq(
      batch_test_field(scope, "selected_files"),
      Json::array([Json::number(0)]),
    )
    assert_eq(
      batch_test_field(scope, "required_files"),
      Json::array(
        (if mode == V1 { [0, 1] } else { [0] }).map(fn(i) {
          Json::number(i.to_double())
        }),
      ),
    )
  }
}

///|
test "batch binds exact manifest metadata and scopes without merging equal infohashes" {
  let data = [b"abc", b"def"]
  let torrent = create_torrent(
    [{ path: ["a"], length: 3L, }, { path: ["b"], length: 3L, }],
    { ..create_options("bundle"), mode: Hybrid, piece_length: 16384, },
    fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
  )
  let edited = edit_distribution(torrent, [["https://example.org/announce"]], [])
  let manifest = batch_test_manifest([
    batch_test_task("original"),
    batch_test_task("edited"),
    batch_test_task("partial", files=Some(["a"])),
  ])
  let run = fn() raise CrateError {
    audit_batch(
      manifest,
      fn(i, _) { if i == 1 { edited } else { torrent } },
      fn(_, _, _) { [Some(3L), Some(3L)] },
      fn(_, file, o, n) { data[file][o.to_int():o.to_int() + n].to_owned() },
    )
  }
  let audit = run()
  let rows = batch_test_rows(audit)
  let original = batch_test_field(rows[0], "subject")
  let changed = batch_test_field(rows[1], "subject")
  assert_eq(
    batch_test_field(original, "info_hash_v1"),
    batch_test_field(changed, "info_hash_v1"),
  )
  assert_eq(
    batch_test_field(original, "info_hash_v2"),
    batch_test_field(changed, "info_hash_v2"),
  )
  assert_true(
    batch_test_field(original, "metainfo_sha256") !=
    batch_test_field(changed, "metainfo_sha256"),
  )
  assert_eq(
    batch_test_field(original, "metainfo_sha256"),
    batch_test_field(batch_test_field(rows[2], "subject"), "metainfo_sha256"),
  )
  assert_eq(
    batch_test_field(batch_test_json(audit), "outcome"),
    Json::string("PARTIAL_PASS"),
  )
  assert_eq(batch_audit_exit_code(audit), 0)
  let (_, receipt) = verify_with_receipt(
    torrent,
    [Some(3L), Some(3L)],
    fn(file, o, n) { data[file][o.to_int():o.to_int() + n].to_owned() },
    detail_limit=128,
  )
  assert_eq(
    batch_test_field(rows[0], "receipt_sha256"),
    Json::string(
      @crypto.bytes_to_hex_string(
        @crypto.sha256(@utf8.encode(receipt_json_text(receipt))),
      ),
    ),
  )
  let text = batch_audit_json_text(audit)
  let exported = batch_manifest_tasks(manifest)
  exported.clear()
  match rows[0] {
    Object(map) => map.clear()
    _ => ()
  }
  assert_eq(batch_audit_json_text(audit), text)
  assert_eq(batch_audit_json_text(run()), text)
}

///|
test "batch callback mutation cannot change task selections or internal scope mappings" {
  let torrent = create_torrent(
    [{ path: ["a"], length: 1L, }, { path: ["b"], length: 1L, }],
    { ..create_options("bundle"), mode: V2, piece_length: 16384, },
    fn(_, _, _) { b"x" },
  )
  let manifest = batch_test_manifest([
    batch_test_task("selected", files=Some(["a"])),
  ])
  let exported = batch_manifest_tasks(manifest)
  exported[0].files.unwrap()[0] = "b"
  let sizes : Array[Int64?] = [Some(1L), None]
  let audit = audit_batch(
    manifest,
    fn(_, task) {
      task.files.unwrap().clear()
      torrent
    },
    fn(_, info, scope) {
      info.files[0].path[0] = "caller mutation"
      info.files.clear()
      scope.selected_files.clear()
      scope.required_files.clear()
      sizes
    },
    fn(_, file, _, _) raise CrateError {
      sizes[0] = None
      if file != 0 {
        raise CrateError("test", "selection was mutated")
      }
      b"x"
    },
  )
  let row = batch_test_rows(audit)[0]
  assert_eq(batch_test_field(row, "outcome"), Json::string("PARTIAL_PASS"))
  assert_eq(
    batch_test_field(batch_test_field(row, "scope"), "selected_files"),
    Json::array([Json::number(0)]),
  )
  assert_true(!batch_audit_json_text(audit).contains("caller mutation"))
}

///|
test "batch rejects malformed or unbounded manifests before storage callbacks" {
  for
    text in [
      "{}", "{\"schema\":\"bad\",\"tasks\":[]}", "{\"schema\":\"swarmcrate.audit-manifest.v1\",\"schema\":\"swarmcrate.audit-manifest.v1\",\"tasks\":[]}",
      "{\"schema\":\"swarmcrate.audit-manifest.v1\",\"tasks\":[],\"typo\":1}", "[[[[[[[[[[]]]]]]]]]]",
    ] {
    assert_true(
      try {
        ignore(parse_batch_manifest(@utf8.encode(text)))
        false
      } catch {
        _ => true
      },
    )
  }
  for
    tasks in [
      [],
      [batch_test_task("same"), batch_test_task("same")],
      [batch_test_task("empty", files=Some([]))],
      Array::makei(65, fn(i) { batch_test_task(i.to_string()) }),
    ] {
    assert_true(
      try {
        ignore(batch_test_manifest(tasks))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(parse_batch_manifest(Bytes::make(1048577, 32)))
      false
    } catch {
      _ => true
    },
  )
  let manifest = batch_test_manifest([batch_test_task("one")])
  let mut calls = 0
  assert_true(
    try {
      ignore(
        audit_batch(
          manifest,
          fn(_, _) {
            calls += 1
            b""
          },
          fn(_, _, _) { [] },
          fn(_, _, _, _) { b"" },
          max_summary_bytes=1,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_eq(calls, 0)
}

///|
test "batch summary budget records a task error and still accepts a later small audit" {
  let files : Array[SourceFile] = [{ path: ["a"], length: 1L, }]
  for i in 0..<2500 {
    files.push({ path: ["empty" + i.to_string()], length: 0L, })
  }
  let torrent = create_torrent(
    files,
    { ..create_options("bundle"), mode: V1, piece_length: 16384, },
    fn(_, _, _) { b"x" },
  )
  let manifest = batch_test_manifest([
    batch_test_task("large"),
    batch_test_task("later", files=Some(["a"])),
  ])
  let loaded : Array[Int32] = []
  let audit = audit_batch(
    manifest,
    fn(i, _) {
      loaded.push(i)
      torrent
    },
    fn(_, info, _) { info.files.map(fn(f) { Some(f.length) }) },
    fn(_, _, _, _) { b"x" },
    max_summary_bytes=12288,
  )
  let rows = batch_test_rows(audit)
  assert_eq(loaded, [0, 1])
  assert_eq(batch_test_field(rows[0], "outcome"), Json::string("ERROR"))
  assert_eq(
    batch_test_field(batch_test_field(rows[0], "error"), "code"),
    Json::string("summary_limit"),
  )
  assert_eq(batch_test_field(rows[1], "outcome"), Json::string("PARTIAL_PASS"))
  assert_true(@utf8.encode(batch_audit_json_text(audit)).length() <= 12288)
}
