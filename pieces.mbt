///|
priv struct DataEntry {
  source : Int32
  length : Int64
  padding : Bool
}

///|
pub(all) struct PieceSpan {
  file : Int32
  offset : Int64
  length : Int32
}

///|
fn check_piece_length(piece : Int32) -> Unit raise CrateError {
  if piece < 16384 || piece > 16777216 || (piece & (piece - 1)) != 0 {
    reject("piece_length", "expected a power of two in 16 KiB..16 MiB")
  }
}

///|
fn read_exact(
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  file : Int32,
  offset : Int64,
  size : Int32,
) -> Bytes raise CrateError {
  let data = read(file, offset, size)
  if data.length() != size {
    reject("read", "short or oversized read at file \{file} offset \{offset}")
  }
  data
}

///|
priv struct Sha1Pieces {
  buffer : FixedArray[Byte]
  mut used : Int32
  hashes : Array[Byte]
}

///|
fn new_sha1_pieces(piece_length : Int32) -> Sha1Pieces raise CrateError {
  check_piece_length(piece_length)
  { buffer: FixedArray::make(piece_length, 0), used: 0, hashes: [], }
}

///|
fn flush_sha1(state : Sha1Pieces, padded : Bool) -> Unit raise CrateError {
  if state.used == 0 {
    return
  }
  let hash = if padded {
    for i in state.used..<state.buffer.length() {
      state.buffer[i] = 0
    }
    Bytes::from_array(@crypto.sha1(state.buffer)[:])
  } else {
    Bytes::from_array(
      @crypto.sha1(Bytes::from_array(state.buffer[0:state.used]))[:],
    )
  }
  if state.hashes.length() / 20 >= 400000 {
    reject("limit", "too many pieces")
  }
  append_bytes(state.hashes, hash)
  state.used = 0
}

///|
fn push_sha1(state : Sha1Pieces, data : Bytes) -> Unit raise CrateError {
  let mut offset = 0
  while offset < data.length() {
    let capacity = state.buffer.length() - state.used
    let n = if data.length() - offset < capacity {
      data.length() - offset
    } else {
      capacity
    }
    state.buffer.blit_from_bytes(state.used, data, offset, n)
    state.used += n
    offset += n
    if state.used == state.buffer.length() {
      flush_sha1(state, true)
    }
  }
}

///|
fn v1_hash_entries(
  entries : Array[DataEntry],
  piece_length : Int32,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
) -> Bytes raise CrateError {
  let state = new_sha1_pieces(piece_length)
  for entry in entries {
    let mut offset = 0L
    while offset < entry.length {
      let remaining = entry.length - offset
      let size = if remaining < (piece_length - state.used).to_int64() {
        remaining.to_int()
      } else {
        piece_length - state.used
      }
      // Read in at most 1 MiB chunks even when a piece is larger.
      let size = if size > 1048576 { 1048576 } else { size }
      let data = if entry.padding {
        Bytes::make(size, 0)
      } else {
        read_exact(read, entry.source, offset, size)
      }
      push_sha1(state, data)
      offset += size.to_int64()
    }
  }
  flush_sha1(state, false)
  Bytes::from_array(state.hashes)
}

///|
/// Hash the exact caller-supplied file order, crossing file boundaries (BEP 3).
/// The callback must return exactly the requested bytes; only one piece is buffered.
/// Reject layouts above 400,000 pieces before calling the reader.
pub fn sha1_pieces(
  files : Array[SourceFile],
  piece_length : Int32,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
) -> Bytes raise CrateError {
  let total = validate_sources(files)
  check_piece_length(piece_length)
  if (total + piece_length.to_int64() - 1L) / piece_length.to_int64() > 400000L {
    reject("limit", "too many pieces; select a larger piece length")
  }
  let entries = files.mapi(fn(i, f) {
    DataEntry::{ source: i, length: f.length, padding: false, }
  })
  v1_hash_entries(entries, piece_length, read)
}

///|
/// Map a v1 piece to its contributing real file ranges, including boundary pieces.
pub fn piece_spans(
  files : Array[SourceFile],
  piece_length : Int32,
  piece : Int32,
) -> Array[PieceSpan] raise CrateError {
  let total = validate_sources(files)
  check_piece_length(piece_length)
  let start = piece.to_int64() * piece_length.to_int64()
  if piece < 0 || start >= total {
    reject("piece", "piece index is outside payload")
  }
  let end = start + piece_length.to_int64()
  let out : Array[PieceSpan] = []
  let mut cursor = 0L
  for i, file in files {
    let next = cursor + file.length
    if file.length > 0 && next > start && cursor < end {
      let lo = if start > cursor { start } else { cursor }
      let hi = if end < next { end } else { next }
      out.push({ file: i, offset: lo - cursor, length: (hi - lo).to_int(), })
    }
    cursor = next
  }
  out
}
