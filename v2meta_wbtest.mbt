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

///|
test "large flat and shared-directory trees retain deterministic paths and roots" {
  for nested in [false, true] {
    let files = Array::makei(5000, fn(i) {
      let name = "file-" + i.to_string()
      SourceFile::{
        path: if nested {
          ["资料", (i % 7).to_string(), name]
        } else {
          [name]
        },
        length: if i == 4999 {
          1L
        } else {
          0L
        },
      }
    })
    let torrent = create_torrent(
      files,
      { ..create_options("many-files"), mode: V2, },
      fn(_, _, _) { b"x" },
    )
    let info = inspect_torrent(torrent)
    assert_eq(info.files.length(), 5000)
    let order = sorted_source_indices(files)
    for i, file in info.files {
      assert_eq(file.path, files[order[i]].path)
      assert_eq(file.length, files[order[i]].length)
    }
    let reversed = Array::makei(files.length(), fn(i) {
      files[files.length() - 1 - i]
    })
    assert_eq(
      torrent,
      create_torrent(reversed, { ..create_options("many-files"), mode: V2, }, fn(
        _,
        _,
        _,
      ) {
        b"x"
      }),
    )
    check_bencode(torrent)
  }
}
