///|
test "v2 file trees deduplicate layers and authenticate all referenced roots" {
  let content = Bytes::makei(50000, fn(i) { (i % 251).to_byte() })
  let files : Array[SourceFile] = [
    { path: ["b", "same"], length: 50000L, },
    { path: ["a"], length: 50000L, },
    { path: ["empty"], length: 0L, },
  ]
  let torrent = create_torrent(
    files,
    { ..create_options("dataset"), mode: V2, piece_length: 32768, },
    fn(_, offset, n) { content[offset.to_int():offset.to_int() + n].to_owned() },
  )
  let summary = inspect_torrent(torrent)
  assert_eq(summary.mode, V2)
  assert_eq(summary.files[0].path, ["a"])
  assert_eq(expected_v2_files(torrent).length(), 3)
  let top = decode_bencode(torrent)
  let layers = require_key(top, "piece layers")
  assert_eq(dict_pairs(layers).length(), 1)
  let bad_top = dict_pairs(top).map(fn(p) {
    if p.0 == b"piece layers" {
      (p.0, bn(Dictionary([])))
    } else {
      p
    }
  })
  assert_true(
    try {
      ignore(inspect_torrent(encode_bencode(bn(Dictionary(bad_top)))))
      false
    } catch {
      _ => true
    },
  )
}
