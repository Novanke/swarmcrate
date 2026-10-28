///|
test "controlled verification is monotone and matches legacy full subset and empty reports" {
  let data = [b"abc", Bytes::make(32769, 7), b""]
  let files : Array[SourceFile] = data.mapi(fn(i, b) {
    { path: [i.to_string()], length: b.length().to_int64(), }
  })
  for mode in [V1, V2, Hybrid] {
    let read = fn(i : Int32, o : Int64, n : Int32) raise CrateError {
      if n < 0 {
        raise CrateError("test", "invalid read")
      }
      data[i][o.to_int():o.to_int() + n].to_owned()
    }
    let torrent = create_torrent(
      files,
      { ..create_options("bundle"), mode, piece_length: 16384, },
      read,
    )
    for selection in [None, Some([0]), Some([2])] {
      let events : Array[VerificationProgress] = []
      let (report, receipt) = verify_with_control(
        torrent,
        [Some(3L), Some(32769L), Some(0L)],
        read,
        fn(event) {
          events.push(event)
          true
        },
        selected_files=selection,
      )
      let legacy = verify_payload(
        torrent,
        [Some(3L), Some(32769L), Some(0L)],
        read,
        selected_files=selection,
      )
      assert_eq(
        verification_json(report).stringify(),
        verification_json(legacy).stringify(),
      )
      assert_eq(events[0].phase, "start")
      let last = events[events.length() - 1]
      assert_eq(last.phase, "finalize")
      assert_eq(last.checked_pieces, report.checked_pieces)
      assert_eq(last.total_checks, report.checked_pieces)
      assert_eq(last.failed_pieces, 0)
      assert_eq(last.complete_scope, report.scope.complete)
      let mut checked = 0
      let mut bytes = 0L
      let mut reads = 0
      for event in events {
        assert_true(
          event.checked_pieces >= checked &&
          event.checked_pieces <= event.total_checks,
        )
        assert_true(
          event.validated_read_bytes >= bytes && event.read_calls >= reads,
        )
        if event.phase == "before_read" {
          assert_true(
            event.file is Some(_) &&
            event.offset is Some(_) &&
            event.length is Some(_),
          )
          assert_true(event.length.unwrap() <= 1048576)
          assert_true(event.read_ok is None)
        }
        if event.phase == "after_read" {
          assert_eq(event.read_ok, Some(true))
        }
        checked = event.checked_pieces
        bytes = event.validated_read_bytes
        reads = event.read_calls
      }
      assert_eq(
        last.validated_read_bytes,
        if selection is Some([2]) {
          0L
        } else if selection is Some([0]) {
          if mode == V1 {
            16384L
          } else {
            3L
          }
        } else {
          32772L
        },
      )
      assert_true(receipt_json_text(receipt).contains("swarmcrate.receipt.v1"))
    }
  }
}

///|
test "cancel and observer errors escape per-piece catches at every checkpoint without a receipt" {
  let data = Bytes::make(2097169, 7)
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      [{ path: ["file"], length: data.length().to_int64(), }],
      {
        ..create_options("file"),
        mode,
        single_file: true,
        piece_length: 2097152,
      },
      fn(_, o, n) { data[o.to_int():o.to_int() + n].to_owned() },
    )
    for phase in ["start", "before_read", "after_read", "check", "finalize"] {
      for observer_error in [false, true] {
        let mut reads = 0
        let mut stops = 0
        let mut returned = false
        let code = try {
          ignore(
            verify_with_control(
              torrent,
              [Some(data.length().to_int64())],
              fn(_, o, n) {
                reads += 1
                data[o.to_int():o.to_int() + n].to_owned()
              },
              fn(event) raise CrateError {
                if event.phase == phase {
                  stops += 1
                  if observer_error {
                    raise CrateError("observer", "exact observer detail")
                  }
                  return false
                }
                true
              },
            ),
          )
          returned = true
          "returned"
        } catch {
          CrateError(code, detail) => {
            if observer_error {
              assert_eq(detail, "exact observer detail")
            }
            code
          }
        }
        assert_eq(code, if observer_error { "observer" } else { "cancelled" })
        assert_true(!returned)
        assert_eq(stops, 1)
        assert_eq(
          reads,
          match phase {
            "start" | "before_read" => 0
            "after_read" => 1
            "check" => 2
            _ => 3
          },
        )
      }
    }
  }
}

