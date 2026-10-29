///|
fn batch_control_key(event : BatchProgress) -> String {
  match event.verification {
    Some(v) => "verification/" + v.phase
    None => event.phase
  }
}

///|
test "batch progress has monotonic real I/O counters and settled row counts across isolated failures" {
  let data = [b"abc", Bytes::make(17000, 7)]
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      [{ path: ["a"], length: 3L, }, { path: ["b"], length: 17000L, }],
      { ..create_options("bundle"), mode, piece_length: 16384, },
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
    )
    let manifest = batch_test_manifest([
      batch_test_task("full"),
      batch_test_task("partial", files=Some(["a"])),
      batch_test_task("load-error"),
      batch_test_task("unreadable"),
      batch_test_task("finish-error"),
      batch_test_task("later"),
    ])
    let load = fn(i : Int32, _ : BatchTask) raise CrateError {
      if i == 2 {
        raise CrateError("cancelled", "ordinary storage load error")
      }
      torrent
    }
    let observe = fn(
      _ : Int32,
      info : TorrentInfo,
      _ : VerificationScope,
    ) raise CrateError {
      if info.files.length() != 2 {
        raise CrateError("test", "unexpected file table")
      }
      [Some(3L), Some(17000L)]
    }
    let mut read_calls = 0L
    let mut read_bytes = 0L
    let read = fn(
      i : Int32,
      file : Int32,
      o : Int64,
      n : Int32,
    ) raise CrateError {
      read_calls += 1L
      if i == 3 {
        raise CrateError("cancelled", "ordinary storage read error")
      }
      read_bytes += n.to_int64()
      data[file][o.to_int():o.to_int() + n].to_owned()
    }
    let finish = Some(fn(i : Int32) raise CrateError {
      if i == 4 {
        raise CrateError("cancelled", "ordinary storage finish error")
      }
    })
    let events : Array[BatchProgress] = []
    let controlled = audit_batch_with_control(
      manifest,
      load,
      observe,
      read,
      fn(e) {
        events.push(e)
        true
      },
      finish~,
    )
    let end_event = events[events.length() - 1]
    assert_eq(end_event.phase, "finalize")
    assert_eq(end_event.completed_tasks, 6)
    assert_eq(end_event.pass_tasks, 2)
    assert_eq(end_event.partial_pass_tasks, 1)
    assert_eq(end_event.failed_tasks, 1)
    assert_eq(end_event.error_tasks, 2)
    assert_eq(end_event.read_calls, read_calls)
    assert_eq(end_event.validated_read_bytes, read_bytes)
    let mut previous_completed = 0
    let mut previous_calls = 0L
    let mut previous_bytes = 0L
    for e in events {
      assert_true(
        e.completed_tasks >= previous_completed &&
        e.completed_tasks <= e.task_count,
      )
      assert_eq(
        e.completed_tasks,
        e.pass_tasks + e.partial_pass_tasks + e.failed_tasks + e.error_tasks,
      )
      assert_true(
        e.read_calls >= previous_calls &&
        e.validated_read_bytes >= previous_bytes,
      )
      previous_completed = e.completed_tasks
      previous_calls = e.read_calls
      previous_bytes = e.validated_read_bytes
      if e.verification is Some(v) {
        assert_eq(e.phase, "verification")
        assert_true(e.task_index != None && e.task_id != None)
        if v.phase == "start" {
          assert_eq(v.read_calls, 0)
          assert_eq(v.validated_read_bytes, 0L)
        }
      }
      assert_eq(
        batch_test_field(batch_progress_json(e), "manifest_sha256"),
        Json::string(e.manifest_sha256),
      )
    }
    assert_eq(
      batch_audit_json_text(controlled),
      batch_audit_json_text(audit_batch(manifest, load, observe, read, finish~)),
    )
  }
}

