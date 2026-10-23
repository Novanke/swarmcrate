///|
test "selected verification reads v1 boundary neighbours but skips unrelated payload" {
  let data = [b"abc", Bytes::make(32769, 7), Bytes::make(40000, 9), b""]
  let files : Array[SourceFile] = [
    { path: ["a"], length: 3L, },
    { path: ["b"], length: 32769L, },
    { path: ["c"], length: 40000L, },
    { path: ["empty"], length: 0L, },
  ]
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      files,
      { ..create_options("bundle"), mode, piece_length: 16384, },
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
    )
    let scope = verification_scope(torrent, selected_files=Some([0, 0]))
    assert_true(!scope.complete)
    assert_eq(scope.selected_files, [0])
    assert_eq(scope.required_files, if mode == V1 { [0, 1] } else { [0] })
    let report = verify_payload(
      torrent,
      [Some(3L), Some(32769L), None, None],
      fn(i, o, n) raise CrateError {
        if i > 1 || (i == 1 && (mode != V1 || o + n.to_int64() > 16381L)) {
          raise CrateError("test", "read outside selected pieces")
        }
        data[i][o.to_int():o.to_int() + n].to_owned()
      },
      selected_files=Some([0]),
    )
    assert_true(report.ok)
    assert_true(report.file_issues.is_empty())
    assert_eq(report.checked_pieces, if mode == Hybrid { 2 } else { 1 })
    assert_eq(
      report.skipped_pieces,
      match mode {
        V1 => 4
        V2 => 6
        Hybrid => 12
      },
    )
    let unavailable = verify_payload(
      torrent,
      [Some(3L), None, None, None],
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
      selected_files=Some([0]),
    )
    assert_eq(unavailable.ok, mode != V1)
    if mode == V1 {
      assert_eq(unavailable.unreadable_pieces, 1)
      assert_eq(unavailable.file_issues[0].file, 1)
      assert_eq(unavailable.failures[0].spans[1].file, 1)
    }
    let empty = verify_payload(
      torrent,
      [None, None, None, None],
      fn(_, _, _) { b"" },
      selected_files=Some([3]),
    )
    assert_true(!empty.ok)
    assert_eq(empty.checked_pieces, 0)
    assert_eq(empty.file_issues[0].file, 3)
    for indices in [[], [-1], [4]] {
      assert_true(
        try {
          ignore(verification_scope(torrent, selected_files=Some(indices)))
          false
        } catch {
          _ => true
        },
      )
    }
    let all = verification_scope(torrent, selected_files=Some([3, 2, 1, 0, 3]))
    assert_true(all.complete)
    assert_eq(all.selected_files, [0, 1, 2, 3])
  }
}

///|
test "every nonempty selection accounts for all hashes without reading unrelated files" {
  let data = [Bytes::make(16385, 1), Bytes::make(32769, 2), b"x"]
  let files = data.mapi(fn(i, bytes) {
    SourceFile::{ path: [i.to_string()], length: bytes.length().to_int64(), }
  })
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      files,
      { ..create_options("bundle"), mode, piece_length: 32768, },
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
    )
    let sizes = data.map(fn(bytes) { Some(bytes.length().to_int64()) })
    let total = verify_payload(torrent, sizes, fn(i, o, n) {
        data[i][o.to_int():o.to_int() + n].to_owned()
      }).checked_pieces
    for mask in 1..<8 {
      let indices : Array[Int32] = []
      for i in 0..<3 {
        if (mask & (1 << i)) != 0 {
          indices.push(i)
        }
      }
      let scope = verification_scope(torrent, selected_files=Some(indices))
      let report = verify_payload(
        torrent,
        sizes,
        fn(i, o, n) raise CrateError {
          if !scope.required_files.contains(i) {
            raise CrateError("test", "unrelated read")
          }
          data[i][o.to_int():o.to_int() + n].to_owned()
        },
        selected_files=Some(indices),
      )
      assert_true(report.ok)
      assert_eq(report.checked_pieces + report.skipped_pieces, total)
      assert_eq(report.scope.complete, mask == 7)
    }
  }
}
