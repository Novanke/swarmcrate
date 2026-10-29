///|
priv struct StageSnapshot {
  owner : @lib.StagingOwner
  marker : FileStat
  data : FileStat
  receipt : FileStat
  receipt_path : String
  parent : String
  parent_id : String
}

///|
/// A local observation, not an importable deletion manifest. Only inspection constructs it.
pub struct StagingInspection {
  priv path : String
  priv assessment : @lib.StagingAssessment
  priv snapshot : StageSnapshot?
}

///|
fn staging_reject(reason : String) -> Unit raise @lib.CrateError {
  raise @lib.CrateError("staging", reason)
}

///|
fn stage_handle_call(
  h : StageHandle,
  op : String,
  bytes~ : Bytes = b"",
) -> Unit raise @lib.CrateError {
  let result = stage_handle_io(h, op, bytes)
  if result.error() != "" {
    raise @lib.CrateError("io", result.error())
  }
}

///|
fn publish_owned(path : String, bytes : Bytes) -> Unit raise @lib.CrateError {
  let h = stage_begin(resolve(path), bytes.length())
  if h.error() != "" {
    raise @lib.CrateError("io", h.error())
  }
  try {
    let owner = @lib.parse_staging_owner(@utf8.encode(h.info()))
    stage_handle_call(h, "owner", bytes=@lib.staging_owner_bytes(owner))
    stage_handle_call(h, "data", bytes~)
    stage_handle_call(h, "link")
  } catch {
    @lib.CrateError(code, detail) => {
      ignore(stage_handle_io(h, "dispose", b""))
      raise @lib.CrateError(code, detail)
    }
  }
  ignore(stage_handle_io(h, "dispose", b""))
}

///|
fn stage_record(path : String) -> (FileStat, Bytes) raise @lib.CrateError {
  let before = stat(path)
  if before.kind != "file" || before.length < 1L || before.length > 65536L {
    staging_reject("ownership record is not a regular file of 1..65536 bytes")
  }
  let bytes = read_range(path, 0L, before.length.to_int(), stamp=before.stamp)
  check_unchanged(path, before)
  (before, bytes)
}

///|
fn stage_same_directory(
  path : String,
  expected : String,
) -> Unit raise @lib.CrateError {
  if stat(path).kind != "directory" ||
    expected == "unsupported" ||
    stage_call("identity", path) != expected {
    staging_reject("directory identity changed or unsupported")
  }
}

///|
fn inspect_owned_stage(
  path : String,
) -> StagingInspection raise @lib.CrateError {
  let parent = stage_call("parent", path)
  let parent_id = stage_call("identity", parent)
  let directory_id = stage_call("identity", path)
  if stat(path).kind != "directory" ||
    directory_names(path, 3) != ["data", "owner.json"] {
    staging_reject(
      "stage must contain exactly data and owner.json; unknown members are preserved",
    )
  }
  let (marker, bytes) = stage_record(path + "/owner.json")
  let owner = @lib.parse_staging_owner(bytes)
  let name = stage_call("name", path)
  let prefix = ".swarmcrate-" + owner.operation_id + "-"
  if !name.has_prefix(prefix) ||
    name.length() != prefix.length() + 6 ||
    owner.stage_path != path ||
    stage_call("parent", owner.target_path) != parent ||
    resolve(owner.target_path) != owner.target_path ||
    owner.target_path == path {
    staging_reject("stage name or same-parent target binding is invalid")
  }
  let data = stat(path + "/data")
  if data.kind != "file" {
    staging_reject("staged data is not regular")
  }
  let data_id = stage_call("identity", path + "/data")
  let receipt_path = stage_call("receipt", "", argument=owner.operation_id)
  ignore(stage_call("receipt-safe", receipt_path))
  let (receipt, local_bytes) = stage_record(receipt_path)
  let context = @json.parse(stage_call("context", "")) catch {
    _ => raise @lib.CrateError("io", "invalid local context")
  }
  let fields = match context {
    Object(fields) => fields
    _ => Map([])
  }
  let assessment = @lib.assess_staging(bytes, Some(local_bytes), {
    stage_path: path,
    directory_id,
    data_id,
    actual_bytes: data.length,
    local_host: json_text(fields.get("host").unwrap()),
    local_user: json_text(fields.get("user").unwrap()),
    owner_state: stage_call("probe", "", argument=owner.pid.to_string()),
  })
  stage_same_directory(parent, parent_id)
  stage_same_directory(path, directory_id)
  check_unchanged(path + "/data", data)
  check_unchanged(path + "/owner.json", marker)
  check_unchanged(receipt_path, receipt)
  if directory_names(path, 3) != ["data", "owner.json"] {
    staging_reject("stage membership changed")
  }
  {
    path,
    assessment,
    snapshot: Some({
      owner,
      marker,
      data,
      receipt,
      receipt_path,
      parent,
      parent_id,
    }),
  }
}

