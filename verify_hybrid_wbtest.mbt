///|
test "hybrid verification reads every selected real byte once including short padded tails" {
  for piece in [16384, 32768, 1048576, 2097152, 16777216] {
    for trailing_empty in [false, true] {
      let data = [Bytes::make(2097169, 7), b"abc"]
      if trailing_empty {
        data.push(b"")
      }
      let files = data.mapi(fn(i, b) {
        SourceFile::{ path: [i.to_string()], length: b.length().to_int64(), }
      })
      let torrent = create_torrent(
        files,
        { ..create_options("bundle"), mode: Hybrid, piece_length: piece, },
        fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
      )
      for selected in [None, Some([0]), Some([1])] {
        let positions = Array::make(data.length(), 0L)
        let mut bytes_read = 0L
        let report = verify_payload(
          torrent,
          data.map(fn(b) { Some(b.length().to_int64()) }),
          fn(i, o, n) raise CrateError {
            if o != positions[i] ||
              n > 1048576 ||
              (selected is Some(indices) && !indices.contains(i)) {
              raise CrateError("test", "repeated, unbounded or unselected read")
            }
            positions[i] += n.to_int64()
            bytes_read += n.to_int64()
            data[i][o.to_int():o.to_int() + n].to_owned()
          },
          selected_files=selected,
        )
        assert_true(report.ok)
        let mut expected_bytes = 0L
        let mut expected_checks = 0
        for i, b in data {
          if selected is None ||
            (selected is Some(indices) && indices.contains(i)) {
            expected_bytes += b.length().to_int64()
            expected_checks += (b.length() + piece - 1) / piece * 2
          }
        }
        assert_eq(bytes_read, expected_bytes)
        assert_eq(report.checked_pieces, expected_checks)
      }
    }
  }
  let content = Bytes::make(33000, 7)
  let torrent = create_torrent(
    [{ path: ["data"], length: 33000L, }],
    {
      ..create_options("data"),
      mode: Hybrid,
      single_file: true,
      piece_length: 16384,
    },
    fn(_, o, n) { content[o.to_int():o.to_int() + n].to_owned() },
  )
  let calls : Array[Int64] = []
  let mut transient = true
  let report = verify_payload(torrent, [Some(33000L)], fn(
    _,
    o,
    n,
  ) raise CrateError {
    calls.push(o)
    if transient {
      transient = false
      raise CrateError("io", "one-time read failure")
    }
    content[o.to_int():o.to_int() + n].to_owned()
  })
  assert_eq(calls, [0L, 16384L, 32768L])
  assert_eq(report.checked_pieces, 6)
  assert_eq(report.failed_pieces, 2)
  assert_eq(report.unreadable_pieces, 2)
}

///|
test "one-pass hybrid diagnostics agree with independent v1 and v2 verification passes" {
  let data = [Bytes::make(2097169, 7), b"abc", b""]
  let files = data.mapi(fn(i, b) {
    SourceFile::{ path: [i.to_string()], length: b.length().to_int64(), }
  })
  let torrent = create_torrent(
    files,
    { ..create_options("bundle"), mode: Hybrid, piece_length: 2097152, },
    fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
  )
  let parsed = parse_torrent(torrent)
  for fault in ["corrupt", "throw", "short", "oversized", "size", "missing"] {
    for selected in [None, Some([1])] {
      let sizes : Array[Int64?] = [Some(2097169L), Some(3L), Some(0L)]
      if fault == "size" {
        sizes[0] = Some(2097168L)
      }
      if fault == "missing" {
        sizes[0] = None
      }
      let read = fn(i : Int32, o : Int64, n : Int32) raise CrateError {
        if i == 0 && o == 1048576L {
          if fault == "throw" {
            raise CrateError("io", "injected failure")
          }
          if fault == "short" {
            return b""
          }
          if fault == "oversized" {
            return Bytes::make(n + 1, 0)
          }
        }
        if fault == "corrupt" && i == 0 {
          return Bytes::make(n, 9)
        }
        data[i][o.to_int():o.to_int() + n].to_owned()
      }
      for limit in [1, 3, 100] {
        let plan = plan_verification(parsed, selected)
        let separate : VerifyState = {
          checked: 0,
          skipped: 0,
          failed: 0,
          unreadable: 0,
          failures: [],
          limit,
        }
        verify_v1(parsed, plan.v1_pieces, sizes, read, separate)
        verify_v2(parsed, plan.selected, sizes, read, separate)
        let report = verify_payload(
          torrent,
          sizes,
          read,
          detail_limit=limit,
          selected_files=selected,
        )
        let reference = {
          ..report,
          checked_pieces: separate.checked,
          skipped_pieces: separate.skipped,
          failed_pieces: separate.failed,
          unreadable_pieces: separate.unreadable,
          failures: separate.failures,
          details_truncated: separate.failed > separate.failures.length(),
        }
        assert_eq(
          verification_json(report).stringify(),
          verification_json(reference).stringify(),
        )
      }
    }
  }
}

