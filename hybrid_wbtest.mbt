///|
test "hybrid inserts virtual zeros without requesting padding files" {
  let files : Array[SourceFile] = [
    { path: ["a"], length: 3L, },
    { path: ["b"], length: 4L, },
  ]
  let torrent = create_torrent(
    files,
    { ..create_options("set"), piece_length: 16384, },
    fn(i, _, _) { if i == 0 { b"abc" } else { b"defg" } },
  )
  let summary = inspect_torrent(torrent)
  assert_eq(summary.mode, Hybrid)
  assert_true(summary.info_hash_v1 is Some(_))
  assert_true(summary.info_hash_v2 is Some(_))
  assert_eq(torrent_storage_bytes(torrent), 16388L)
  let padded = Bytes::makei(16384, fn(i) { if i < 3 { b"abc"[i] } else { 0 } })
  let pieces = expected_v1_pieces(torrent)
  assert_eq(pieces[0:20].to_owned(), Bytes::from_array(@crypto.sha1(padded)[:]))
  let top = decode_bencode(torrent)
  let info = require_key(top, "info")
  let list = as_list(require_key(info, "files"))
  list.remove(1) |> ignore
  assert_true(
    try {
      ignore(inspect_torrent(encode_bencode(top)))
      false
    } catch {
      _ => true
    },
  )
}
