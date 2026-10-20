///|
test "strict binary codec preserves spans and canonical bytes" {
  for
    data in [
      b"i-9223372036854775808e", b"i9223372036854775807e", b"d1:ali1e3:abce1:b3:\xff\x00xe",
      b"0:",
    ] {
    check_bencode(data)
    let root = decode_bencode(data)
    assert_eq((root.start, root.end), (0, data.length()))
  }
  for
    data in [
      b"", b"i-0e", b"i01e", b"i9223372036854775808e", b"01:x", b"d1:bi1e1:ai2ee",
      b"d1:ai1e1:ai2ee", b"l", b"3:ab", b"i1ee",
    ] {
    let bad = try {
      check_bencode(data)
      false
    } catch {
      _ => true
    }
    assert_true(bad)
  }
}
