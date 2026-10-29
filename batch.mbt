///|
/// Locators are opaque to the core; the filesystem CLI resolves them from the manifest directory.
pub(all) struct BatchTask {
  id : String
  metainfo : String
  payload : String
  files : Array[String]?
}

///|
/// Validated, immutable task definitions bound to the exact manifest bytes.
pub struct BatchManifest {
  priv tasks : Array[BatchTask]
  priv digest : String
  priv byte_length : Int32
}

///|
/// Immutable, unsigned summary. Only audit_batch can construct one.
pub struct BatchAudit {
  priv text : String
  priv exit_code : Int32
}

///|
fn batch_fields(
  value : Json,
  allowed : Array[String],
) -> Map[String, Json] raise CrateError {
  let fields = match value {
    Object(fields) => fields
    _ => {
      reject("manifest", "expected JSON object")
      Map([])
    }
  }
  for key, _ in fields {
    if !allowed.contains(key) {
      reject("manifest", "unknown field: " + key)
    }
  }
  fields
}

///|
fn batch_text(
  fields : Map[String, Json],
  key : String,
  maximum : Int32,
) -> String raise CrateError {
  let text = match fields.get(key) {
    Some(String(text)) => text
    _ => {
      reject("manifest", "expected string: " + key)
      ""
    }
  }
  if text.is_empty() || @utf8.encode(text).length() > maximum {
    reject("manifest", "empty or oversized field: " + key)
  }
  for c in text.iter() {
    if c.to_int() < 32 || c.to_int() == 127 {
      reject("manifest", "control character in field: " + key)
    }
  }
  text
}

///|
fn copy_batch_task(task : BatchTask) -> BatchTask {
  { ..task, files: task.files.map(fn(files) { files.copy() }), }
}

///|
/// Parse <=1 MiB UTF-8 JSON, depth <=8, unique keys/IDs, 1..64 tasks.
/// Unknown fields and explicit empty selections are errors before any callbacks.
pub fn parse_batch_manifest(data : Bytes) -> BatchManifest raise CrateError {
  if data.length() > 1048576 {
    reject("limit", "batch manifest exceeds 1 MiB")
  }
  let text = @utf8.decode(data) catch {
    _ => {
      reject("manifest", "manifest must be UTF-8")
      ""
    }
  }
  let value = @json.parse(text, max_nesting_depth=8, reject_duplicate_keys=true) catch {
    _ => {
      reject("manifest", "invalid, duplicate-key or over-nested JSON")
      Json::null()
    }
  }
  let fields = batch_fields(value, ["schema", "tasks"])
  if batch_text(fields, "schema", 64) != "swarmcrate.audit-manifest.v1" {
    reject("manifest", "unsupported batch manifest schema")
  }
  let items = match fields.get("tasks") {
    Some(Array(items)) => items
    _ => {
      reject("manifest", "tasks must be an array")
      []
    }
  }
  if items.is_empty() || items.length() > 64 {
    reject("limit", "expected 1..64 batch tasks")
  }
  let ids : Map[String, Bool] = Map([])
  let tasks : Array[BatchTask] = []
  for item in items {
    let fields = batch_fields(item, ["id", "metainfo", "payload", "files"])
    let id = batch_text(fields, "id", 128)
    if ids.contains(id) {
      reject("manifest", "duplicate task ID: " + id)
    }
    ids[id] = true
    let metainfo = batch_text(fields, "metainfo", 4096)
    let payload = batch_text(fields, "payload", 4096)
    let files = match fields.get("files") {
      None => None
      Some(Array(paths)) => {
        if paths.is_empty() || paths.length() > 65536 {
          reject("selection", "expected a nonempty bounded file selection")
        }
        let selected : Array[String] = []
        for value in paths {
          let path = match value {
            String(path) => path
            _ => {
              reject("manifest", "selected paths must be strings")
              ""
            }
          }
          let parts = path.split("/").map(fn(s) { s.to_owned() }).to_array()
          if parts.is_empty() || parts.length() > 32 {
            reject("selection", "invalid selected path depth")
          }
          for part in parts {
            check_component(part)
          }
          selected.push(path)
        }
        Some(selected)
      }
      _ => {
        reject("manifest", "files must be a nonempty array when present")
        None
      }
    }
    tasks.push({ id, metainfo, payload, files, })
  }
  {
    tasks,
    digest: @crypto.bytes_to_hex_string(@crypto.sha256(data)),
    byte_length: data.length(),
  }
}

