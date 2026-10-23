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

///|
test "hybrid accepts a non-rewindable source and hashes each real byte once" {
  let data = [b"abc", Bytes::makei(16385, fn(i) { (i % 251).to_byte() }), b""]
  let files : Array[SourceFile] = [
    { path: ["b"], length: 3L, },
    { path: ["a"], length: 16385L, },
    { path: ["z-empty"], length: 0L, },
  ]
  for piece in [16384, 32768, 65536] {
    let positions = Array::make(3, 0L)
    let mut bytes_read = 0L
    let torrent = create_torrent(
      files,
      { ..create_options("stream"), piece_length: piece, },
      fn(i, o, n) raise CrateError {
        if o != positions[i] || n <= 0 || n > 16384 {
          reject("stream", "cannot rewind or skip input")
        }
        positions[i] += n.to_int64()
        bytes_read += n.to_int64()
        data[i][o.to_int():o.to_int() + n].to_owned()
      },
    )
    assert_eq(bytes_read, 16388L)
    assert_eq(positions, [3L, 16385L, 0L])
    let a_size = (16385 + piece - 1) / piece * piece
    let storage = Bytes::makei(a_size + piece, fn(i) {
      if i < 16385 {
        data[1][i]
      } else if i >= a_size && i < a_size + 3 {
        b"abc"[i - a_size]
      } else {
        0
      }
    })
    let expected : Array[Byte] = []
    for i in 0..<(storage.length() / piece) {
      append_bytes(
        expected,
        Bytes::from_array(@crypto.sha1(storage[i * piece:(i + 1) * piece])[:]),
      )
    }
    assert_eq(expected_v1_pieces(torrent), Bytes::from_array(expected))
    assert_eq(torrent_storage_bytes(torrent), storage.length().to_int64())
    assert_eq(inspect_torrent(torrent).files[2].length, 0L)
  }
}

///|
test "hybrid rejects an excessive aligned piece count before touching payload" {
  let files = Array::makei(1001, fn(i) {
    SourceFile::{ path: [i.to_string()], length: 6537217L, }
  })
  let mut reads = 0
  let code = try {
    ignore(
      create_torrent(
        files,
        { ..create_options("too-many-pieces"), piece_length: 16384, },
        fn(_, _, _) raise CrateError {
          reads += 1
          reject("unexpected_read", "layout must be checked first")
          b""
        },
      ),
    )
    "accepted"
  } catch {
    CrateError(code, _) => code
  }
  assert_eq(code, "limit")
  assert_eq(reads, 0)
}
