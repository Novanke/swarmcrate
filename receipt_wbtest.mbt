///|
test "receipt binds exact metadata and freezes the report and caller size mapping" {
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
    let sizes : Array[Int64?] = [Some(3L), Some(32769L), Some(0L)]
    let (report, receipt) = verify_with_receipt(
      torrent,
      sizes,
      fn(i, o, n) {
        // A callback can mutate the original array; the receipt factory must own its mapping.
        sizes[0] = None
        sizes[1] = None
        data[i][o.to_int():o.to_int() + n].to_owned()
      },
      selected_files=Some([0, 0]),
    )
    assert_true(report.ok && !report.scope.complete)
    assert_eq(
      report.scope.required_files,
      if mode == V1 {
        [0, 1]
      } else {
        [0]
      },
    )
    let text = receipt_json_text(receipt)
    assert_true(
      text.contains(@crypto.bytes_to_hex_string(@crypto.sha256(torrent))),
    )
    let info = inspect_torrent(torrent)
    for hash in [info.info_hash_v1, info.info_hash_v2] {
      if hash is Some(hash) {
        assert_true(text.contains(hash))
      }
    }
    assert_true(text.contains("\"outcome\": \"PARTIAL_PASS\""))
    assert_true(text.contains("\"actual_bytes\": \"3\""))
    assert_eq(text.contains("\"actual_bytes\": \"32769\""), mode == V1)
    assert_true(!text.contains("\"actual_bytes\": \"0\""))
    report.scope.selected_files.clear()
    report.scope.required_files.clear()
    report.failures.push({
      scheme: "modified",
      piece: 0,
      spans: [],
      reason: "caller edit",
    })
    assert_eq(receipt_json_text(receipt), text)
    assert_true(!text.contains("caller edit"))
  }
}

///|
test "receipt distinguishes complete success failure and missing empty files with bounded details" {
  let data = [Bytes::make(32769, 7), b""]
  let files : Array[SourceFile] = [
    { path: ["data"], length: 32769L, },
    { path: ["empty"], length: 0L, },
  ]
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      files,
      { ..create_options("bundle"), mode, piece_length: 16384, },
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
    )
    let (_, pass) = verify_with_receipt(torrent, [Some(32769L), Some(0L)], fn(
      i,
      o,
      n,
    ) {
      data[i][o.to_int():o.to_int() + n].to_owned()
    })
    assert_true(receipt_json_text(pass).contains("\"outcome\": \"PASS\""))
    let (failed, receipt) = verify_with_receipt(
      torrent,
      [Some(32769L), Some(0L)],
      fn(_, _, n) { Bytes::make(n, 0) },
      detail_limit=1,
    )
    assert_true(!failed.ok && failed.details_truncated)
    assert_eq(failed.failures.length(), 1)
    assert_eq(failed.failed_pieces, if mode == Hybrid { 6 } else { 3 })
    assert_true(receipt_json_text(receipt).contains("\"outcome\": \"FAIL\""))
    assert_true(
      receipt_json_text(receipt).contains("\"details_truncated\": true"),
    )
    let (missing, receipt) = verify_with_receipt(
      torrent,
      [None, None],
      fn(_, _, _) { abort("empty selection must not read") },
      selected_files=Some([1]),
    )
    assert_true(!missing.ok && !missing.scope.complete)
    assert_eq(missing.checked_pieces, 0)
    assert_eq(missing.file_issues[0].file, 1)
    let text = receipt_json_text(receipt)
    assert_true(text.contains("\"actual_bytes\": null"))
    assert_true(text.contains("\"is_digital_signature\": false"))
    assert_true(text.contains("\"publisher_authenticated\": false"))
  }
}

///|
test "distribution edits retain infohash but invalidate exact metainfo receipt identity" {
  let data = b"hello"
  let torrent = create_torrent(
    [{ path: ["hello"], length: 5L, }],
    { ..create_options("hello"), single_file: true, },
    fn(_, o, n) { data[o.to_int():o.to_int() + n].to_owned() },
  )
  let edited = edit_distribution(torrent, [["https://example.org/announce"]], [])
  assert_eq(
    inspect_torrent(torrent).info_hash_v1,
    inspect_torrent(edited).info_hash_v1,
  )
  assert_eq(
    inspect_torrent(torrent).info_hash_v2,
    inspect_torrent(edited).info_hash_v2,
  )
  let (_, first) = verify_with_receipt(torrent, [Some(5L)], fn(_, o, n) {
    data[o.to_int():o.to_int() + n].to_owned()
  })
  let (_, repeat) = verify_with_receipt(torrent, [Some(5L)], fn(_, o, n) {
    data[o.to_int():o.to_int() + n].to_owned()
  })
  let (_, second) = verify_with_receipt(edited, [Some(5L)], fn(_, o, n) {
    data[o.to_int():o.to_int() + n].to_owned()
  })
  assert_eq(receipt_json_text(first), receipt_json_text(repeat))
  assert_true(receipt_json_text(first) != receipt_json_text(second))
  assert_true(
    !receipt_json_text(second).contains("https://example.org/announce"),
  )
}
