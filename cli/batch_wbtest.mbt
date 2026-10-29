///|
fn disk_batch_field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap()
    _ => abort("expected object")
  }
}

///|
fn disk_batch_task(
  id : String,
  torrent : String,
  payload : String,
  files~ : Array[String]? = None,
) -> Json {
  let fields = [
    ("id", Json::string(id)),
    ("metainfo", Json::string(torrent)),
    ("payload", Json::string(payload)),
  ]
  if files is Some(files) {
    fields.push(("files", Json::array(files.map(Json::string))))
  }
  Json::object(Map(fields))
}

///|
fn disk_batch_manifest(
  path : String,
  tasks : Array[Json],
) -> Unit raise @lib.CrateError {
  @host.write_new(
    path,
    @utf8.encode(
      Json::object(
        Map([
          ("schema", Json::string("swarmcrate.audit-manifest.v1")),
          ("tasks", Json::array(tasks)),
        ]),
      ).stringify(),
    ),
  )
}

///|
test "disk batch resolves from manifest directory isolates errors and binds exact identities" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  @host.write_new(dir + "/input/b.txt", b"world")
  for mode in ["v1", "v2", "hybrid"] {
    let seed = dir + "/" + mode + ".torrent"
    assert_eq(
      execute([
        "create",
        dir + "/input",
        seed,
        "--mode",
        mode,
        "--piece-length",
        "16384",
      ]).code,
      0,
    )
    let edited = dir + "/" + mode + "-edited.torrent"
    assert_eq(
      execute([
        "edit", seed, edited, "--tracker", "https://example.org/announce",
      ]).code,
      0,
    )
    @host.write_new(dir + "/" + mode + "-bad.torrent", b"bad metadata")
    let manifest = dir + "/" + mode + "-jobs.json"
    disk_batch_manifest(manifest, [
      disk_batch_task("first", mode + ".torrent", "input"),
      disk_batch_task("missing-seed", "absent.torrent", "input"),
      disk_batch_task("bad-seed", mode + "-bad.torrent", "input"),
      disk_batch_task("missing-payload", mode + ".torrent", "missing-payload"),
      disk_batch_task(
        "unknown-selection",
        mode + ".torrent",
        "input",
        files=Some(["absent"]),
      ),
      disk_batch_task(
        "selected",
        mode + ".torrent",
        "input",
        files=Some(["a.txt"]),
      ),
      disk_batch_task("edited", mode + "-edited.torrent", "input"),
      disk_batch_task("last", mode + ".torrent", "input"),
    ])
    let summary = dir + "/" + mode + "-summary.json"
    let result = execute(["audit-batch", manifest, summary])
    assert_eq(result.code, 1)
    assert_eq(@host.read_metainfo(summary), @utf8.encode(result.output))
    let value = @json.parse(result.output)
    assert_eq(disk_batch_field(value, "processed_tasks"), Json::number(8))
    assert_eq(disk_batch_field(value, "pass_tasks"), Json::number(3))
    assert_eq(disk_batch_field(value, "partial_pass_tasks"), Json::number(1))
    assert_eq(disk_batch_field(value, "failed_tasks"), Json::number(1))
    assert_eq(disk_batch_field(value, "error_tasks"), Json::number(3))
    let rows = match disk_batch_field(value, "tasks") {
      Array(rows) => rows
      _ => abort("expected rows")
    }
    let subject = disk_batch_field(rows[0], "subject")
    let edited_subject = disk_batch_field(rows[6], "subject")
    for key in ["info_hash_v1", "info_hash_v2"] {
      assert_eq(
        disk_batch_field(subject, key),
        disk_batch_field(edited_subject, key),
      )
    }
    assert_true(
      disk_batch_field(subject, "metainfo_sha256") !=
      disk_batch_field(edited_subject, "metainfo_sha256"),
    )
    assert_eq(disk_batch_field(rows[7], "outcome"), Json::string("PASS"))
    let before = @host.read_metainfo(summary)
    assert_eq(execute(["audit-batch", manifest, summary]).code, 1)
    assert_eq(@host.read_metainfo(summary), before)
  }
  cli_cleanup(dir)
}

///|
test "disk batch protects every declared input root including later invalid and missing jobs" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  assert_eq(execute(["create", dir + "/input", dir + "/valid.torrent"]).code, 0)
  let manifest = dir + "/jobs.json"
  disk_batch_manifest(manifest, [
    disk_batch_task("valid", "valid.torrent", "input"),
    disk_batch_task("later-invalid", "missing.torrent", "later-root"),
  ])
  for
    output in [
      manifest,
      dir + "/valid.torrent",
      dir + "/missing.torrent",
      dir + "/input/a.txt",
      dir + "/input/not-payload.json",
      dir + "/later-root",
      dir + "/later-root/summary.json",
      dir + "/INPUT/new.json",
    ] {
    assert_eq(execute(["audit-batch", manifest, output]).code, 1)
  }
  assert_eq(@host.stat(dir + "/missing.torrent").kind, "missing")
  assert_eq(@host.stat(dir + "/input/not-payload.json").kind, "missing")
  assert_eq(@host.stat(dir + "/later-root").kind, "missing")
  cli_cleanup(dir)
}

