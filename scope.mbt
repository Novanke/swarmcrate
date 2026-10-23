///|
pub(all) struct VerificationScope {
  complete : Bool
  selected_files : Array[Int32]
  required_files : Array[Int32]
}

///|
priv struct VerifyPlan {
  scope : VerificationScope
  selected : Array[Bool]
  v1_pieces : Array[Bool]
}

///|
fn marked_indices(mask : Array[Bool]) -> Array[Int32] {
  let indices : Array[Int32] = []
  for i, marked in mask {
    if marked {
      indices.push(i)
    }
  }
  indices
}

///|
fn plan_verification(
  parsed : ParsedTorrent,
  requested : Array[Int32]?,
) -> VerifyPlan raise CrateError {
  let selected = Array::make(parsed.summary.files.length(), false)
  match requested {
    None => selected.fill(true)
    Some(indices) => {
      if indices.is_empty() {
        reject("selection", "select at least one file")
      }
      for index in indices {
        if index < 0 || index >= selected.length() {
          reject("selection", "file index is outside inspected file list")
        }
        selected[index] = true
      }
    }
  }
  let v1_pieces = Array::make(parsed.pieces.length() / 20, false)
  let piece = parsed.summary.piece_length.to_int64()
  let indices = marked_indices(selected)
  let complete = indices.length() == selected.length()
  let mut cursor = 0L
  if complete {
    v1_pieces.fill(true)
  } else if parsed.summary.mode != V2 {
    for entry in parsed.entries {
      if !entry.padding && entry.length > 0L && selected[entry.source] {
        let first = (cursor / piece).to_int()
        let end = ((cursor + entry.length - 1L) / piece).to_int() + 1
        for p in first..<end {
          v1_pieces[p] = true
        }
      }
      cursor += entry.length
    }
  }
  // V1 boundary pieces may need bytes from unselected neighbours. Do not
  // recursively expand to those neighbours' other pieces.
  let required = selected.copy()
  cursor = 0L
  if parsed.summary.mode != V2 {
    for entry in parsed.entries {
      if !entry.padding && entry.length > 0L {
        let first = (cursor / piece).to_int()
        let end = ((cursor + entry.length - 1L) / piece).to_int() + 1
        for p in first..<end {
          if v1_pieces[p] {
            required[entry.source] = true
            break
          }
        }
      }
      cursor += entry.length
    }
  }
  {
    scope: {
      complete,
      selected_files: indices,
      required_files: marked_indices(required),
    },
    selected,
    v1_pieces,
  }
}

///|
/// Resolve a file selection before filesystem reads. Indices refer to inspected
/// files. None selects all; duplicates are normalized; an empty selection fails.
/// Required files include V1 boundary neighbours, which are only partly checked.
pub fn verification_scope(
  torrent : Bytes,
  selected_files~ : Array[Int32]? = None,
) -> VerificationScope raise CrateError {
  plan_verification(parse_torrent(torrent), selected_files).scope
}
