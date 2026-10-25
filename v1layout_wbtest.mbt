///|
fn padded_v1_fixture(
  nodes : Array[BNode],
  hashes : Bytes,
) -> Bytes raise CrateError {
  encode_bencode(
    bn_dict([
      (
        "info",
        bn_dict([
          ("name", bn_text("bundle")),
          ("piece length", bn_int(16384L)),
          ("pieces", bn(Blob(hashes))),
          ("files", bn(Sequence(nodes))),
        ]),
      ),
    ]),
  )
}

///|
test "v1 padding stays virtual with exact storage hashes and real callback indices" {
  let padded = Bytes::make(16384, 0)
  let data : FixedArray[Byte] = FixedArray::make(16384, 0)
  data.blit_from_bytes(0, b"abc", 0, 3)
  let first_hash = Bytes::from_array(@crypto.sha1(data)[:])
  let second_hash = Bytes::from_array(@crypto.sha1(b"defgh")[:])
  let hashes = first_hash + second_hash
  let a = v1_file_node({ path: ["a"], length: 3L, })
  let b = v1_file_node({ path: ["b"], length: 4L, })
  let c = v1_file_node({ path: ["c"], length: 1L, })
  // Both recommended paths (including repeats) and omitted paths are virtual.
  for
    pad in [
      bn_dict([("attr", bn_text("p")), ("length", bn_int(16381L))]),
      bn_dict([
        ("attr", bn_text("p")),
        ("length", bn_int(16381L)),
        ("path", bn(Sequence([bn_text(".pad"), bn_text("16381")]))),
      ]),
    ] {
    let torrent = padded_v1_fixture([a, pad, b, c], hashes)
    let info = inspect_torrent(torrent)
    assert_eq(info.mode, V1)
    assert_eq(info.files.length(), 3)
    assert_eq(info.files[1].path, ["b"])
    assert_eq(torrent_storage_bytes(torrent), 16389L)
    assert_eq(expected_v1_pieces(torrent), hashes)
    let payload = [b"abc", b"defg", b"h"]
    let calls : Array[Int32] = []
    let report = verify_payload(torrent, [Some(3L), Some(4L), Some(1L)], (
      i,
      offset,
      n,
    ) => {
      calls.push(i)
      payload[i][offset.to_int():offset.to_int() + n].to_owned()
    })
    assert_true(report.ok)
    assert_eq(report.checked_pieces, 2)
    assert_eq(calls, [0, 1, 2])
    let partial = verify_payload(
      torrent,
      [Some(3L), None, None],
      (i, offset, n) => {
        if i != 0 {
          reject("test", "partial check read an unrelated file")
        }
        payload[i][offset.to_int():offset.to_int() + n].to_owned()
      },
      selected_files=Some([0]),
    )
    assert_true(partial.ok)
    assert_eq(partial.scope.required_files, [0])
    assert_eq(partial.skipped_pieces, 1)
    assert_eq(
      verification_scope(torrent, selected_files=Some([1])).required_files,
      [1, 2],
    )
    let damaged = verify_payload(torrent, [Some(3L), Some(4L), Some(1L)], fn(
      i,
      offset,
      n,
    ) {
      if i == 1 {
        b"DEFG"
      } else {
        payload[i][offset.to_int():offset.to_int() + n].to_owned()
      }
    })
    assert_eq(damaged.failed_pieces, 1)
    assert_eq(damaged.failures[0].piece, 1)
    assert_eq(damaged.failures[0].spans[0].file, 1)
    assert_eq(damaged.failures[0].spans[1].file, 2)
  }
  // Trailing padding contributes to storage and hashes, not the real file size.
  let trailing = padded_v1_fixture(
    [
      v1_file_node({ path: ["a"], length: 1L, }),
      bn_dict([("attr", bn_text("p")), ("length", bn_int(16383L))]),
    ],
    Bytes::from_array(@crypto.sha1(padded)[:]),
  )
  assert_true(verify_payload(trailing, [Some(1L)], fn(_, _, _) { b"\x00" }).ok)
  assert_eq(torrent_storage_bytes(trailing), 16384L)
}

///|
test "v1 rejects malformed padding unsafe paths and unsupported file semantics" {
  let real = v1_file_node({ path: ["a"], length: 3L, })
  let hash = Bytes::make(20, 0)
  for
    nodes in [
      [bn_dict([("attr", bn_text("p")), ("length", bn_int(16384L))]), real],
      [real, bn_dict([("attr", bn_text("p")), ("length", bn_int(0L))])],
      [real, bn_dict([("attr", bn_text("p")), ("length", bn_int(-1L))])],
      [real, bn_dict([("attr", bn_text("p")), ("length", bn_int(16384L))])],
      [real, bn_dict([("attr", bn_text("p")), ("length", bn_int(16380L))])],
      [
        real,
        bn_dict([
          ("attr", bn_text("p")),
          ("length", bn_int(16381L)),
          ("path", bn(Sequence([bn_text("..")]))),
        ]),
      ],
      [bn_dict([("length", bn_int(1L))])],
      [
        bn_dict([
          ("attr", bn_text("pl")),
          ("length", bn_int(1L)),
          ("path", bn(Sequence([bn_text("a")]))),
        ]),
      ],
      [
        bn_dict([
          ("length", bn_int(1L)),
          ("path", bn(Sequence([bn_text("a")]))),
          ("symlink path", bn(Sequence([bn_text("b")]))),
        ]),
      ],
    ] {
    assert_true(
      try {
        ignore(inspect_torrent(padded_v1_fixture(nodes, hash)))
        false
      } catch {
        _ => true
      },
    )
  }
  let valid_pad = bn_dict([("attr", bn_text("p")), ("length", bn_int(16381L))])
  // Real byte count alone would suggest one piece; padded storage needs two.
  assert_true(
    try {
      ignore(
        inspect_torrent(
          padded_v1_fixture(
            [real, valid_pad, v1_file_node({ path: ["b"], length: 1L, })],
            hash,
          ),
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  // Single-file attributes were previously ignored; links must never be treated as payloads.
  let single = encode_bencode(
    bn_dict([
      (
        "info",
        bn_dict([
          ("name", bn_text("a")),
          ("length", bn_int(1L)),
          ("piece length", bn_int(16384L)),
          ("pieces", bn(Blob(hash))),
          ("attr", bn_text("l")),
        ]),
      ),
    ]),
  )
  assert_true(
    try {
      ignore(inspect_torrent(single))
      false
    } catch {
      _ => true
    },
  )
}
