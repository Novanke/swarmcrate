///|
/// Immutable checkpoint values. Completed rows and read bytes are not a success certificate.
pub(all) struct BatchProgress {
  phase : String
  manifest_sha256 : String
  task_count : Int32
  completed_tasks : Int32
  pass_tasks : Int32
  partial_pass_tasks : Int32
  failed_tasks : Int32
  error_tasks : Int32
  read_calls : Int64
  validated_read_bytes : Int64
  task_index : Int32?
  task_id : String?
  task_outcome : String?
  verification : VerificationProgress?
}

///|
priv struct BatchControl {
  callback : (BatchProgress) -> Bool raise CrateError
  digest : String
  task_count : Int32
  mut completed : Int32
  mut passed : Int32
  mut partial : Int32
  mut failed : Int32
  mut errors : Int32
  mut reads : Int64
  mut bytes : Int64
  mut task_reads : Int32
  mut task_bytes : Int64
  mut error : CrateError?
}

///|
fn check_batch_control(control : BatchControl?) -> Unit raise CrateError {
  if control is Some(control) {
    if control.error is Some(error) {
      raise error
    }
  }
}

///|
fn emit_batch_progress(
  control : BatchControl?,
  phase : String,
  task_index~ : Int32? = None,
  task_id~ : String? = None,
  task_outcome~ : String? = None,
  verification~ : VerificationProgress? = None,
) -> Unit raise CrateError {
  check_batch_control(control)
  if control is Some(control) {
    let event : BatchProgress = {
      phase,
      manifest_sha256: control.digest,
      task_count: control.task_count,
      completed_tasks: control.completed,
      pass_tasks: control.passed,
      partial_pass_tasks: control.partial,
      failed_tasks: control.failed,
      error_tasks: control.errors,
      read_calls: control.reads,
      validated_read_bytes: control.bytes,
      task_index,
      task_id,
      task_outcome,
      verification,
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
        "cancelled", "batch audit cancelled by progress callback",
      )
      control.error = Some(error)
      raise error
    }
  }
}

///|
fn batch_verification_progress(
  control : BatchControl,
  index : Int32,
  id : String,
  event : VerificationProgress,
) -> Bool raise CrateError {
  control.reads += event.read_calls.to_int64() - control.task_reads.to_int64()
  control.bytes += event.validated_read_bytes - control.task_bytes
  control.task_reads = event.read_calls
  control.task_bytes = event.validated_read_bytes
  emit_batch_progress(
    Some(control),
    "verification",
    task_index=Some(index),
    task_id=Some(id),
    verification=Some(event),
  )
  true
}

///|
/// False or observer errors abort the entire batch, with no BatchAudit returned.
/// Task-local checked storage errors retain ordinary ERROR/FAIL isolation.
pub fn audit_batch_with_control(
  manifest : BatchManifest,
  load : (Int32, BatchTask) -> Bytes raise CrateError,
  observe : (Int32, TorrentInfo, VerificationScope) -> Array[Int64?] raise CrateError,
  read : (Int32, Int32, Int64, Int32) -> Bytes raise CrateError,
  on_progress : (BatchProgress) -> Bool raise CrateError,
  finish~ : ((Int32) -> Unit raise CrateError)? = None,
  detail_limit~ : Int32 = 128,
  max_summary_bytes~ : Int32 = 16777216,
) -> BatchAudit raise CrateError {
  audit_batch_impl(
    manifest,
    load,
    observe,
    read,
    finish,
    detail_limit,
    max_summary_bytes,
    Some(on_progress),
  )
}

///|
/// Structured progress is telemetry, never a saved/verified batch result.
pub fn batch_progress_json(event : BatchProgress) -> Json {
  let verification = match event.verification {
    None => Json::null()
    Some(v) =>
      j_object([
        ("phase", Json::string(v.phase)),
        ("total_checks", Json::number(v.total_checks.to_double())),
        ("checked_pieces", Json::number(v.checked_pieces.to_double())),
        ("failed_pieces", Json::number(v.failed_pieces.to_double())),
        ("unreadable_pieces", Json::number(v.unreadable_pieces.to_double())),
        ("read_calls", Json::number(v.read_calls.to_double())),
        (
          "validated_read_bytes",
          Json::string(v.validated_read_bytes.to_string()),
        ),
        ("complete_scope", Json::boolean(v.complete_scope)),
        ("selected_file_count", Json::number(v.selected_file_count.to_double())),
        ("required_file_count", Json::number(v.required_file_count.to_double())),
        (
          "file",
          match v.file {
            Some(i) => Json::number(i.to_double())
            None => Json::null()
          },
        ),
        ("offset", optional_text(v.offset.map(fn(n) { n.to_string() }))),
        (
          "length",
          match v.length {
            Some(n) => Json::number(n.to_double())
            None => Json::null()
          },
        ),
        (
          "read_ok",
          match v.read_ok {
            Some(ok) => Json::boolean(ok)
            None => Json::null()
          },
        ),
      ])
  }
  j_object([
    ("schema", Json::string("swarmcrate.batch-progress.v1")),
    ("phase", Json::string(event.phase)),
    ("manifest_sha256", Json::string(event.manifest_sha256)),
    ("task_count", Json::number(event.task_count.to_double())),
    ("completed_tasks", Json::number(event.completed_tasks.to_double())),
    ("pass_tasks", Json::number(event.pass_tasks.to_double())),
    ("partial_pass_tasks", Json::number(event.partial_pass_tasks.to_double())),
    ("failed_tasks", Json::number(event.failed_tasks.to_double())),
    ("error_tasks", Json::number(event.error_tasks.to_double())),
    ("read_calls", Json::string(event.read_calls.to_string())),
    (
      "validated_read_bytes",
      Json::string(event.validated_read_bytes.to_string()),
    ),
    (
      "task_index",
      match event.task_index {
        Some(i) => Json::number(i.to_double())
        None => Json::null()
      },
    ),
    ("task_id", optional_text(event.task_id)),
    ("task_outcome", optional_text(event.task_outcome)),
    ("verification", verification),
  ])
}
