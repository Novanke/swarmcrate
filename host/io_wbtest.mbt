///|
extern "js" fn fixture() -> String =
  #| () => {
  #|   const fs=process.getBuiltinModule('node:fs'),os=process.getBuiltinModule('node:os'),p=process.getBuiltinModule('node:path');
  #|   const dir=fs.mkdtempSync(p.join(os.tmpdir(),'swarmcrate-test-'));
  #|   fs.mkdirSync(p.join(dir,'folder'));
  #|   fs.writeFileSync(p.join(dir,'folder','hello.txt'),'hello');
  #|   return dir;
  #| }

///|
extern "js" fn cleanup_fixture(path : String) -> Unit =
  #| path => process.getBuiltinModule('node:fs').rmSync(path,{recursive:true,force:true})

///|
test "atomic publication preserves existing files and removes staging after normal completion" {
  let dir = fixture()
  errdefer cleanup_fixture(dir)
  let path = dir + "/atomic.torrent"
  write_new_atomic(path, b"complete bytes")
  assert_eq(read_metainfo(path), b"complete bytes")
  assert_true(
    try {
      write_new_atomic(path, b"replace")
      false
    } catch {
      _ => true
    },
  )
  assert_eq(read_metainfo(path), b"complete bytes")
  write_new_atomic(dir + "/empty", b"")
  assert_eq(stat(dir + "/empty").length, 0L)
  assert_true(
    !directory_names(dir, 100).any(fn(name) { name.has_prefix(".swarmcrate-") }),
  )
  cleanup_fixture(dir)
}

///|
test "disk adapter scans reads bounded ranges and refuses to overwrite" {
  let directory = fixture()
  errdefer cleanup_fixture(directory)
  {
    let (name, single, sources) = scan(directory + "/folder")
    assert_eq(name, "folder")
    assert_true(!single)
    assert_eq(sources.length(), 1)
    assert_eq(read_source(sources, 0, 1L, 3), b"ell")
    let output = directory + "/out.torrent"
    write_new(output, b"data")
    assert_eq(read_metainfo(output), b"data")
    assert_true(
      try {
        write_new(output, b"bad")
        false
      } catch {
        _ => true
      },
    )
    assert_eq(read_metainfo(output), b"data")
    assert_eq(stat(directory + "/missing").kind, "missing")
  }
  cleanup_fixture(directory)
}

///|
extern "js" fn mutate_fixture(path : String, content : String) -> Unit =
  #| (path,content) => {
  #|   const fs=process.getBuiltinModule('node:fs');
  #|   fs.writeFileSync(path,content);
  #|   fs.utimesSync(path,new Date('2000-01-01'),new Date('2000-01-01'));
  #| }

///|
test "completion check detects edits after the last read and newly appearing empty files" {
  let directory = fixture()
  errdefer cleanup_fixture(directory)
  let path = directory + "/folder/hello.txt"
  let snapshot = stat(path)
  assert_eq(read_range(path, 0L, 5, stamp=snapshot.stamp), b"hello")
  check_unchanged(path, snapshot)
  mutate_fixture(path, "world")
  assert_true(
    try {
      check_unchanged(path, snapshot)
      false
    } catch {
      _ => true
    },
  )
  let absent = directory + "/empty"
  let missing = stat(absent)
  check_unchanged(absent, missing)
  mutate_fixture(absent, "")
  assert_true(
    try {
      check_unchanged(absent, missing)
      false
    } catch {
      _ => true
    },
  )
  let empty = stat(absent)
  mutate_fixture(absent, "new")
  assert_true(
    try {
      check_unchanged(absent, empty)
      false
    } catch {
      _ => true
    },
  )
  cleanup_fixture(directory)
}
