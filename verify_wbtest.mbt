///|
test "verification catches corruption missing empty files and failures at read boundaries" {
  let data = [Bytes::makei(33000, fn(i) { (i % 251).to_byte() }), b"abc", b""]
  let files : Array[SourceFile] = [
    { path: ["a"], length: 33000L, },
    { path: ["b"], length: 3L, },
    { path: ["empty"], length: 0L, },
  ]
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      files,
      { ..create_options("bundle"), mode, piece_length: 16384, },
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
    )
    let report = verify_payload(torrent, [Some(33000L), Some(3L), Some(0L)], fn(
      i,
      o,
      n,
    ) {
      data[i][o.to_int():o.to_int() + n].to_owned()
    })
    assert_true(report.ok)
    let corrupt = verify_payload(
      torrent,
      [Some(33000L), Some(3L), Some(0L)],
      fn(i, o, n) {
        let bytes = data[i][o.to_int():o.to_int() + n].to_array()
        if i == 0 && o == 16384L {
          bytes[0] = 255
        }
        Bytes::from_array(bytes)
      },
      detail_limit=1,
    )
    assert_true(!corrupt.ok)
    assert_eq(corrupt.failures[0].spans[0].offset, 16384L)
    assert_eq(corrupt.failures[0].reason, "hash_mismatch")
    let missing = verify_payload(torrent, [Some(33000L), Some(3L), None], fn(
      i,
      o,
      n,
    ) {
      data[i][o.to_int():o.to_int() + n].to_owned()
    })
    assert_true(!missing.ok)
    assert_eq(missing.file_issues[0].reason, "missing")
    let broken = verify_payload(torrent, [Some(33000L), Some(3L), Some(0L)], fn(
      _,
      _,
      _,
    ) raise CrateError {
      raise CrateError("io", "read failed")
    })
    assert_true(broken.unreadable_pieces > 0)
  }
}

///|
test "unreadable v1 pieces still read real neighbours and leave later hashes intact" {
  let left = Bytes::make(8, 0)
  let right = Bytes::makei(32762, fn(i) { (i % 251).to_byte() })
  let torrent = create_torrent(
    [{ path: ["left"], length: 8L, }, { path: ["right"], length: 32762L, }],
    { ..create_options("bundle"), mode: V1, piece_length: 16384, },
    fn(i, o, n) {
      let bytes = if i == 0 { left } else { right }
      bytes[o.to_int():o.to_int() + n].to_owned()
    },
  )
  let reads : Array[(Int32, Int64)] = []
  let report = verify_payload(torrent, [None, Some(32762L)], fn(i, o, n) {
    reads.push((i, o))
    right[o.to_int():o.to_int() + n].to_owned()
  })
  assert_eq(reads, [(1, 0L), (1, 16376L), (1, 32760L)])
  assert_eq(report.checked_pieces, 3)
  assert_eq(report.failed_pieces, 1)
  assert_eq(report.unreadable_pieces, 1)
  assert_eq(report.failures[0].reason, "unreadable")
  assert_eq(report.failures[0].spans.length(), 2)
  assert_eq(report.failures[0].spans[1].length, 16376)
  let unreadable_tail = verify_payload(torrent, [Some(8L), Some(32762L)], fn(
    i,
    o,
    n,
  ) raise CrateError {
    if i == 1 && o == 32760L {
      raise CrateError("io", "unreadable tail")
    }
    let bytes = if i == 0 { left } else { right }
    bytes[o.to_int():o.to_int() + n].to_owned()
  })
  assert_eq(unreadable_tail.checked_pieces, 3)
  assert_eq(unreadable_tail.failed_pieces, 1)
  assert_eq(unreadable_tail.unreadable_pieces, 1)
  assert_eq(unreadable_tail.failures[0].piece, 2)
  assert_eq(unreadable_tail.failures[0].reason, "unreadable")
}

///|
test "a failed v2 block affects only its piece and later pieces are still checked" {
  let data = Bytes::makei(98305, fn(i) { (i % 251).to_byte() })
  for mode in [V2, Hybrid] {
    let torrent = create_torrent(
      [{ path: ["data"], length: data.length().to_int64(), }],
      {
        ..create_options("data"),
        mode,
        single_file: true,
        piece_length: 32768,
      },
      fn(_, o, n) { data[o.to_int():o.to_int() + n].to_owned() },
    )
    for short_read in [false, true] {
      let report = verify_payload(torrent, [Some(data.length().to_int64())], fn(
        _,
        o,
        n,
      ) raise CrateError {
        if o == 32768L {
          if short_read {
            return b""
          }
          raise CrateError("io", "unreadable block")
        }
        let result = data[o.to_int():o.to_int() + n].to_array()
        if o == 65536L {
          result[0] = 255
        }
        Bytes::from_array(result)
      })
      let multiplier = if mode == Hybrid { 2 } else { 1 }
      assert_true(!report.ok)
      assert_eq(report.checked_pieces, 4 * multiplier)
      assert_eq(report.unreadable_pieces, multiplier)
      assert_eq(report.failed_pieces, 2 * multiplier)
      assert_eq(report.failures[0].piece, 1)
      assert_eq(report.failures[0].reason, "unreadable")
      assert_eq(report.failures[1].piece, 2)
      assert_eq(report.failures[1].reason, "hash_mismatch")
    }
  }
}
