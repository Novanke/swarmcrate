///|
extern "js" fn departed_pid() -> Int32 =
  #| () => process.getBuiltinModule('node:child_process').spawnSync(process.execPath,['-e','']).pid

///|
fn orphan_fixture(
  dir : String,
) -> (StageHandle, @lib.StagingOwner) raise @lib.CrateError {
  let h = stage_begin(resolve(dir + "/result.json"), 7)
  if h.error() != "" {
    raise @lib.CrateError("test", h.error())
  }
  let owner = {
    ..@lib.parse_staging_owner(@utf8.encode(h.info())),
    pid: departed_pid(),
  }
  stage_handle_call(h, "owner", bytes=@lib.staging_owner_bytes(owner))
  stage_handle_call(h, "data", bytes=b"partial")
  (h, owner)
}

///|
test "orphan cleanup is explicit and preserves sibling task files" {
  let dir = fixture()
  let (h, owner) = orphan_fixture(dir)
  let plan = inspect_staging(owner.stage_path)
  assert_eq(plan.assessment.status, "orphan")
  assert_true(
    try {
      cleanup_staging(plan, "00000000000000000000000000000000")
      false
    } catch {
      _ => true
    },
  )
  assert_eq(stat(owner.stage_path + "/data").length, 7L)
  cleanup_staging(plan, owner.operation_id)
  assert_eq(stat(owner.stage_path).kind, "missing")
  assert_true(
    try {
      cleanup_staging(plan, owner.operation_id)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    stat(stage_call("receipt", "", argument=owner.operation_id)).kind,
    "missing",
  )
  assert_eq(read_metainfo(dir + "/folder/hello.txt"), b"hello")
  ignore(stage_handle_io(h, "dispose", b""))
  cleanup_fixture(dir)
}

///|
extern "js" fn swap_stage(path : String) -> Unit =
  #| p => {const fs=process.getBuiltinModule('node:fs');fs.renameSync(p,p+'.saved');fs.mkdirSync(p);fs.writeFileSync(p+'/unrelated','keep');}

///|
extern "js" fn restore_stage(path : String) -> Unit =
  #| p => {const fs=process.getBuiltinModule('node:fs');fs.unlinkSync(p+'/unrelated');fs.rmdirSync(p);fs.renameSync(p+'.saved',p);}

///|
test "replaced staging directory invalidates its previous cleanup plan" {
  let dir = fixture()
  let (h, owner) = orphan_fixture(dir)
  let plan = inspect_staging(owner.stage_path)
  swap_stage(owner.stage_path)
  assert_true(
    try {
      cleanup_staging(plan, owner.operation_id)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(read_metainfo(owner.stage_path + "/unrelated"), b"keep")
  restore_stage(owner.stage_path)
  cleanup_staging(inspect_staging(owner.stage_path), owner.operation_id)
  ignore(stage_handle_io(h, "dispose", b""))
  cleanup_fixture(dir)
}

///|
test "stale inspection and unexpected membership refuse cleanup" {
  let dir = fixture()
  let (h, owner) = orphan_fixture(dir)
  let plan = inspect_staging(owner.stage_path)
  mutate_fixture(owner.stage_path + "/data", "changed")
  assert_true(
    try {
      cleanup_staging(plan, owner.operation_id)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(read_metainfo(owner.stage_path + "/data"), b"changed")
  let next = inspect_staging(owner.stage_path)
  write_new(owner.stage_path + "/foreign", b"preserve")
  assert_true(
    try {
      cleanup_staging(next, owner.operation_id)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(inspect_staging(owner.stage_path).assessment.status, "unverified")
  ignore(
    stage_call(
      "unlink",
      owner.stage_path + "/foreign",
      argument=stat(owner.stage_path + "/foreign").stamp,
    ),
  )
  cleanup_staging(inspect_staging(owner.stage_path), owner.operation_id)
  ignore(stage_handle_io(h, "dispose", b""))
  cleanup_fixture(dir)
}