///|
test "shared hybrid input must still independently match both expected hash schemes" {
  let torrent = create_torrent(
    [{ path: ["data"], length: 3L, }],
    { ..create_options("data"), mode: Hybrid, single_file: true, },
    fn(_, _, _) { b"abc" },
  )
  for sha1_only in [false, true] {
    let top = decode_bencode(torrent)
    let info = require_key(top, "info")
    let fields = if sha1_only {
      dict_pairs(info)
    } else {
      dict_pairs(
        require_key(require_key(require_key(info, "file tree"), "data"), ""),
      )
    }
    for i, (key, _) in fields {
      if key == (if sha1_only { b"pieces" } else { b"pieces root" }) {
        fields[i] = (
          key,
          bn(Blob(Bytes::make(if sha1_only { 20 } else { 32 }, 0))),
        )
      }
    }
    let report = verify_payload(encode_bencode(top), [Some(3L)], fn(_, _, _) {
      b"abc"
    })
    assert_true(!report.ok)
    assert_eq(report.checked_pieces, 2)
    assert_eq(report.failed_pieces, 1)
    assert_eq(report.unreadable_pieces, 0)
    assert_eq(
      report.failures[0].scheme,
      if sha1_only {
        "sha1"
      } else {
        "sha256"
      },
    )
  }
  // An early SHA-256-only error must not displace a later SHA-1 error when
  // preserving the established grouped report order under a small detail cap.
  let mixed = create_torrent(
    [{ path: ["a"], length: 3L, }, { path: ["b"], length: 3L, }],
    { ..create_options("bundle"), mode: Hybrid, piece_length: 16384, },
    fn(_, _, _) { b"abc" },
  )
  let top = decode_bencode(mixed)
  let info = require_key(top, "info")
  let fields = dict_pairs(info)
  for i, (key, value) in fields {
    if key == b"pieces" {
      let hashes = as_blob(value).to_array()
      for j in 20..<40 {
        hashes[j] = 0
      }
      fields[i] = (key, bn(Blob(Bytes::from_array(hashes))))
    }
  }
  let first = dict_pairs(
    require_key(require_key(require_key(info, "file tree"), "a"), ""),
  )
  for i, (key, _) in first {
    if key == b"pieces root" {
      first[i] = (key, bn(Blob(Bytes::make(32, 0))))
    }
  }
  let changed = encode_bencode(top)
  for limit in [1, 2] {
    let report = verify_payload(
      changed,
      [Some(3L), Some(3L)],
      fn(_, _, _) { b"abc" },
      detail_limit=limit,
    )
    assert_eq(report.failed_pieces, 2)
    assert_eq(report.failures.length(), limit)
    assert_eq(report.failures[0].scheme, "sha1")
    assert_eq(report.failures[0].piece, 1)
    assert_eq(report.details_truncated, limit == 1)
    if limit == 2 {
      assert_eq(report.failures[1].scheme, "sha256")
    }
  }
}
