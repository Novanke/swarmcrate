///|
/// Synchronous cooperative-verification checkpoint. All fields are value snapshots.
/// Checks count hash comparisons (two per hybrid piece), not physical byte ranges.
pub(all) struct VerificationProgress {
  phase : String
  total_checks : Int32
  checked_pieces : Int32
  failed_pieces : Int32
  unreadable_pieces : Int32
  read_calls : Int32
  validated_read_bytes : Int64
  complete_scope : Bool
  selected_file_count : Int32
  required_file_count : Int32
  file : Int32?
  offset : Int64?
  length : Int32?
  read_ok : Bool?
}

///|
priv struct VerifyControl {
  callback : (VerificationProgress) -> Bool raise CrateError
  total : Int32
  scope : VerificationScope
  mut checked : Int32
  mut failed : Int32
  mut unreadable : Int32
  mut read_calls : Int32
  mut read_bytes : Int64
  mut error : CrateError?
}

///|
fn new_verify_control(
  parsed : ParsedTorrent,
  plan : VerifyPlan,
  callback : (VerificationProgress) -> Bool raise CrateError,
) -> VerifyControl {
  let mut total = 0
  if parsed.summary.mode != V2 {
    for selected in plan.v1_pieces {
      if selected {
        total += 1
      }
    }
  }
  if parsed.summary.mode != V1 {
    let width = parsed.summary.piece_length.to_int64()
    for i in plan.scope.selected_files {
      total += ((parsed.summary.files[i].length + width - 1L) / width).to_int()
    }
  }
  {
    callback,
    total,
    scope: plan.scope,
    checked: 0,
    failed: 0,
    unreadable: 0,
    read_calls: 0,
    read_bytes: 0L,
    error: None,
  }
}

///|
fn check_verification_control(
  control : VerifyControl?,
) -> Unit raise CrateError {
  if control is Some(control) {
    if control.error is Some(error) {
      raise error
    }
  }
}

///|
fn emit_verification_progress(
  control : VerifyControl?,
  phase : String,
  file~ : Int32? = None,
  offset~ : Int64? = None,
  length~ : Int32? = None,
  read_ok~ : Bool? = None,
) -> Unit raise CrateError {
  check_verification_control(control)
  if control is Some(control) {
    let event : VerificationProgress = {
      phase,
      total_checks: control.total,
      checked_pieces: control.checked,
      failed_pieces: control.failed,
      unreadable_pieces: control.unreadable,
      read_calls: control.read_calls,
      validated_read_bytes: control.read_bytes,
      complete_scope: control.scope.complete,
      selected_file_count: control.scope.selected_files.length(),
      required_file_count: control.scope.required_files.length(),
      file,
      offset,
      length,
      read_ok,
    }
    let keep_going = (control.callback)(event) catch {
      CrateError(code, detail) => {
        let error = CrateError(code, detail)
        control.error = Some(error)
        raise error
      }
    }
    if !keep_going {
      let error = CrateError(
        "cancelled", "verification cancelled by progress callback",
      )
      control.error = Some(error)
      raise error
    }
  }
}

///|
fn controlled_read(
  control : VerifyControl,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  file : Int32,
  offset : Int64,
  size : Int32,
) -> Bytes raise CrateError {
  emit_verification_progress(
    Some(control),
    "before_read",
    file=Some(file),
    offset=Some(offset),
    length=Some(size),
  )
  control.read_calls += 1
  let data = read_exact(read, file, offset, size) catch {
    CrateError(code, detail) => {
      emit_verification_progress(
        Some(control),
        "after_read",
        file=Some(file),
        offset=Some(offset),
        length=Some(size),
        read_ok=Some(false),
      )
      raise CrateError(code, detail)
    }
  }
  control.read_bytes += size.to_int64()
  emit_verification_progress(
    Some(control),
    "after_read",
    file=Some(file),
    offset=Some(offset),
    length=Some(size),
    read_ok=Some(true),
  )
  data
}
