///|
pub(all) struct FileIssue {
  file : Int32
  path : String
  expected : Int64
  actual : Int64?
  reason : String
}

///|
pub(all) struct PieceFailure {
  scheme : String
  piece : Int32
  spans : Array[PieceSpan]
  reason : String
}

///|
pub(all) struct VerificationReport {
  ok : Bool
  scope : VerificationScope
  checked_pieces : Int32
  skipped_pieces : Int32
  failed_pieces : Int32
  unreadable_pieces : Int32
  file_issues : Array[FileIssue]
  failures : Array[PieceFailure]
  details_truncated : Bool
}

///|
priv struct VerifyState {
  mut checked : Int32
  mut skipped : Int32
  mut failed : Int32
  mut unreadable : Int32
  failures : Array[PieceFailure]
  limit : Int32
  control : VerifyControl?
}

///|
fn record_piece(
  state : VerifyState,
  scheme : String,
  index : Int32,
  spans : Array[PieceSpan],
  matches : Bool,
  readable : Bool,
) -> Unit raise CrateError {
  state.checked += 1
  if !matches || !readable {
    state.failed += 1
    if !readable {
      state.unreadable += 1
    }
    if state.failures.length() < state.limit {
      state.failures.push({
        scheme,
        piece: index,
        spans: spans.copy(),
        reason: if readable {
          "hash_mismatch"
        } else {
          "unreadable"
        },
      })
    }
  }
  if state.control is Some(control) {
    control.checked += 1
    if !matches || !readable {
      control.failed += 1
    }
    if !readable {
      control.unreadable += 1
    }
    emit_verification_progress(Some(control), "check")
  }
}

///|
fn verify_v1(
  parsed : ParsedTorrent,
  selected : Array[Bool],
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  state : VerifyState,
) -> Unit raise CrateError {
  let piece_length = parsed.summary.piece_length
  let buffer : FixedArray[Byte] = FixedArray::make(piece_length, 0)
  let spans : Array[PieceSpan] = []
  let mut used = 0
  let mut piece = 0
  let mut readable = true
  for entry in parsed.entries {
    let mut offset = 0L
    while offset < entry.length {
      let remaining = entry.length - offset
      let size = if remaining < (piece_length - used).to_int64() {
        remaining.to_int()
      } else {
        piece_length - used
      }
      let size = if size > 1048576 { 1048576 } else { size }
      if selected[piece] {
        let valid_size = entry.padding ||
          lengths[entry.source] ==
          Some(parsed.summary.files[entry.source].length)
        let data = if entry.padding || !valid_size {
          Bytes::make(size, 0)
        } else {
          read_exact(read, entry.source, offset, size) catch {
            _ => {
              readable = false
              Bytes::make(size, 0)
            }
          }
        }
        check_verification_control(state.control)
        if !valid_size {
          readable = false
        }
        if !entry.padding {
          spans.push({ file: entry.source, offset, length: size, })
        }
        buffer.blit_from_bytes(used, data, 0, size)
      }
      used += size
      offset += size.to_int64()
      if used == piece_length {
        if selected[piece] {
          let actual = Bytes::from_array(@crypto.sha1(buffer)[:])
          record_piece(
            state,
            "sha1",
            piece,
            spans,
            actual == parsed.pieces[piece * 20:piece * 20 + 20].to_owned(),
            readable,
          )
        } else {
          state.skipped += 1
        }
        spans.clear()
        used = 0
        piece += 1
        readable = true
      }
    }
  }
  if used > 0 {
    if selected[piece] {
      let actual = Bytes::from_array(
        @crypto.sha1(Bytes::from_array(buffer[0:used]))[:],
      )
      record_piece(
        state,
        "sha1",
        piece,
        spans,
        actual == parsed.pieces[piece * 20:piece * 20 + 20].to_owned(),
        readable,
      )
    } else {
      state.skipped += 1
    }
  }
}