///|
test "disk batch keeps partial success and integrity failure exit codes distinct" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  @host.write_new(dir + "/input/b.txt", b"world")
  assert_eq(
    execute(["create", dir + "/input", dir + "/valid.torrent", "--mode", "v2"]).code,
    0,
  )
  let partial = dir + "/partial.json"
  disk_batch_manifest(partial, [
    disk_batch_task("one", "valid.torrent", "input", files=Some(["a.txt"])),
  ])
  let result = execute(["audit-batch", partial, dir + "/partial-summary.json"])
  assert_eq(result.code, 0)
  let value = @json.parse(result.output)
  assert_eq(disk_batch_field(value, "outcome"), Json::string("PARTIAL_PASS"))
  assert_eq(disk_batch_field(value, "all_full_pass"), Json::boolean(false))
  let missing = dir + "/missing.json"
  disk_batch_manifest(missing, [
    disk_batch_task("missing", "valid.torrent", "absent"),
  ])
  let result = execute(["audit-batch", missing, dir + "/missing-summary.json"])
  assert_eq(result.code, 2)
  assert_eq(
    disk_batch_field(@json.parse(result.output), "outcome"),
    Json::string("FAIL"),
  )
  cli_cleanup(dir)
}

///|
test "batch filesystem locators reject ambient drive-relative paths" {
  assert_true(
    try {
      ignore(batch_disk_locator("base", "C:payload"))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(batch_disk_locator("base", "C:"))
      false
    } catch {
      _ => true
    },
  )
}

///|
extern "js" fn batch_change_after_close(
  watched : String,
  changed : String,
) -> Unit =
  #| (watched,changed) => {
  #|   const fs=process.getBuiltinModule('node:fs'),path=process.getBuiltinModule('node:path');
  #|   const open=fs.openSync,close=fs.closeSync,fds=new Set(),state={injected:false};
  #|   const key=Symbol.for('swarmcrate.batch.test');
  #|   if(globalThis[key]) throw Error('batch test hook already installed');
  #|   fs.openSync=function(file,...args){ const fd=open.call(this,file,...args); if(path.resolve(String(file))===path.resolve(watched)) fds.add(fd); return fd; };
  #|   fs.closeSync=function(fd){ const applies=fds.delete(fd),result=close.call(this,fd); if(applies&&!state.injected){state.injected=true;fs.appendFileSync(changed,'!');} return result; };
  #|   state.restore=()=>{fs.openSync=open;fs.closeSync=close;delete globalThis[key];};
  #|   globalThis[key]=state;
  #| }

///|
extern "js" fn batch_restore_close_hook() -> Bool =
  #| () => { const state=globalThis[Symbol.for('swarmcrate.batch.test')]; if(!state) return false; state.restore(); return state.injected; }

///|
test "disk batch rejects stale task acceptance and stale manifest publication" {
  for mutation in ["payload", "metainfo", "manifest"] {
    let dir = cli_fixture()
    errdefer cli_cleanup(dir)
    assert_eq(
      execute(["create", dir + "/input", dir + "/first.torrent"]).code,
      0,
    )
    @host.write_new(dir + "/other.txt", b"stable later payload")
    assert_eq(
      execute(["create", dir + "/other.txt", dir + "/later.torrent"]).code,
      0,
    )
    let manifest = dir + "/jobs.json"
    disk_batch_manifest(manifest, [
      disk_batch_task("first", "first.torrent", "input"),
      disk_batch_task("later", "later.torrent", "other.txt"),
    ])
    let watched = if mutation == "metainfo" {
      dir + "/first.torrent"
    } else {
      dir + "/input/a.txt"
    }
    let changed = if mutation == "metainfo" {
      watched
    } else if mutation == "manifest" {
      manifest
    } else {
      watched
    }
    batch_change_after_close(watched, changed)
    errdefer ignore(batch_restore_close_hook())
    let summary = dir + "/summary.json"
    let result = execute(["audit-batch", manifest, summary])
    assert_true(batch_restore_close_hook())
    assert_eq(result.code, 1)
    if mutation == "manifest" {
      assert_eq(@host.stat(summary).kind, "missing")
    } else {
      let rows = match disk_batch_field(@json.parse(result.output), "tasks") {
        Array(rows) => rows
        _ => abort("expected rows")
      }
      assert_eq(disk_batch_field(rows[0], "outcome"), Json::string("ERROR"))
      assert_eq(disk_batch_field(rows[0], "verification"), Json::null())
      assert_eq(disk_batch_field(rows[0], "receipt_sha256"), Json::null())
      assert_eq(disk_batch_field(rows[1], "outcome"), Json::string("PASS"))
    }
    cli_cleanup(dir)
  }
}

///|
extern "js" fn batch_race_publication(target : String) -> Unit =
  #| target => {
  #|   const fs=process.getBuiltinModule('node:fs'),path=process.getBuiltinModule('node:path'),link=fs.linkSync;
  #|   const state={injected:false,restore:()=>{fs.linkSync=link;delete globalThis[Symbol.for('swarmcrate.batch.test')];}};
  #|   if(globalThis[Symbol.for('swarmcrate.batch.test')]) throw Error('batch test hook already installed');
  #|   fs.linkSync=function(source,dest){if(path.resolve(String(dest))===path.resolve(target)){state.injected=true;fs.writeFileSync(target,'competing writer');} return link.call(this,source,dest);};
  #|   globalThis[Symbol.for('swarmcrate.batch.test')]=state;
  #| }

///|
test "batch publication race preserves a competing summary and returns a global I/O error" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  assert_eq(execute(["create", dir + "/input", dir + "/seed.torrent"]).code, 0)
  disk_batch_manifest(dir + "/jobs.json", [
    disk_batch_task("one", "seed.torrent", "input"),
  ])
  let output = dir + "/summary.json"
  batch_race_publication(output)
  errdefer ignore(batch_restore_close_hook())
  let result = execute(["audit-batch", dir + "/jobs.json", output])
  assert_true(batch_restore_close_hook())
  assert_eq(result.code, 1)
  assert_eq(@host.read_metainfo(output), b"competing writer")
  assert_eq(
    disk_batch_field(@json.parse(result.output), "error"),
    Json::string("io"),
  )
  cli_cleanup(dir)
}
