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
