///|
extern "js" fn make_empty_directory(root : String) -> Unit =
  #| root => process.getBuiltinModule('node:fs').mkdirSync(root + '/folder/empty')

///|
extern "js" fn mutate_directory(root : String, action : String) -> Unit =
  #| (root,action) => {
  #|   const fs=process.getBuiltinModule('node:fs'), folder=root+'/folder', empty=folder+'/empty';
  #|   if (action==='add') fs.writeFileSync(folder+'/new.txt','new');
  #|   else if (action==='fill-empty') fs.writeFileSync(empty+'/new.txt','new');
  #|   else if (action==='add-empty') fs.mkdirSync(folder+'/new-empty');
  #|   else if (action==='remove-empty') fs.rmdirSync(empty);
  #|   else if (action==='rename-empty') fs.renameSync(empty,folder+'/renamed');
  #|   else if (action==='replace-empty') { fs.rmdirSync(empty); fs.mkdirSync(empty); }
  #| }

///|
test "scan snapshots preserve empty directory membership and detect roster changes" {
  for
    action in [
      "add", "fill-empty", "add-empty", "remove-empty", "rename-empty", "replace-empty",
    ] {
    let root = fixture()
    errdefer cleanup_fixture(root)
    make_empty_directory(root)
    let snapshot = scan_snapshot(root + "/folder")
    assert_true(!snapshot.single_file)
    assert_eq(snapshot.sources.length(), 1)
    assert_eq(snapshot.directories.length(), 2)
    assert_eq(snapshot.directories[0].names, ["empty", "hello.txt"])
    check_scan_unchanged(snapshot)
    assert_eq(read_source(snapshot.sources, 0, 0L, 5), b"hello")
    mutate_directory(root, action)
    assert_true(
      try {
        check_scan_unchanged(snapshot)
        false
      } catch {
        _ => true
      },
    )
    cleanup_fixture(root)
  }
  let root = fixture()
  errdefer cleanup_fixture(root)
  let snapshot = scan_snapshot(root + "/folder/hello.txt", max_entries=1)
  assert_true(snapshot.single_file)
  assert_true(snapshot.directories.is_empty())
  check_scan_unchanged(snapshot)
  let (name, single, files) = scan(root + "/folder/hello.txt")
  assert_eq(name, snapshot.name)
  assert_eq(single, snapshot.single_file)
  assert_eq(files[0].descriptor.path, snapshot.sources[0].descriptor.path)
  cleanup_fixture(root)
}

///|
test "membership comparison detects new files even when directory tokens match" {
  for action in ["add", "fill-empty"] {
    let root = fixture()
    errdefer cleanup_fixture(root)
    make_empty_directory(root)
    let snapshot = scan_snapshot(root + "/folder")
    mutate_directory(root, action)
    // Substitute current tokens to independently exercise the membership
    // comparison; no assumption about filesystem timestamp resolution.
    let refreshed : Array[DirectorySnapshot] = []
    for directory in snapshot.directories {
      refreshed.push({ ..directory, stat: stat(directory.absolute_path), })
    }
    let stale_membership = { ..snapshot, directories: refreshed, }
    assert_true(
      try {
        check_scan_unchanged(stale_membership)
        false
      } catch {
        @lib.CrateError(code, _) => code == "changed"
      },
    )
    cleanup_fixture(root)
  }
}

///|
test "entry budgets count nested and empty directories and stop enumeration at the limit" {
  let root = fixture()
  errdefer cleanup_fixture(root)
  make_empty_directory(root)
  let folder = root + "/folder"
  check_scan_unchanged(scan_snapshot(folder, max_entries=2))
  for budget in [0, 1, 200001] {
    assert_true(
      try {
        ignore(scan_snapshot(folder, max_entries=budget))
        false
      } catch {
        @lib.CrateError(code, _) => code == "limit"
      },
    )
  }
  mutate_directory(root, "fill-empty")
  assert_true(
    try {
      ignore(scan_snapshot(folder, max_entries=2))
      false
    } catch {
      @lib.CrateError(code, _) => code == "limit"
    },
  )
  let snapshot = scan_snapshot(folder, max_entries=3)
  assert_eq(snapshot.sources.length(), 2)
  check_scan_unchanged(snapshot)
  cleanup_fixture(root)
}
