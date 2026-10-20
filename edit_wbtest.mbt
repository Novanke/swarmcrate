///|
test "distribution edits retain exact info bytes and unknown extension fields" {
  for mode in [V1, V2, Hybrid] {
    let torrent = create_torrent(
      [{ path: ["abc"], length: 3L, }],
      { ..create_options("abc"), mode, single_file: true, },
      fn(_, _, _) { b"abc" },
    )
    let before = inspect_torrent(torrent)
    let top = decode_bencode(torrent)
    dict_pairs(top).push((b"x-custom", bn(Blob(b"\xff\x00"))))
    let torrent = encode_bencode(top)
    let edited = edit_distribution(
      torrent,
      [["udp://example.org:8080/announce"]],
      ["https://example.org/files/"],
    )
    assert_eq(inspect_torrent(edited).info_hash_v1, before.info_hash_v1)
    assert_eq(inspect_torrent(edited).info_hash_v2, before.info_hash_v2)
    assert_eq(
      as_blob(require_key(decode_bencode(edited), "x-custom")),
      b"\xff\x00",
    )
    let old = require_key(decode_bencode(torrent), "info")
    let new = require_key(decode_bencode(edited), "info")
    assert_eq(torrent[old.start:old.end], edited[new.start:new.end])
  }
}
