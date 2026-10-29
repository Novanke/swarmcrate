///|
test "v1 pieces cross files handle empty files and reject short reads" {
  let a = Bytes::make(9000, 97)
  let b = Bytes::make(10000, 98)
  let sources : Array[SourceFile] = [
    { path: ["a"], length: 9000L, },
    { path: ["empty"], length: 0L, },
    { path: ["b"], length: 10000L, },
  ]
  let data = [a, b"", b]
  let hashes = sha1_pieces(sources, 16384, fn(i, offset, n) {
    data[i][offset.to_int():offset.to_int() + n].to_owned()
  })
  let concat = a.to_array()
  append_bytes(concat, b)
  let concat = Bytes::from_array(concat)
  assert_eq(hashes.length(), 40)
  assert_eq(
    hashes[0:20].to_owned(),
    Bytes::from_array(@crypto.sha1(concat[0:16384])[:]),
  )
  assert_eq(
    hashes[20:40].to_owned(),
    Bytes::from_array(@crypto.sha1(concat[16384:])[:]),
  )
  let spans = piece_spans(sources, 16384, 0)
  assert_eq(spans.length(), 2)
  assert_eq(spans[0].length, 9000)
  assert_eq(spans[1].file, 2)
  assert_eq(spans[1].length, 7384)
  let failed = try {
    ignore(sha1_pieces(sources, 16384, fn(_, _, _) { b"" }))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(
    sha1_pieces([{ path: ["empty"], length: 0L, }], 16384, fn(_, _, _) { b"" }),
    b"",
  )
}

///|
test "public SHA1 hashing rejects oversized work before the reader is called" {
  for
    (length, expected) in [
      (6553600001L, "limit"),
      (6553600000L, "reader_reached"),
    ] {
    let mut reads = 0
    let code = try {
      ignore(
        sha1_pieces([{ path: ["large"], length, }], 16384, fn(
          _,
          _,
          _,
        ) raise CrateError {
          reads += 1
          raise CrateError(
            "reader_reached", "boundary probe; no payload allocated",
          )
        }),
      )
      "returned"
    } catch {
      CrateError(code, _) => code
    }
    assert_eq(code, expected)
    assert_eq(reads, if expected == "limit" { 0 } else { 1 })
  }
}