///|
/// Return independent copies, not the runner's frozen task definitions.
pub fn batch_manifest_tasks(manifest : BatchManifest) -> Array[BatchTask] {
  manifest.tasks.map(copy_batch_task)
}

///|
fn batch_subject(
  byte_length : Int32,
  digest : String,
  info : TorrentInfo?,
) -> Json {
  j_object([
    ("metainfo_sha256", Json::string(digest)),
    ("metainfo_bytes", Json::string(byte_length.to_string())),
    (
      "info_hash_v1",
      optional_text(
        match info {
          Some(info) => info.info_hash_v1
          None => None
        },
      ),
    ),
    (
      "info_hash_v2",
      optional_text(
        match info {
          Some(info) => info.info_hash_v2
          None => None
        },
      ),
    ),
    ("name", optional_text(info.map(fn(info) { info.name }))),
    ("mode", optional_text(info.map(fn(info) { mode_name(info.mode) }))),
  ])
}

///|
fn batch_info_copy(info : TorrentInfo) -> TorrentInfo {
  {
    ..info,
    files: info.files.map(fn(file) { { ..file, path: file.path.copy(), } }),
    trackers: info.trackers.map(fn(tier) { tier.copy() }),
    web_seeds: info.web_seeds.copy(),
  }
}

///|
fn batch_scope_copy(scope : VerificationScope) -> VerificationScope {
  {
    ..scope,
    selected_files: scope.selected_files.copy(),
    required_files: scope.required_files.copy(),
  }
}

///|
fn batch_selection(
  task : BatchTask,
  info : TorrentInfo,
) -> Array[Int32]? raise CrateError {
  task.files.map(fn(paths) raise CrateError {
    let by_path : Map[String, Int32] = Map([])
    for i, file in info.files {
      by_path[file.path.join("/")] = i
    }
    paths.map(fn(path) raise CrateError {
      match by_path.get(path) {
        Some(index) => index
        None => {
          reject("selection", "selected path is not in metainfo: " + path)
          0
        }
      }
    })
  })
}

///|
fn batch_scope_json(scope : VerificationScope) -> Json {
  j_object([
    ("complete", Json::boolean(scope.complete)),
    (
      "selected_files",
      Json::array(
        scope.selected_files.map(fn(i) { Json::number(i.to_double()) }),
      ),
    ),
    (
      "required_files",
      Json::array(
        scope.required_files.map(fn(i) { Json::number(i.to_double()) }),
      ),
    ),
  ])
}

///|
// Bound untrusted callback messages independently of the summary's scope budget.
fn batch_message(text : String, limit : Int32) -> String {
  let out = StringBuilder()
  for c in text.iter().take(limit) {
    out.write_char(c)
  }
  out.to_string()
}

///|
fn batch_error_row(
  index : Int32,
  id : String,
  subject : Json,
  code : String,
  detail : String,
) -> Json {
  j_object([
    ("index", Json::number(index.to_double())),
    ("id", Json::string(id)),
    ("outcome", Json::string("ERROR")),
    ("subject", subject),
    ("scope", Json::null()),
    ("verification", Json::null()),
    ("receipt_sha256", Json::null()),
    (
      "error",
      j_object([
        ("code", Json::string(batch_message(code, 64))),
        ("detail", Json::string(batch_message(detail, 256))),
      ]),
    ),
  ])
}

///|
fn batch_verified_row(
  index : Int32,
  task : BatchTask,
  subject : Json,
  report : VerificationReport,
  receipt : VerificationReceipt,
  detail_limit : Int32,
) -> Json {
  let receipt_bytes = @utf8.encode(receipt_json_text(receipt))
  j_object([
    ("index", Json::number(index.to_double())),
    ("id", Json::string(task.id)),
    (
      "outcome",
      Json::string(
        if !report.ok {
          "FAIL"
        } else if report.scope.complete {
          "PASS"
        } else {
          "PARTIAL_PASS"
        },
      ),
    ),
    (
      "requested_files",
      match task.files {
        Some(paths) => Json::array(paths.map(Json::string))
        None => Json::null()
      },
    ),
    ("subject", subject),
    ("scope", batch_scope_json(report.scope)),
    (
      "verification",
      j_object([
        ("ok", Json::boolean(report.ok)),
        ("checked_pieces", Json::number(report.checked_pieces.to_double())),
        ("skipped_pieces", Json::number(report.skipped_pieces.to_double())),
        ("failed_pieces", Json::number(report.failed_pieces.to_double())),
        (
          "unreadable_pieces",
          Json::number(report.unreadable_pieces.to_double()),
        ),
        (
          "file_issue_count",
          Json::number(report.file_issues.length().to_double()),
        ),
        ("details_truncated", Json::boolean(report.details_truncated)),
        ("details_included", Json::boolean(false)),
      ]),
    ),
    (
      "receipt_sha256",
      Json::string(@crypto.bytes_to_hex_string(@crypto.sha256(receipt_bytes))),
    ),
    ("receipt_bytes", Json::string(receipt_bytes.length().to_string())),
    ("receipt_detail_limit", Json::number(detail_limit.to_double())),
    ("error", Json::null()),
  ])
}