///|
/// Inspect one directory. Missing/legacy/foreign/active/uncertain stages never qualify.
pub fn inspect_staging(
  path : String,
) -> StagingInspection raise @lib.CrateError {
  let absolute = resolve(path)
  inspect_owned_stage(absolute) catch {
    @lib.CrateError(_, detail) =>
      {
        path: absolute,
        assessment: {
          status: "unverified",
          reason: detail,
          operation_id: None,
        },
        snapshot: None,
      }
  }
}

///|
/// Read-only, one-level inventory. The bound includes all parent entries, not only stages.
pub fn scan_staging(
  parent : String,
  max_entries~ : Int32 = 4096,
) -> Array[StagingInspection] raise @lib.CrateError {
  if max_entries < 1 || max_entries > 4096 {
    staging_reject("parent entry budget must be in 1..4096")
  }
  let absolute = resolve(parent)
  let before = stat(absolute)
  if before.kind != "directory" {
    staging_reject("expected a staging parent directory")
  }
  let names = directory_names(absolute, max_entries)
  let result = []
  for name in names {
    if name.has_prefix(".swarmcrate-") {
      result.push(inspect_staging(resolve_from(absolute, name)))
    }
  }
  check_unchanged(absolute, before)
  result
}

///|
pub fn staging_inspection_json(inspection : StagingInspection) -> Json {
  Json::object(
    Map([
      ("schema", Json::string("swarmcrate.staging-inspection.v1")),
      ("path", Json::string(inspection.path)),
      ("status", Json::string(inspection.assessment.status)),
      ("reason", Json::string(inspection.assessment.reason)),
      (
        "operation_id",
        match inspection.assessment.operation_id {
          Some(id) => Json::string(id)
          None => Json::null()
        },
      ),
    ]),
  )
}

///|
fn check_stage_snapshot(
  path : String,
  snapshot : StageSnapshot,
  claimed : Bool,
) -> Unit raise @lib.CrateError {
  stage_same_directory(snapshot.parent, snapshot.parent_id)
  stage_same_directory(path, snapshot.owner.directory_id)
  let expected = if claimed {
    ["cleanup.lock", "data", "owner.json"]
  } else {
    ["data", "owner.json"]
  }
  expected.sort()
  let names = directory_names(path, 4)
  if names != expected {
    staging_reject(
      "stage has unknown members or another cleanup claim: " + names.join(","),
    )
  }
  check_unchanged(path + "/data", snapshot.data)
  check_unchanged(path + "/owner.json", snapshot.marker)
  check_unchanged(snapshot.receipt_path, snapshot.receipt)
  if stage_call("probe", "", argument=snapshot.owner.pid.to_string()) != "dead" {
    staging_reject("owner process is present or uncertain")
  }
}

///|
/// Remove exactly one freshly inspected orphan and its matching local receipt.
/// This is nonrecursive, guarded local cleanup, not protection against hostile ancestor swaps.
pub fn cleanup_staging(
  inspection : StagingInspection,
  operation_id : String,
) -> Unit raise @lib.CrateError {
  if inspection.assessment.status != "orphan" ||
    inspection.assessment.operation_id != Some(operation_id) {
    staging_reject("cleanup requires an orphan and its exact operation ID")
  }
  let snapshot = match inspection.snapshot {
    Some(snapshot) => snapshot
    None => {
      staging_reject("inspection has no ownership evidence")
      abort("unreachable")
    }
  }
  let path = inspection.path
  check_stage_snapshot(path, snapshot, false)
  let claim = path + "/cleanup.lock"
  let token = stage_call("claim", claim)
  try {
    check_stage_snapshot(path, snapshot, true)
    // Check the directory again before each exact unlink; no path from marker.target is deleted.
    stage_same_directory(path, snapshot.owner.directory_id)
    ignore(stage_call("unlink", path + "/data", argument=snapshot.data.stamp))
    stage_same_directory(path, snapshot.owner.directory_id)
    ignore(
      stage_call("unlink", path + "/owner.json", argument=snapshot.marker.stamp),
    )
    stage_same_directory(path, snapshot.owner.directory_id)
    ignore(stage_call("unlink", claim, argument=token))
    ignore(stage_call("rmdir", path, argument=snapshot.owner.directory_id))
    ignore(
      stage_call(
        "unlink",
        snapshot.receipt_path,
        argument=snapshot.receipt.stamp,
      ),
    )
  } catch {
    @lib.CrateError(code, detail) => {
      // Remove only this claim, and only if its containing directory still matches.
      try {
        stage_same_directory(path, snapshot.owner.directory_id)
        ignore(stage_call("unlink", claim, argument=token))
      } catch {
        _ => ()
      }
      raise @lib.CrateError(code, detail)
    }
  }
}
