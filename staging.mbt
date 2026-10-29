///|
/// Versioned provenance for one exclusive publication stage, not a signature.
pub(all) struct StagingOwner {
  operation_id : String
  stage_path : String
  target_path : String
  directory_id : String
  data_id : String
  pid : Int32
  host : String
  user : String
  expected_bytes : Int64
}

///|
/// Filesystem/process observations are supplied by an adapter; the core performs no I/O.
pub(all) struct StagingEvidence {
  stage_path : String
  directory_id : String
  data_id : String
  actual_bytes : Int64
  local_host : String
  local_user : String
  owner_state : String
}

///|
pub(all) struct StagingAssessment {
  status : String
  reason : String
  operation_id : String?
}

///|
fn staging_value(
  fields : Map[String, Json],
  key : String,
  maximum : Int32,
) -> String raise CrateError {
  let text = match fields.get(key) {
    Some(String(s)) => s
    _ => {
      reject("staging", "missing or invalid string: " + key)
      ""
    }
  }
  if text.is_empty() || @utf8.encode(text).length() > maximum {
    reject("staging", "empty or oversized field: " + key)
  }
  for c in text.iter() {
    if c.to_int() < 32 || c.to_int() == 127 {
      reject("staging", "control character in owner record")
    }
  }
  text
}

///|
pub fn valid_staging_operation_id(id : String) -> Bool {
  id.length() == 32 &&
  id
  .iter()
  .all(fn(c) {
    let n = c.to_int()
    (n >= 48 && n <= 57) || (n >= 97 && n <= 102)
  })
}

///|
pub fn parse_staging_owner(data : Bytes) -> StagingOwner raise CrateError {
  if data.length() > 65536 {
    reject("limit", "staging owner record exceeds 64 KiB")
  }
  let text = @utf8.decode(data) catch {
    _ => {
      reject("staging", "owner record must be UTF-8")
      ""
    }
  }
  let value = @json.parse(text, max_nesting_depth=4, reject_duplicate_keys=true) catch {
    _ => {
      reject("staging", "invalid owner JSON")
      Json::null()
    }
  }
  let fields = match value {
    Object(fields) => fields
    _ => {
      reject("staging", "owner must be an object")
      Map([])
    }
  }
  let allowed = [
    "schema", "operation_id", "stage_path", "target_path", "directory_id", "data_id",
    "pid", "host", "user", "expected_bytes",
  ]
  for key, _ in fields {
    if !allowed.contains(key) {
      reject("staging", "unknown owner field: " + key)
    }
  }
  if staging_value(fields, "schema", 64) != "swarmcrate.staging-owner.v1" {
    reject("staging", "unsupported owner record")
  }
  let operation_id = staging_value(fields, "operation_id", 32)
  if !valid_staging_operation_id(operation_id) {
    reject("staging", "invalid operation ID")
  }
  let pid = match fields.get("pid") {
    Some(Number(n, ..)) if n >= 1 &&
      n <= 2147483647.0 &&
      n == n.to_int().to_double() => n.to_int()
    _ => {
      reject("staging", "invalid owner PID")
      0
    }
  }
  let expected = @string.parse_int64(
    staging_value(fields, "expected_bytes", 20),
  ) catch {
    _ => {
      reject("staging", "invalid expected byte count")
      0L
    }
  }
  if expected < 0L || expected > 2147483647L {
    reject("staging", "owner byte count outside Bytes range")
  }
  {
    operation_id,
    stage_path: staging_value(fields, "stage_path", 16384),
    target_path: staging_value(fields, "target_path", 16384),
    directory_id: staging_value(fields, "directory_id", 256),
    data_id: staging_value(fields, "data_id", 256),
    pid,
    host: staging_value(fields, "host", 256),
    user: staging_value(fields, "user", 256),
    expected_bytes: expected,
  }
}

///|
pub fn staging_owner_bytes(owner : StagingOwner) -> Bytes raise CrateError {
  let data = @utf8.encode(
    j_object([
      ("schema", Json::string("swarmcrate.staging-owner.v1")),
      ("operation_id", Json::string(owner.operation_id)),
      ("stage_path", Json::string(owner.stage_path)),
      ("target_path", Json::string(owner.target_path)),
      ("directory_id", Json::string(owner.directory_id)),
      ("data_id", Json::string(owner.data_id)),
      ("pid", Json::number(owner.pid.to_double())),
      ("host", Json::string(owner.host)),
      ("user", Json::string(owner.user)),
      ("expected_bytes", Json::string(owner.expected_bytes.to_string())),
    ]).stringify(),
  )
  ignore(parse_staging_owner(data))
  data
}

///|
/// Only matching local provenance, stable object identities and positively absent PID qualify.
/// Existing/reused PIDs and all uncertain observations are preserved, regardless of age.
pub fn assess_staging(
  marker : Bytes,
  local_receipt : Bytes?,
  evidence : StagingEvidence,
) -> StagingAssessment {
  let owner = parse_staging_owner(marker) catch {
    _ =>
      return {
        status: "unverified",
        reason: "invalid or legacy ownership record",
        operation_id: None,
      }
  }
  let result = fn(status : String, reason : String) {
    StagingAssessment::{
      status,
      reason,
      operation_id: Some(owner.operation_id),
    }
  }
  if owner.stage_path != evidence.stage_path ||
    owner.directory_id != evidence.directory_id ||
    owner.data_id != evidence.data_id ||
    owner.directory_id == "unsupported" ||
    owner.data_id == "unsupported" {
    return result(
      "unverified", "stage or data identity does not match ownership record",
    )
  }
  if evidence.actual_bytes < 0L || evidence.actual_bytes > owner.expected_bytes {
    return result("unverified", "data length exceeds the owned staging range")
  }
  if local_receipt != Some(marker) {
    return result("unverified", "matching machine-local receipt is unavailable")
  }
  if owner.host != evidence.local_host || owner.user != evidence.local_user {
    return result("unverified", "owner context differs from the local context")
  }
  match evidence.owner_state {
    "dead" => result("orphan", "matching owner process is positively absent")
    "alive" =>
      result("active", "owner PID exists; reused PIDs are also preserved")
    _ => result("unverified", "owner process state is uncertain")
  }
}
