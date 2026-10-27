///|
extern "js" fn cli_fixture() -> String =
  #| () => {
  #|   const fs=process.getBuiltinModule('node:fs'),os=process.getBuiltinModule('node:os'),p=process.getBuiltinModule('node:path');
  #|   const dir=fs.mkdtempSync(p.join(os.tmpdir(),'swarmcrate-cli-'));
  #|   fs.mkdirSync(p.join(dir,'input'));
  #|   fs.writeFileSync(p.join(dir,'input','a.txt'),'hello');
  #|   return dir;
  #| }

///|
extern "js" fn cli_cleanup(path : String) -> Unit =
  #| path => process.getBuiltinModule('node:fs').rmSync(path,{recursive:true,force:true})

///|
test "CLI creates usable files edits endpoints verifies and uses meaningful exit codes" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  for mode in ["v1", "v2", "hybrid"] {
    let torrent = dir + "/" + mode + ".torrent"
    let created = execute([
      "create",
      dir + "/input",
      torrent,
      "--mode",
      mode,
      "--piece-length",
      "16384",
    ])
    assert_eq(created.code, 0)
    assert_true(created.output.contains("info_hash"))
    assert_eq(execute(["inspect", torrent]).code, 0)
    assert_true(
      execute(["magnet", torrent]).output.has_prefix("magnet:?xt=urn:"),
    )
    assert_eq(
      execute([
        "verify",
        torrent,
        dir + "/input",
        "--html",
        dir + "/" + mode + ".html",
      ]).code,
      0,
    )
    assert_eq(execute(["verify", torrent, dir + "/missing"]).code, 2)
    let diagnostic_path = dir + "/" + mode + "-diagnostics.json"
    let diagnosed = execute([
      "verify",
      torrent,
      dir + "/input",
      "--diagnostics",
      diagnostic_path,
    ])
    assert_eq(diagnosed.code, 0)
    assert_eq(
      diagnosed.output,
      execute(["verify", torrent, dir + "/input"]).output,
    )
    assert_true(
      @utf8.decode(@host.read_metainfo(diagnostic_path)).contains(
        "swarmcrate.diagnostics.v1",
      ),
    )
    let receipt = dir + "/" + mode + "-receipt.json"
    let with_receipt = execute([
      "verify",
      torrent,
      dir + "/input",
      "--receipt",
      receipt,
    ])
    assert_eq(with_receipt.code, 0)
    assert_eq(
      with_receipt.output,
      execute(["verify", torrent, dir + "/input"]).output,
    )
    assert_true(
      @utf8.decode(@host.read_metainfo(receipt)).contains(
        "swarmcrate.receipt.v1",
      ),
    )
    assert_eq(
      execute(["verify", torrent, dir + "/input", "--receipt", receipt]).code,
      1,
    )
    assert_eq(
      execute([
        "edit",
        torrent,
        dir + "/edited-" + mode + ".torrent",
        "--tracker",
        "https://example.org/announce",
      ]).code,
      0,
    )
    assert_eq(execute(["create", dir + "/input", torrent]).code, 1)
  }
  assert_eq(execute(["create", "a", "b", "--bad"]).code, 1)
  assert_eq(execute(["verify"]).code, 1)
  assert_eq(execute(["help"]).code, 0)
  for command in ["plan", "create", "inspect", "magnet", "verify", "edit"] {
    assert_eq(execute([command, "--help"]).code, 0)
  }
  let auto = dir + "/auto.torrent"
  assert_eq(execute(["create", dir + "/input", auto]).code, 0)
  assert_eq(@lib.inspect_torrent(@host.read_metainfo(auto)).piece_length, 16384)
  assert_eq(
    execute([
      "create",
      dir + "/input",
      dir + "/bad.torrent",
      "--piece-length",
      "invalid",
    ]).code,
    1,
  )
  cli_cleanup(dir)
}

///|
test "CLI planning shares creation options and requires no output path" {
  let dir = cli_fixture()
  errdefer cli_cleanup(dir)
  let planned = execute(["plan", dir + "/input"])
  assert_eq(planned.code, 0)
  assert_true(planned.output.contains("swarmcrate.plan.v1"))
  assert_true(planned.output.contains("\"real_bytes\": \"5\""))
  assert_eq(execute(["plan", dir + "/input", "extra"]).code, 1)
  assert_eq(execute(["plan", dir + "/input", "--mode", "invalid"]).code, 1)
  assert_eq(execute(["plan", dir + "/input", "--piece-length", "17"]).code, 1)
  assert_eq(execute(["plan", dir + "/input", "--private"]).code, 1)
  assert_eq(
    execute([
      "plan",
      dir + "/input",
      "--private",
      "--tracker",
      "https://example.org/announce",
    ]).code,
    0,
  )
  cli_cleanup(dir)
}
