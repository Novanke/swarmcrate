///|
test "v1 metainfo preserves exact info hash and original callback indices" {
  let files : Array[SourceFile] = [
    { path: ["z"], length: 1L, },
    { path: ["a"], length: 3L, },
  ]
  let torrent = create_torrent(
    files,
    { ..create_options("bundle"), mode: V1, },
    fn(i, _, _) { if i == 0 { b"z" } else { b"abc" } },
  )
  let info = inspect_torrent(torrent)
  assert_eq(info.files[0].path, ["a"])
  assert_eq(info.files[1].path, ["z"])
  assert_eq(
    expected_v1_pieces(torrent),
    Bytes::from_array(@crypto.sha1(b"abcz")[:]),
  )
  let top = decode_bencode(torrent)
  let raw = require_key(top, "info")
  assert_eq(
    info.info_hash_v1,
    Some(@crypto.bytes_to_hex_string(@crypto.sha1(torrent[raw.start:raw.end]))),
  )
  let single = create_torrent(
    [{ path: ["one"], length: 3L, }],
    {
      ..create_options("one"),
      mode: V1,
      single_file: true,
      trackers: [["https://example.org/announce"]],
    },
    fn(_, _, _) { b"abc" },
  )
  assert_true(inspect_torrent(single).single_file)
  assert_eq(
    inspect_torrent(single).trackers[0][0],
    "https://example.org/announce",
  )
  let invalid = bn_dict([
    (
      "info",
      bn_dict([
        ("name", bn_text("x")),
        ("piece length", bn_int(16384L)),
        ("length", bn_int(1L)),
        ("pieces", bn(Blob(b""))),
      ]),
    ),
  ])
  assert_true(
    try {
      ignore(inspect_torrent(encode_bencode(invalid)))
      false
    } catch {
      _ => true
    },
  )
}
