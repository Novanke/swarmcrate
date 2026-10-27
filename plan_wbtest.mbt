///|
test "planning distinguishes real bytes virtual data padding and both hash layouts" {
  let data = [Bytes::make(8193, 7), Bytes::make(8193, 9), b""]
  let files : Array[SourceFile] = [
    { path: ["b"], length: 8193L, },
    { path: ["a"], length: 8193L, },
    { path: ["z-empty"], length: 0L, },
  ]
  for mode in [V1, V2, Hybrid] {
    let options = { ..create_options("bundle"), mode, piece_length: 16384, }
    let planned = plan_torrent(files, options)
    assert_eq(planned.real_bytes, 16386L)
    assert_eq(planned.file_count, 3)
    assert_eq(planned.empty_files, 1)
    assert_eq(planned.padding_bytes, if mode == Hybrid { 16382L } else { 0L })
    assert_eq(
      planned.storage_bytes,
      if mode == Hybrid {
        32768L
      } else {
        16386L
      },
    )
    assert_eq(planned.v1_pieces, if mode == V2 { 0 } else { 2 })
    assert_eq(planned.v2_pieces, if mode == V1 { 0 } else { 2 })
    assert_eq(planned.v1_hash_bytes, if mode == V2 { 0L } else { 40L })
    assert_eq(planned.v2_piece_layer_bytes_upper_bound, 0L)
    let torrent = create_torrent(files, options, fn(i, o, n) {
      data[i][o.to_int():o.to_int() + n].to_owned()
    })
    assert_eq(torrent_storage_bytes(torrent), planned.storage_bytes)
    assert_eq(
      expected_v1_pieces(torrent).length().to_int64(),
      planned.v1_hash_bytes,
    )
    assert_true(plan_json(planned).stringify().contains("swarmcrate.plan.v1"))
  }
  // Last in canonical path order, rather than last supplied input, avoids padding.
  let no_empty = plan_torrent(
    [{ path: ["z"], length: 8193L, }, { path: ["a"], length: 8193L, }],
    { ..create_options("bundle"), piece_length: 16384, },
  )
  assert_eq(no_empty.padding_bytes, 8191L)
  assert_eq(no_empty.storage_bytes, 24577L)
  let single = plan_torrent([{ path: ["one"], length: 8193L, }], {
    ..create_options("one"),
    single_file: true,
    piece_length: 16384,
  })
  assert_eq(single.padding_bytes, 0L)
  assert_eq(single.v1_pieces, 1)
  assert_eq(single.v2_pieces, 1)
}

///|
test "piece layer planning is an honest upper bound before duplicate roots are known" {
  let files : Array[SourceFile] = [
    { path: ["a"], length: 32769L, },
    { path: ["b"], length: 32769L, },
  ]
  for mode in [V2, Hybrid] {
    let options = { ..create_options("duplicates"), mode, piece_length: 16384, }
    let planned = plan_torrent(files, options)
    assert_eq(planned.v2_pieces, 6)
    assert_eq(planned.v2_piece_layer_bytes_upper_bound, 192L)
    let torrent = create_torrent(files, options, fn(_, _, n) {
      Bytes::make(n, 7)
    })
    let layers = dict_pairs(
      require_key(decode_bencode(torrent), "piece layers"),
    )
    assert_eq(layers.length(), 1)
    assert_eq(as_blob(layers[0].1).length(), 96)
    assert_true(
      plan_json(planned).stringify().contains("\"real_bytes\":\"65538\""),
    )
  }
}

///|
test "planning enforces exact piece limits and creation rejects before reading data" {
  for mode in [V1, V2, Hybrid] {
    let options = {
      ..create_options("large"),
      mode,
      single_file: true,
      piece_length: 16777216,
    }
    let exact = [{ path: ["large"], length: 6710886400000L, }]
    let planned = plan_torrent(exact, options)
    assert_eq(planned.v1_pieces, if mode == V2 { 0 } else { 400000 })
    assert_eq(planned.v2_pieces, if mode == V1 { 0 } else { 400000 })
    assert_true(
      try {
        ignore(
          plan_torrent([{ path: ["large"], length: 6710886400001L, }], options),
        )
        false
      } catch {
        CrateError(code, _) => code == "limit"
      },
    )
  }
  let aligned = Array::makei(1001, fn(i) {
    SourceFile::{ path: [i.to_string()], length: 6537217L, }
  })
  for mode in [V2, Hybrid] {
    let mut reads = 0
    assert_true(
      try {
        ignore(
          create_torrent(
            aligned,
            { ..create_options("large"), mode, piece_length: 16384, },
            fn(_, _, _) raise CrateError {
              reads += 1
              reject("test", "unexpected read")
              b""
            },
          ),
        )
        false
      } catch {
        CrateError(code, _) => code == "limit"
      },
    )
    assert_eq(reads, 0)
  }
}
