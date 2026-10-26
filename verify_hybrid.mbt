///|
/// Validated hybrid files start on SHA-1 piece boundaries. Hash each selected
/// real chunk once, reusing it for SHA-256 leaves and the SHA-1 piece buffer.
fn verify_hybrid(
  parsed : ParsedTorrent,
  selected : Array[Bool],
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  state : VerifyState,
) -> Unit {
  let piece = parsed.summary.piece_length
  let buffer : FixedArray[Byte] = FixedArray::make(piece, 0)
  let mut storage = 0L
  for entry in parsed.entries {
    storage += entry.length
  }
  // Retain the existing SHA-1-then-SHA-256 diagnostic order and detail cap.
  // Only bounded SHA-256 failure details wait here, never actual file layers.
  let v2 : VerifyState = {
    checked: 0,
    skipped: 0,
    failed: 0,
    unreadable: 0,
    failures: [],
    limit: state.limit,
  }
  let mut global_piece = 0
  for index, file in parsed.summary.files {
    let count = ((file.length + piece.to_int64() - 1L) / piece.to_int64()).to_int()
    if !selected[index] {
      state.skipped += count
      v2.skipped += count
      global_piece += count
      continue
    }
    for local_piece in 0..<count {
      let offset = local_piece.to_int64() * piece.to_int64()
      let real_length = if file.length - offset < piece.to_int64() {
        (file.length - offset).to_int()
      } else {
        piece
      }
      let spans : Array[PieceSpan] = []
      let mut cursor = 0
      while cursor < real_length {
        let size = if real_length - cursor > 1048576 {
          1048576
        } else {
          real_length - cursor
        }
        spans.push({
          file: index,
          offset: offset + cursor.to_int64(),
          length: size,
        })
        cursor += size
      }
      let actual = if lengths[index] == Some(file.length) {
        Some(
          hash_v2_piece(file.length, piece, offset, (o, n) => {
            let data = read_exact(read, index, o, n)
            buffer.blit_from_bytes((o - offset).to_int(), data, 0, n)
            data
          }),
        ) catch {
          _ => None
        }
      } else {
        None
      }
      let readable = actual is Some(_)
      let sha1_matches = if readable {
        let remaining = storage - global_piece.to_int64() * piece.to_int64()
        let hashed_length = if remaining < piece.to_int64() {
          remaining.to_int()
        } else {
          piece
        }
        // A short final file may or may not have virtual trailing padding.
        // Clear reused buffer bytes so previous pieces cannot leak into zeros.
        for i in real_length..<hashed_length {
          buffer[i] = 0
        }
        let hash = if hashed_length == piece {
          Bytes::from_array(@crypto.sha1(buffer)[:])
        } else {
          Bytes::from_array(
            @crypto.sha1(Bytes::from_array(buffer[0:hashed_length]))[:],
          )
        }
        hash ==
        parsed.pieces[global_piece * 20:global_piece * 20 + 20].to_owned()
      } else {
        false
      }
      record_piece(state, "sha1", global_piece, spans, sha1_matches, readable)
      let sha256_matches = match actual {
        None => false
        Some(hash) =>
          if count == 1 {
            hash == parsed.roots[index].root
          } else {
            hash ==
            parsed.roots[index].piece_layer[local_piece * 32:local_piece * 32 +
            32].to_owned()
          }
      }
      record_piece(
        v2,
        "sha256",
        local_piece,
        [{ file: index, offset, length: real_length, }],
        sha256_matches,
        readable,
      )
      // Later SHA-1 failures take precedence over earlier SHA-256 failures.
      // Keep only the earliest SHA-256 details that could still be returned.
      while state.failures.length() + v2.failures.length() > state.limit {
        ignore(v2.failures.pop())
      }
      global_piece += 1
    }
  }
  state.checked += v2.checked
  state.skipped += v2.skipped
  state.failed += v2.failed
  state.unreadable += v2.unreadable
  for failure in v2.failures {
    if state.failures.length() >= state.limit {
      break
    }
    state.failures.push(failure)
  }
}