///|
test "global batch cancellation and observer errors escape every task boundary and final result gate" {
  let phases = [
    "start", "before_task", "after_load", "before_observe", "verification/start",
    "verification/before_read", "verification/after_read", "verification/check",
    "verification/finalize", "before_finish", "task_complete", "last_complete", "before_summary",
    "finalize",
  ]
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      [{ path: ["a"], length: 1L, }],
      { ..create_options("bundle"), mode, piece_length: 16384, },
      fn(_, _, _) { b"x" },
    )
    let manifest = batch_test_manifest([
      batch_test_task("first"),
      batch_test_task("later"),
    ])
    for phase in phases {
      for action in ["cancel", "observer", "named-cancelled"] {
        let loaded : Array[Int32] = []
        let mut matched = false
        let mut final_count = 0
        let code = try {
          ignore(
            audit_batch_with_control(
              manifest,
              fn(i, _) {
                loaded.push(i)
                torrent
              },
              fn(_, _, _) { [Some(1L)] },
              fn(_, _, _, _) { b"x" },
              fn(e) raise CrateError {
                let hit = if phase == "last_complete" {
                  e.phase == "task_complete" &&
                  e.completed_tasks == e.task_count
                } else {
                  batch_control_key(e) == phase
                }
                if hit {
                  matched = true
                  final_count = e.completed_tasks
                  if action != "cancel" {
                    raise CrateError(
                      if action == "observer" {
                        "observer"
                      } else {
                        "cancelled"
                      },
                      "observer sentinel",
                    )
                  }
                  false
                } else {
                  true
                }
              },
            ),
          )
          "returned"
        } catch {
          CrateError(code, detail) => {
            if action != "cancel" {
              assert_eq(detail, "observer sentinel")
            }
            code
          }
        }
        assert_true(matched)
        assert_eq(
          code,
          if action == "observer" {
            "observer"
          } else {
            "cancelled"
          },
        )
        if phase == "start" || phase == "before_task" {
          assert_true(loaded.is_empty())
        }
        if phase == "last_complete" ||
          phase == "before_summary" ||
          phase == "finalize" {
          assert_eq(final_count, 2)
          assert_eq(loaded, [0, 1])
        } else {
          assert_true(!loaded.contains(1))
        }
      }
    }
  }
}

///|
test "batch observer abort survives inner verification read-error recovery" {
  let torrent = create_torrent(
    [{ path: ["a"], length: 20000L, }],
    { ..create_options("bundle"), piece_length: 16384, },
    fn(_, _, n) { Bytes::make(n, 7) },
  )
  let manifest = batch_test_manifest([
    batch_test_task("broken"),
    batch_test_task("must-not-run"),
  ])
  for cancel in [true, false] {
    let mut reads = 0
    let mut loads = 0
    let mut seen = false
    let code = try {
      ignore(
        audit_batch_with_control(
          manifest,
          fn(_, _) {
            loads += 1
            torrent
          },
          fn(_, _, _) { [Some(20000L)] },
          fn(_, _, _, _) raise CrateError {
            reads += 1
            raise CrateError("io", "ordinary read failure")
          },
          fn(e) raise CrateError {
            if e.verification is Some(v) &&
              v.phase == "after_read" &&
              v.read_ok == Some(false) {
              seen = true
              if !cancel {
                raise CrateError("observer", "failure recovery observer")
              }
              false
            } else {
              true
            }
          },
        ),
      )
      "returned"
    } catch {
      CrateError(code, _) => code
    }
    assert_true(seen)
    assert_eq(code, if cancel { "cancelled" } else { "observer" })
    assert_eq(reads, 1)
    assert_eq(loads, 1)
  }
}

///|
test "batch task completion reports summary quota downgrades before allowing cancellation" {
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
  let mut completed = 0
  let mut errors = 0
  let code = try {
    ignore(
      audit_batch_with_control(
        manifest,
        fn(_, _) { torrent },
        fn(_, info, _) { info.files.map(fn(f) { Some(f.length) }) },
        fn(_, _, _, _) { b"x" },
        fn(e) {
          if e.phase == "task_complete" {
            completed = e.completed_tasks
            errors = e.error_tasks
            e.task_outcome != Some("ERROR")
          } else {
            true
          }
        },
        max_summary_bytes=12288,
      ),
    )
    "returned"
  } catch {
    CrateError(code, _) => code
  }
  assert_eq(code, "cancelled")
  assert_eq(completed, 1)
  assert_eq(errors, 1)
  let mut callbacks = 0
  assert_true(
    try {
      ignore(
        audit_batch_with_control(
          manifest,
          fn(_, _) { torrent },
          fn(_, _, _) { [] },
          fn(_, _, _, _) { b"" },
          fn(_) {
            callbacks += 1
            true
          },
          max_summary_bytes=1,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_eq(callbacks, 0)
}
