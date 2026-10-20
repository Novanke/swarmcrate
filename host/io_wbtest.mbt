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
