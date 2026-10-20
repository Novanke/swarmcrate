///|
pub(all) struct V2FileHash {
  root : Bytes
  piece_layer : Bytes
}

///|
fn sha256(data : Bytes) -> Bytes {
  Bytes::from_array(@crypto.sha256(data)[:])
}

///|
fn hash_pair(left : Bytes, right : Bytes) -> Bytes {
  let pair = left.to_array()
  append_bytes(pair, right)
  sha256(Bytes::from_array(pair))
}

///|
fn zero_piece_hash(piece_length : Int32) -> Bytes {
  let mut width = 16384
  let mut zero = Bytes::make(32, 0)
  while width < piece_length {
    zero = hash_pair(zero, zero)
    width *= 2
  }
  zero
}

///|
fn merkle_root(hashes : Array[Bytes], zero : Bytes) -> Bytes raise CrateError {
  if hashes.is_empty() {
    reject("merkle", "cannot hash an empty tree")
  }
  let nodes = hashes.copy()
  let mut capacity = 1
  while capacity < nodes.length() {
    capacity *= 2
  }
  while nodes.length() < capacity {
    nodes.push(zero)
  }
  let mut width = capacity
  while width > 1 {
    for i in 0..<(width / 2) {
      nodes[i] = hash_pair(nodes[i * 2], nodes[i * 2 + 1])
    }
    width /= 2
  }
  nodes[0]
}

///|
fn split_hashes(data : Bytes) -> Array[Bytes] raise CrateError {
  if data.length() % 32 != 0 {
    reject("merkle", "SHA-256 layer length must be divisible by 32")
  }
  Array::makei(data.length() / 32, fn(i) { data[i * 32:i * 32 + 32].to_owned() })
}

///|
/// Hash 16 KiB blocks with BEP 52 zero-hash padding, buffering one piece's hashes.
/// Empty files have neither pieces root nor piece layer.
pub fn hash_v2_file(
  length : Int64,
  piece_length : Int32,
  read : (Int64, Int32) -> Bytes raise CrateError,
) -> V2FileHash raise CrateError {
  check_piece_length(piece_length)
  if length < 0L ||
    (length + piece_length.to_int64() - 1L) / piece_length.to_int64() > 400000L {
    reject("limit", "invalid file length or too many pieces")
  }
  if length == 0L {
    return { root: b"", piece_layer: b"", }
  }
  let pieces : Array[Bytes] = []
  let mut offset = 0L
  while offset < length {
    let blocks : Array[Bytes] = []
    let piece_end = if length - offset < piece_length.to_int64() {
      length
    } else {
      offset + piece_length.to_int64()
    }
    while offset < piece_end {
      let size = if piece_end - offset < 16384L {
        (piece_end - offset).to_int()
      } else {
        16384
      }
      let data = read(offset, size)
      if data.length() != size {
        reject("read", "short or oversized v2 block read")
      }
      blocks.push(sha256(data))
      offset += size.to_int64()
    }
    if length > piece_length.to_int64() {
      while blocks.length() < piece_length / 16384 {
        blocks.push(Bytes::make(32, 0))
      }
    }
    pieces.push(merkle_root(blocks, Bytes::make(32, 0)))
  }
  if length <= piece_length.to_int64() {
    { root: pieces[0], piece_layer: b"", }
  } else {
    let layer : Array[Byte] = []
    for hash in pieces {
      append_bytes(layer, hash)
    }
    {
      root: merkle_root(pieces, zero_piece_hash(piece_length)),
      piece_layer: Bytes::from_array(layer),
    }
  }
}

///|
pub fn validate_piece_layer(
  root : Bytes,
  length : Int64,
  piece_length : Int32,
  layer : Bytes,
) -> Unit raise CrateError {
  check_piece_length(piece_length)
  if length <= piece_length.to_int64() ||
    length > 9007199254740991L ||
    root.length() != 32 {
    reject(
      "merkle", "piece layer requires a nonempty multi-piece file and 32-byte root",
    )
  }
  let count = (length + piece_length.to_int64() - 1L) / piece_length.to_int64()
  if count > 400000L || layer.length().to_int64() != count * 32L {
    reject("merkle", "piece layer count mismatch")
  }
  if merkle_root(split_hashes(layer), zero_piece_hash(piece_length)) != root {
    reject("merkle", "piece layer does not reconstruct file root")
  }
}