///|
/// Sequential independent audits. Only checked CrateError task failures are isolated;
/// programming panics are not caught. finish must recheck caller-owned storage before acceptance.
/// A summary quota failure records ERROR for that task and continues, never dropping later jobs.
pub fn audit_batch(
  manifest : BatchManifest,
  load : (Int32, BatchTask) -> Bytes raise CrateError,
  observe : (Int32, TorrentInfo, VerificationScope) -> Array[Int64?] raise CrateError,
  read : (Int32, Int32, Int64, Int32) -> Bytes raise CrateError,
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
    None,
  )
}

///|
fn audit_batch_impl(
  manifest : BatchManifest,
  load : (Int32, BatchTask) -> Bytes raise CrateError,
  observe : (Int32, TorrentInfo, VerificationScope) -> Array[Int64?] raise CrateError,
  read : (Int32, Int32, Int64, Int32) -> Bytes raise CrateError,
  finish : ((Int32) -> Unit raise CrateError)?,
  detail_limit : Int32,
  max_summary_bytes : Int32,
  on_progress : ((BatchProgress) -> Bool raise CrateError)?,
) -> BatchAudit raise CrateError {
  let tasks = manifest.tasks
  // Reserve 4 KiB for every possible compact error row and 4 KiB for the envelope.
  if detail_limit < 1 ||
    detail_limit > 10000 ||
    max_summary_bytes < (tasks.length() + 1) * 4096 ||
    max_summary_bytes > 16777216 {
    reject("limit", "invalid batch detail or summary budget")
  }
  let control = on_progress.map(fn(callback) {
    BatchControl::{
      callback,
      digest: manifest.digest,
      task_count: tasks.length(),
      completed: 0,
      passed: 0,
      partial: 0,
      failed: 0,
      errors: 0,
      reads: 0L,
      bytes: 0L,
      task_reads: 0,
      task_bytes: 0L,
      error: None,
    }
  })
  emit_batch_progress(control, "start")
  let rows : Array[Json] = []
  let mut used = 4096
  let mut passed = 0
  let mut partial = 0
  let mut failed = 0
  let mut errors = 0
  let mut complete = true
  for index, task in tasks {
    if control is Some(control) {
      control.task_reads = 0
      control.task_bytes = 0L
    }
    emit_batch_progress(
      control,
      "before_task",
      task_index=Some(index),
      task_id=Some(task.id),
    )
    let mut subject = Json::null()
    let (initial_row, initial_outcome, initial_full_scope) = try {
      let torrent = load(index, copy_batch_task(task))
      if torrent.length() > 16777216 {
        reject("limit", "metainfo exceeds 16 MiB")
      }
      emit_batch_progress(
        control,
        "after_load",
        task_index=Some(index),
        task_id=Some(task.id),
      )
      let digest = @crypto.bytes_to_hex_string(@crypto.sha256(torrent))
      subject = batch_subject(torrent.length(), digest, None)
      let info = inspect_torrent(torrent)
      subject = batch_subject(torrent.length(), digest, Some(info))
      let selected = batch_selection(task, info)
      let scope = verification_scope(torrent, selected_files=selected)
      emit_batch_progress(
        control,
        "before_observe",
        task_index=Some(index),
        task_id=Some(task.id),
      )
      let sizes = observe(index, batch_info_copy(info), batch_scope_copy(scope))
      let payload_read = fn(
        file : Int32,
        offset : Int64,
        n : Int32,
      ) raise CrateError {
        read(index, file, offset, n)
      }
      let (report, receipt) = match control {
        None =>
          verify_with_receipt(
            torrent,
            sizes,
            payload_read,
            detail_limit~,
            selected_files=selected,
          )
        Some(control) =>
          verify_with_control(
            torrent,
            sizes,
            payload_read,
            fn(event) raise CrateError {
              batch_verification_progress(control, index, task.id, event)
            },
            detail_limit~,
            selected_files=selected,
          )
      }
      emit_batch_progress(
        control,
        "before_finish",
        task_index=Some(index),
        task_id=Some(task.id),
      )
      if finish is Some(check) {
        check(index)
      }
      (
        batch_verified_row(index, task, subject, report, receipt, detail_limit),
        if !report.ok {
          "FAIL"
        } else if report.scope.complete {
          "PASS"
        } else {
          "PARTIAL_PASS"
        },
        report.scope.complete,
      )
    } catch {
      CrateError(code, detail) => {
        // A progress abort is global; ordinary task errors, even named cancelled, are local.
        check_batch_control(control)
        (batch_error_row(index, task.id, subject, code, detail), "ERROR", false)
      }
    }
    check_batch_control(control)
    let mut row = initial_row
    let mut outcome = initial_outcome
    let mut full_scope = initial_full_scope
    let remaining = tasks.length() - index - 1
    let mut bytes = @utf8.encode(row.stringify()).length() + 1
    if bytes > max_summary_bytes - used - remaining * 4096 {
      row = batch_error_row(
        index,
        task.id,
        subject,
        "summary_limit",
        "task result exceeds remaining summary budget; no result accepted",
      )
      outcome = "ERROR"
      full_scope = false
      bytes = @utf8.encode(row.stringify()).length() + 1
    }
    used += bytes
    rows.push(row)
    complete = complete && full_scope
    match outcome {
      "PASS" => passed += 1
      "PARTIAL_PASS" => partial += 1
      "FAIL" => failed += 1
      _ => errors += 1
    }
    if control is Some(control) {
      control.completed = rows.length()
      control.passed = passed
      control.partial = partial
      control.failed = failed
      control.errors = errors
    }
    emit_batch_progress(
      control,
      "task_complete",
      task_index=Some(index),
      task_id=Some(task.id),
      task_outcome=Some(outcome),
    )
  }
  emit_batch_progress(control, "before_summary")
  let outcome = if errors > 0 {
    "ERROR"
  } else if failed > 0 {
    "FAIL"
  } else if partial > 0 {
    "PARTIAL_PASS"
  } else {
    "PASS"
  }
  let value = j_object([
    ("schema", Json::string("swarmcrate.audit-batch.v1")),
    (
      "producer",
      j_object([
        ("name", Json::string("SwarmCrate")),
        ("version", Json::string("0.13.0")),
      ]),
    ),
    ("manifest_sha256", Json::string(manifest.digest)),
    ("manifest_bytes", Json::string(manifest.byte_length.to_string())),
    ("task_count", Json::number(tasks.length().to_double())),
    ("processed_tasks", Json::number(rows.length().to_double())),
    ("verified_tasks", Json::number((passed + partial + failed).to_double())),
    ("pass_tasks", Json::number(passed.to_double())),
    ("partial_pass_tasks", Json::number(partial.to_double())),
    ("failed_tasks", Json::number(failed.to_double())),
    ("error_tasks", Json::number(errors.to_double())),
    ("all_tasks_processed", Json::boolean(true)),
    ("all_scopes_complete", Json::boolean(complete)),
    ("all_full_pass", Json::boolean(passed == tasks.length())),
    ("ok", Json::boolean(errors == 0 && failed == 0)),
    ("outcome", Json::string(outcome)),
    ("is_digital_signature", Json::boolean(false)),
    ("publisher_authenticated", Json::boolean(false)),
    ("tasks", Json::array(rows)),
  ])
  let text = value.stringify()
  if @utf8.encode(text).length() > max_summary_bytes {
    reject("limit", "batch envelope exceeds summary budget")
  }
  emit_batch_progress(control, "finalize")
  { text, exit_code: if errors > 0 { 1 } else if failed > 0 { 2 } else { 0 }, }
}

///|
pub fn batch_audit_json_text(audit : BatchAudit) -> String {
  audit.text
}

///|
/// 1 if any task ERROR, otherwise 2 for integrity FAIL, otherwise 0 (including partial success).
pub fn batch_audit_exit_code(audit : BatchAudit) -> Int32 {
  audit.exit_code
}