///|
fn verify_v2(
  parsed : ParsedTorrent,
  selected : Array[Bool],
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  state : VerifyState,
) -> Unit raise CrateError {
  let piece = parsed.summary.piece_length
  for index, file in parsed.summary.files {
    if file.length == 0L {
      continue
    }
    let count = ((file.length + piece.to_int64() - 1L) / piece.to_int64()).to_int()
    if !selected[index] {
      state.skipped += count
      continue
    }
    for p in 0..<count {
      let offset = p.to_int64() * piece.to_int64()
      let length = if file.length - offset < piece.to_int64() {
        (file.length - offset).to_int()
      } else {
        piece
      }
      let actual = if lengths[index] == Some(file.length) {
        Some(
          hash_v2_piece(file.length, piece, offset, (o, n) => read(index, o, n)),
        ) catch {
          _ => None
        }
      } else {
        None
      }
      check_verification_control(state.control)
      let matches = match actual {
        None => false
        Some(actual) =>
          if count == 1 {
            actual == parsed.roots[index].root
          } else {
            actual ==
            parsed.roots[index].piece_layer[p * 32:p * 32 + 32].to_owned()
          }
      }
      record_piece(
        state,
        "sha256",
        p,
        [{ file: index, offset, length, }],
        matches,
        actual is Some(_),
      )
    }
  }
}

///|
/// Check real sizes and hashes. Missing files are None. Read errors cannot pass as zero data.
/// Failure detail storage is bounded; aggregate counters always include every piece.
pub fn verify_payload(
  torrent : Bytes,
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  detail_limit~ : Int32 = 4096,
  selected_files~ : Array[Int32]? = None,
) -> VerificationReport raise CrateError {
  let parsed = parse_torrent(torrent)
  verify_parsed(parsed, lengths, read, detail_limit, selected_files, None)
}

///|
fn verify_parsed(
  parsed : ParsedTorrent,
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  detail_limit : Int32,
  selected_files : Array[Int32]?,
  on_progress : ((VerificationProgress) -> Bool raise CrateError)?,
) -> VerificationReport raise CrateError {
  let plan = plan_verification(parsed, selected_files)
  if lengths.length() != parsed.summary.files.length() ||
    detail_limit < 1 ||
    detail_limit > 10000 {
    reject("verify", "file size mapping or detail limit is invalid")
  }
  let issues : Array[FileIssue] = []
  for i in plan.scope.required_files {
    let file = parsed.summary.files[i]
    if lengths[i] != Some(file.length) {
      issues.push({
        file: i,
        path: file.path.join("/"),
        expected: file.length,
        actual: lengths[i],
        reason: if lengths[i] is None {
          "missing"
        } else {
          "size_mismatch"
        },
      })
    }
  }
  let control = on_progress.map(fn(callback) {
    new_verify_control(parsed, plan, callback)
  })
  let observed_read = match control {
    None => read
    Some(control) =>
      fn(i, o, n) raise CrateError { controlled_read(control, read, i, o, n) }
  }
  emit_verification_progress(control, "start")
  let state : VerifyState = {
    checked: 0,
    skipped: 0,
    failed: 0,
    unreadable: 0,
    failures: [],
    limit: detail_limit,
    control,
  }
  match parsed.summary.mode {
    V1 => verify_v1(parsed, plan.v1_pieces, lengths, observed_read, state)
    V2 => verify_v2(parsed, plan.selected, lengths, observed_read, state)
    Hybrid =>
      verify_hybrid(parsed, plan.selected, lengths, observed_read, state)
  }
  emit_verification_progress(control, "finalize")
  {
    ok: state.failed == 0 && issues.is_empty(),
    scope: plan.scope,
    checked_pieces: state.checked,
    skipped_pieces: state.skipped,
    failed_pieces: state.failed,
    unreadable_pieces: state.unreadable,
    file_issues: issues,
    failures: state.failures,
    details_truncated: state.failed > state.failures.length(),
  }
}