///|
test "ordinary reader errors including cancelled codes remain unreadable checks and continue" {
  let data = Bytes::make(49153, 7)
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      [{ path: ["file"], length: 49153L, }],
      {
        ..create_options("file"),
        mode,
        single_file: true,
        piece_length: 16384,
      },
      fn(_, o, n) { data[o.to_int():o.to_int() + n].to_owned() },
    )
    for short in [false, true] {
      let events : Array[VerificationProgress] = []
      let (report, _) = verify_with_control(
        torrent,
        [Some(49153L)],
        fn(_, o, n) raise CrateError {
          if o == 16384L {
            if short {
              return b""
            }
            raise CrateError(
              "cancelled", "this is a reader failure, not observer cancellation",
            )
          }
          data[o.to_int():o.to_int() + n].to_owned()
        },
        fn(event) {
          events.push(event)
          true
        },
        detail_limit=1,
      )
      let last = events[events.length() - 1]
      assert_eq(last.phase, "finalize")
      assert_eq(last.read_calls, 4)
      assert_eq(last.validated_read_bytes, 32769L)
      assert_eq(last.failed_pieces, if mode == Hybrid { 2 } else { 1 })
      assert_eq(last.unreadable_pieces, report.unreadable_pieces)
      assert_eq(last.checked_pieces, last.total_checks)
      assert_eq(events.filter(fn(e) { e.read_ok == Some(false) }).length(), 1)
      assert_true(!report.ok)
      assert_eq(report.details_truncated, mode == Hybrid)
    }
  }
}

///|
test "missing files allow check cancellation and empty selections allow finalization cancellation" {
  let torrent = create_torrent(
    [{ path: ["data"], length: 32769L, }, { path: ["empty"], length: 0L, }],
    { ..create_options("bundle"), piece_length: 16384, },
    fn(_, _, n) { Bytes::make(n, 7) },
  )
  for selection in [None, Some([1])] {
    let mut checks = 0
    let code = try {
      ignore(
        verify_with_control(
          torrent,
          [None, None],
          fn(_, _, _) { abort("unavailable data must not read") },
          fn(event) {
            if event.phase == "check" {
              checks += 1
              return false
            }
            event.phase != "finalize"
          },
          selected_files=selection,
        ),
      )
      "returned"
    } catch {
      CrateError(code, _) => code
    }
    assert_eq(code, "cancelled")
    assert_eq(checks, if selection is None { 1 } else { 0 })
  }
}

///|
test "observer cancellation or error after a failed read takes precedence over piece recovery" {
  let torrent = create_torrent(
    [{ path: ["file"], length: 32769L, }],
    { ..create_options("file"), single_file: true, piece_length: 16384, },
    fn(_, _, n) { Bytes::make(n, 7) },
  )
  for observer_error in [false, true] {
    let mut reads = 0
    let code = try {
      ignore(
        verify_with_control(
          torrent,
          [Some(32769L)],
          fn(_, _, _) raise CrateError {
            reads += 1
            raise CrateError("io", "read failure")
          },
          fn(event) raise CrateError {
            if event.read_ok == Some(false) {
              if observer_error {
                raise CrateError("observer", "after failed read")
              }
              return false
            }
            true
          },
        ),
      )
      "returned"
    } catch {
      CrateError(code, _) => code
    }
    assert_eq(code, if observer_error { "observer" } else { "cancelled" })
    assert_eq(reads, 1)
  }
}
