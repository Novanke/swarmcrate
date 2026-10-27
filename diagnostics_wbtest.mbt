///|
test "file diagnostics merge hybrid hashes and keep shared unreadable v1 spans conservative" {
  let data = [Bytes::make(65537, 7), b"hello", b""]
  let files : Array[SourceFile] = [
    { path: ["a"], length: 65537L, },
    { path: ["b"], length: 5L, },
    { path: ["empty"], length: 0L, },
  ]
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      files,
      { ..create_options("bundle"), mode, piece_length: 16384, },
      fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
    )
    let (report, receipt) = verify_with_receipt(
      torrent,
      [Some(65537L), None, None],
      fn(i, o, n) raise CrateError {
        if i != 0 {
          raise CrateError("test", "missing files must not be read")
        }
        if o == 49152L {
          raise CrateError("io", "injected read fault")
        }
        if o == 16384L || o == 32768L {
          return Bytes::make(n, 0)
        }
        data[i][o.to_int():o.to_int() + n].to_owned()
      },
    )
    let summary = diagnostic_files(inspect_torrent(torrent), report)
    assert_eq(summary[0].hash_mismatch.map(fn(r) { (r.offset, r.length) }), [
      (16384L, 32768L),
    ])
    assert_eq(summary[0].unreadable.map(fn(r) { (r.offset, r.length) }), [
      (49152L, if mode == V1 { 16385L } else { 16384L }),
    ])
    assert_eq(
      diagnostic_range_bytes(summary[0].attention),
      if mode == V1 {
        49153L
      } else {
        49152L
      },
    )
    assert_eq(summary[1].missing.map(fn(r) { (r.offset, r.length) }), [(0L, 5L)])
    assert_eq(diagnostic_range_bytes(summary[1].attention), 5L)
    assert_true(file_has_diagnostic(summary[2]))
    assert_true(summary[2].attention.is_empty())
    let text = receipt_diagnostics_json_text(receipt)
    assert_true(text.contains("swarmcrate.diagnostics.v1"))
    assert_true(text.contains("\"ranges_complete\": true"))
    let saved = text
    report.failures.clear()
    report.file_issues.clear()
    assert_eq(receipt_diagnostics_json_text(receipt), saved)
  }
}

///|
test "size diagnostics distinguish missing tails extras and missing zero length files" {
  let data = [Bytes::make(33000, 7), b"abc", b""]
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
    let (report, _) = verify_with_receipt(
      torrent,
      [Some(15000L), Some(9L), None],
      fn(_, _, _) { abort("size mismatches must not read data") },
    )
    let summary = diagnostic_files(inspect_torrent(torrent), report)
    assert_eq(summary[0].missing.map(fn(r) { (r.offset, r.length) }), [
      (15000L, 18000L),
    ])
    assert_eq(summary[0].unreadable.map(fn(r) { (r.offset, r.length) }), [
      (0L, 33000L),
    ])
    assert_eq(diagnostic_range_bytes(summary[0].attention), 33000L)
    assert_eq(summary[1].extra.map(fn(r) { (r.offset, r.length) }), [(3L, 6L)])
    assert_eq(diagnostic_range_bytes(summary[1].attention), 3L)
    assert_true(summary[2].issue is Some("missing"))
    assert_true(summary[2].missing.is_empty())
    assert_true(file_has_diagnostic(summary[2]))
  }
}

///|
test "selected neighbours are partial and truncated inventories cannot be called complete" {
  let data = [b"abc", Bytes::make(40000, 7), b""]
  let files : Array[SourceFile] = [
    { path: ["a"], length: 3L, },
    { path: ["b"], length: 40000L, },
    { path: ["empty"], length: 0L, },
  ]
  let torrent = create_torrent(
    files,
    { ..create_options("bundle"), mode: V1, piece_length: 16384, },
    fn(i, o, n) { data[i][o.to_int():o.to_int() + n].to_owned() },
  )
  let (partial, _) = verify_with_receipt(
    torrent,
    [Some(3L), Some(40000L), None],
    fn(_, _, n) { Bytes::make(n, 0) },
    selected_files=Some([0]),
  )
  let rows = diagnostic_files(inspect_torrent(torrent), partial)
  assert_eq(rows.length(), 2)
  assert_true(rows[0].selected && !rows[1].selected)
  assert_eq(rows[1].attention.map(fn(r) { (r.offset, r.length) }), [
    (0L, 16381L),
  ])
  let (truncated, receipt) = verify_with_receipt(
    torrent,
    [Some(3L), Some(40000L), None],
    fn(_, _, n) { Bytes::make(n, 0) },
    detail_limit=1,
  )
  assert_true(truncated.details_truncated)
  assert_eq(truncated.failures.length(), 1)
  let text = receipt_diagnostics_json_text(receipt)
  assert_true(text.contains("\"ranges_complete\": false"))
  assert_true(text.contains("\"omitted_failure_checks\": 2"))
  let html = verification_html(inspect_torrent(torrent), truncated)
  assert_true(html.contains("INCOMPLETE"))
  assert_true(html.contains("Per-file attention ranges"))
  let (_, empty) = verify_with_receipt(
    torrent,
    [None, None, None],
    fn(_, _, _) { abort("empty selection must not read") },
    selected_files=Some([2]),
  )
  assert_true(
    receipt_diagnostics_json_text(empty).contains(
      "\"has_recorded_issue\": true",
    ),
  )
}

///|
test "interval unions agree with a byte bitmap and preserve 64 bit endpoints" {
  for seed in 0..<64 {
    let input : Array[DiagnosticRange] = []
    let bitmap = Array::make(64, false)
    for i in 0..<17 {
      let offset = (seed * 7 + i * 11) % 64
      let length = (seed + i * 3) % (65 - offset)
      input.push({ offset: offset.to_int64(), length: length.to_int64(), })
      for j in offset..<(offset + length) {
        bitmap[j] = true
      }
    }
    let merged = merge_diagnostic_ranges(input)
    let restored = Array::make(64, false)
    let mut previous_end = -1L
    for range in merged {
      assert_true(range.offset > previous_end && range.length > 0L)
      previous_end = range.offset + range.length
      for i in range.offset.to_int()..<previous_end.to_int() {
        restored[i] = true
      }
    }
    assert_eq(restored, bitmap)
    assert_eq(
      diagnostic_range_bytes(merged),
      bitmap.filter(fn(b) { b }).length().to_int64(),
    )
  }
  let large = merge_diagnostic_ranges([
    { offset: 9007199254740980L, length: 11L, },
    { offset: 9007199254740979L, length: 1L, },
    { offset: 9007199254740981L, length: 1L, },
  ])
  assert_eq(large.map(fn(r) { (r.offset, r.length) }), [
    (9007199254740979L, 12L),
  ])
  assert_true(
    diagnostic_ranges_json(large).stringify().contains("9007199254740979"),
  )
}
