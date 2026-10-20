///|
test "v2 Merkle roots use zero hashes not zero-filled block hashes" {
  for size in [0, 1, 16383, 16384, 16385, 32768, 32769, 65537] {
    let data = Bytes::makei(size, fn(i) { (i % 251).to_byte() })
    for piece in [16384, 32768, 65536] {
      let result = hash_v2_file(size.to_int64(), piece, fn(offset, n) {
        data[offset.to_int():offset.to_int() + n].to_owned()
      })
      if size == 0 {
        assert_eq(result.root, b"")
        continue
      }
      let leaves : Array[Bytes] = []
      let mut cursor = 0
      while cursor < size {
        let end = if size - cursor < 16384 { size } else { cursor + 16384 }
        leaves.push(sha256(data[cursor:end].to_owned()))
        cursor = end
      }
      assert_eq(result.root, merkle_root(leaves, Bytes::make(32, 0)))
      if size > piece {
        validate_piece_layer(
          result.root,
          size.to_int64(),
          piece,
          result.piece_layer,
        )
      }
    }
  }
  let small = hash_v2_file(3L, 262144, fn(_, _) { b"abc" })
  assert_eq(
    @crypto.bytes_to_hex_string(small.root),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_true(
    try {
      validate_piece_layer(
        Bytes::make(32, 0),
        32769L,
        16384,
        Bytes::make(96, 0),
      )
      false
    } catch {
      _ => true
    },
  )
}
