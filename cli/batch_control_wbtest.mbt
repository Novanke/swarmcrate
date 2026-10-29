///|
fn disk_batch_control_key(event : @lib.BatchProgress) -> String {
  match event.verification {
    Some(v) => "verification/" + v.phase
    None => event.phase
  }
}

///|
test "controlled disk batch cancels without a candidate summary or staging and preserves legacy success" {
  let phases = [
    "start", "before_task", "after_load", "before_observe", "verification/start",
    "verification/before_read", "verification/after_read", "verification/check",
    "verification/finalize", "before_finish", "task_complete", "last_complete", "before_summary",
    "finalize", "before_write",
  ]
  for mode in ["v1", "v2", "hybrid"] {
    let dir = cli_fixture()
    errdefer cli_cleanup(dir)
    assert_eq(
      execute(["create", dir + "/input", dir + "/seed.torrent", "--mode", mode]).code,
      0,
    )
    let manifest = dir + "/jobs.json"
    disk_batch_manifest(manifest, [
      disk_batch_task("first", "seed.torrent", "input"),
      disk_batch_task("later", "seed.torrent", "input"),
    ])
    let output = dir + "/summary.json"
    for phase in phases {
      for action in ["cancel", "error"] {
        let mut seen = false
        let result = execute_batch_with_control(
          ["audit-batch", manifest, output],
          fn(e) raise @lib.CrateError {
            let matches = if phase == "last_complete" {
              e.phase == "task_complete" && e.completed_tasks == e.task_count
            } else {
              disk_batch_control_key(e) == phase
            }
            if matches {
              seen = true
              if action == "error" {
                raise @lib.CrateError("observer", "batch observer sentinel")
              }
              false
            } else {
              true
            }
          },
        )
        assert_true(seen)
        assert_eq(result.code, if action == "cancel" { 3 } else { 1 })
        assert_eq(
          disk_batch_field(@json.parse(result.output), "error"),
          Json::string(
            if action == "cancel" {
              "cancelled"
            } else {
              "observer"
            },
          ),
        )
        assert_true(!result.output.contains("all_full_pass"))
        assert_eq(@host.stat(output).kind, "missing")
        assert_true(
          @host.scan_snapshot(dir).directories.all(fn(d) {
            !d.names.any(fn(n) { n.has_prefix(".swarmcrate-") })
          }),
        )
      }
    }
    let result = execute_batch_with_control(["audit-batch", manifest, output], fn(
      _,
    ) {
      true
    })
    assert_eq(result.code, 0)
    assert_eq(
      disk_batch_field(@json.parse(result.output), "all_full_pass"),
      Json::boolean(true),
    )
    assert_eq(@host.read_metainfo(output), @utf8.encode(result.output))
    let legacy = execute(["audit-batch", manifest, dir + "/legacy.json"])
    assert_eq(legacy.output, result.output)
    let mut callbacks = 0
    assert_eq(
      execute_batch_with_control(["audit-batch", manifest, output], fn(_) {
        callbacks += 1
        false
      }).code,
      1,
    )
    assert_eq(callbacks, 0)
    assert_eq(@host.read_metainfo(output), @utf8.encode(result.output))
    assert_eq(execute_batch_with_control(["create"], fn(_) { true }).code, 1)
    cli_cleanup(dir)
  }
}

///|
extern "js" fn batch_observer_append(path : String) -> Unit =
  #| path => process.getBuiltinModule('node:fs').appendFileSync(path,'!')

///|
test "controlled batch rechecks manifest and current source after final successful observers" {
  for phase in ["task_complete", "before_summary", "finalize", "before_write"] {
    for mutation in ["payload", "metainfo", "manifest"] {
      let dir = cli_fixture()
      errdefer cli_cleanup(dir)
      assert_eq(
        execute(["create", dir + "/input", dir + "/seed.torrent"]).code,
        0,
      )
      let manifest = dir + "/jobs.json"
      disk_batch_manifest(manifest, [
        disk_batch_task("one", "seed.torrent", "input"),
      ])
      let target = if mutation == "payload" {
        dir + "/input/a.txt"
      } else if mutation == "metainfo" {
        dir + "/seed.torrent"
      } else {
        manifest
      }
      let mut changed = false
      let result = execute_batch_with_control(
        ["audit-batch", manifest, dir + "/summary.json"],
        fn(e) {
          if e.phase == phase && !changed {
            changed = true
            batch_observer_append(target)
          }
          true
        },
      )
      assert_true(changed)
      assert_eq(result.code, 1)
      assert_eq(
        disk_batch_field(@json.parse(result.output), "error"),
        Json::string("changed"),
      )
      assert_eq(@host.stat(dir + "/summary.json").kind, "missing")
      assert_true(!result.output.contains("all_full_pass"))
      cli_cleanup(dir)
    }
  }
}

///|
test "controlled batch preserves competing publication and fails globally" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  assert_eq(execute(["create", dir + "/input", dir + "/seed.torrent"]).code, 0)
  disk_batch_manifest(dir + "/jobs.json", [
    disk_batch_task("one", "seed.torrent", "input"),
  ])
  let output = dir + "/summary.json"
  batch_race_publication(output)
  errdefer ignore(batch_restore_close_hook())
  let result = execute_batch_with_control(
    ["audit-batch", dir + "/jobs.json", output],
    fn(_) { true },
  )
  assert_true(batch_restore_close_hook())
  assert_eq(result.code, 1)
  assert_eq(@host.read_metainfo(output), b"competing writer")
  cli_cleanup(dir)
}

///|
extern "js" fn batch_enter_directory(path : String) -> String =
  #| path => { const before=process.cwd();process.chdir(path);return before; }

///|
test "controlled batch freezes the output path before an observer changes working directory" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  assert_eq(execute(["create", dir + "/input", dir + "/seed.torrent"]).code, 0)
  disk_batch_manifest(dir + "/jobs.json", [
    disk_batch_task("one", "seed.torrent", "input"),
  ])
  let original_directory = batch_enter_directory(dir)
  errdefer ignore(batch_enter_directory(original_directory))
  let result = execute_batch_with_control(
    ["audit-batch", "jobs.json", "summary.json"],
    fn(e) {
      if e.phase == "before_write" {
        ignore(batch_enter_directory(dir + "/input"))
      }
      true
    },
  )
  ignore(batch_enter_directory(original_directory))
  assert_eq(result.code, 0)
  assert_eq(
    @host.read_metainfo(dir + "/summary.json"),
    @utf8.encode(result.output),
  )
  assert_eq(@host.stat(dir + "/input/summary.json").kind, "missing")
  cli_cleanup(dir)
}

///|
test "controlled creation also retains the originally preflighted destination after chdir" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  let original_directory = batch_enter_directory(dir)
  errdefer ignore(batch_enter_directory(original_directory))
  let result = execute_create_with_control(
    ["create", "input", "seed.torrent"],
    fn(e) {
      if e.phase == "before_write" {
        ignore(batch_enter_directory(dir + "/input"))
      }
      true
    },
  )
  ignore(batch_enter_directory(original_directory))
  assert_eq(result.code, 0)
  assert_eq(@host.stat(dir + "/seed.torrent").kind, "file")
  assert_eq(@host.stat(dir + "/input/seed.torrent").kind, "missing")
  assert_eq(execute(["verify", dir + "/seed.torrent", dir + "/input"]).code, 0)
  cli_cleanup(dir)
}
