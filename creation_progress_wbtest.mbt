///|
test "controlled creation preserves canonical bytes original indices and one real read pass" {
  let data = [Bytes::make(2097169, 7), b"abc", b""]
  let files : Array[SourceFile] = [
    { path: ["b"], length: 2097169L, },
    { path: ["a"], length: 3L, },
    { path: ["z-empty"], length: 0L, },
  ]
  for mode in [V1, V2, Hybrid] {
    let options = { ..create_options("bundle"), mode, piece_length: 2097152, }
    let positions = Array::make(3, 0L)
    let events : Array[CreationProgress] = []
    let created = create_torrent_with_control(
      files,
      options,
      fn(i, o, n) raise CrateError {
        if o != positions[i] || n > 1048576 {
          raise CrateError("test", "repeated or oversized read")
        }
        positions[i] += n.to_int64()
        data[i][o.to_int():o.to_int() + n].to_owned()
      },
      fn(event) {
        events.push(event)
        true
      },
    )
    let legacy = create_torrent(files, options, fn(i, o, n) {
      data[i][o.to_int():o.to_int() + n].to_owned()
    })
    assert_eq(created, legacy)
    assert_eq(positions, [2097169L, 3L, 0L])
    assert_eq(events[0].phase, "start")
    assert_eq(events[1].file, Some(1))
    let last = events[events.length() - 1]
    assert_eq(last.phase, "finalize")
    assert_eq(last.metainfo_bytes, Some(created.length()))
    assert_eq(last.validated_read_bytes, 2097172L)
    assert_eq(last.total_bytes, 2097172L)
    assert_eq(last.file_count, 3)
    let mut bytes = 0L
    let mut reads = 0
    for event in events {
      assert_true(
        event.validated_read_bytes >= bytes &&
        event.validated_read_bytes <= event.total_bytes,
      )
      assert_true(event.read_calls >= reads)
      assert_eq(event.mode, mode)
      if event.phase == "before_encode" {
        assert_eq(event.validated_read_bytes, event.total_bytes)
      }
      bytes = event.validated_read_bytes
      reads = event.read_calls
    }
  }
}

///|
test "creation cancellation and observer errors never return metainfo even after encoding" {
  let data = Bytes::make(2097169, 7)
  for mode in [V1, V2, Hybrid] {
    for
      phase in [
        "start", "before_read", "after_read", "before_encode", "finalize",
      ] {
      for observer_error in [false, true] {
        let mut reads = 0
        let mut stops = 0
        let code = try {
          ignore(
            create_torrent_with_control(
              [{ path: ["file"], length: 2097169L, }],
              {
                ..create_options("file"),
                mode,
                single_file: true,
                piece_length: 2097152,
              },
              fn(_, o, n) {
                reads += 1
                data[o.to_int():o.to_int() + n].to_owned()
              },
              fn(event) raise CrateError {
                if event.phase == phase {
                  stops += 1
                  if observer_error {
                    raise CrateError("observer", "creation observer detail")
                  }
                  return false
                }
                true
              },
            ),
          )
          "returned"
        } catch {
          CrateError(code, detail) => {
            if observer_error {
              assert_eq(detail, "creation observer detail")
            }
            code
          }
        }
        assert_eq(code, if observer_error { "observer" } else { "cancelled" })
        assert_eq(stops, 1)
        assert_eq(
          reads,
          match phase {
            "start" | "before_read" => 0
            "after_read" => 1
            _ => 3
          },
        )
      }
    }
  }
}

///|
test "creation read failures and invalid planning stop without encoding or completion events" {
  for mode in [V1, V2, Hybrid] {
    for fault in ["short", "long", "error"] {
      let phases : Array[String] = []
      let code = try {
        ignore(
          create_torrent_with_control(
            [{ path: ["file"], length: 32769L, }],
            {
              ..create_options("file"),
              mode,
              single_file: true,
              piece_length: 16384,
            },
            fn(_, _, n) raise CrateError {
              if fault == "error" {
                raise CrateError("source", "read failed")
              }
              Bytes::make(if fault == "short" { n - 1 } else { n + 1 }, 7)
            },
            fn(event) {
              phases.push(event.phase)
              true
            },
          ),
        )
        "returned"
      } catch {
        CrateError(code, _) => code
      }
      assert_eq(code, if fault == "error" { "source" } else { "read" })
      assert_eq(phases, ["start", "before_read"])
    }
  }
  let mut events = 0
  assert_true(
    try {
      ignore(
        create_torrent_with_control(
          [{ path: ["file"], length: 1L, }],
          { ..create_options("file"), piece_length: 1, },
          fn(_, _, _) { abort("invalid plan read") },
          fn(_) {
            events += 1
            true
          },
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_eq(events, 0)
}

///|
test "controlled creation freezes path and endpoint arrays before observers run" {
  for mode in [V1, V2, Hybrid] {
    let files : Array[SourceFile] = [{ path: ["a"], length: 3L, }]
    let options = {
      ..create_options("bundle"),
      mode,
      trackers: [["https://example.org/original"]],
      web_seeds: ["https://example.org/files/"],
    }
    let torrent = create_torrent_with_control(
      files,
      options,
      fn(_, _, _) { b"abc" },
      fn(event) {
        if event.phase == "start" {
          files[0].path[0] = "changed"
          files[0] = { path: ["replacement"], length: 1L, }
          options.trackers[0][0] = "https://example.org/changed"
          options.web_seeds[0] = "https://example.org/changed/"
        }
        true
      },
    )
    let info = inspect_torrent(torrent)
    assert_eq(info.files[0].path, ["a"])
    assert_eq(info.files[0].length, 3L)
    assert_eq(info.trackers, [["https://example.org/original"]])
    assert_eq(info.web_seeds, ["https://example.org/files/"])
  }
}
