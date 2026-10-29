///|
// Only OS fixture setup/cleanup crosses the JS bridge; workflow and checks are MoonBit.
extern "js" fn fixture() -> String =
  #| () => {
  #|   const fs=process.getBuiltinModule('node:fs'),os=process.getBuiltinModule('node:os'),p=process.getBuiltinModule('node:path');
  #|   const root=fs.mkdtempSync(p.join(os.tmpdir(),'swarmcrate-batch-example-'));
  #|   fs.mkdirSync(p.join(root,'input'));
  #|   return root;
  #| }

///|
extern "js" fn cleanup(root : String) -> Unit =
  #| root => {
  #|   const fs=process.getBuiltinModule('node:fs'),os=process.getBuiltinModule('node:os'),p=process.getBuiltinModule('node:path');
  #|   const resolved=p.resolve(root);
  #|   if(p.dirname(resolved)!==p.resolve(os.tmpdir()) || !p.basename(resolved).startsWith('swarmcrate-batch-example-')) throw Error('unexpected fixture path');
  #|   fs.rmSync(resolved,{recursive:true,force:true});
  #| }

///|
fn task(
  id : String,
  seed : String,
  payload : String,
  files~ : Array[String]? = None,
) -> Json {
  let fields = [
    ("id", Json::string(id)),
    ("metainfo", Json::string(seed)),
    ("payload", Json::string(payload)),
  ]
  if files is Some(files) {
    fields.push(("files", Json::array(files.map(Json::string))))
  }
  Json::object(Map(fields))
}

///|
fn main {
  let root = fixture()
  try {
    @host.write_new(root + "/input/a.txt", b"abc")
    @host.write_new(root + "/input/b.txt", b"def")
    let made = @cli.execute([
      "create",
      root + "/input",
      root + "/seed.torrent",
      "--piece-length",
      "16384",
    ])
    assert_eq(made.code, 0)
    assert_eq(
      @cli.execute([
        "edit",
        root + "/seed.torrent",
        root + "/edited.torrent",
        "--tracker",
        "https://example.org/announce",
      ]).code,
      0,
    )
    let manifest = Json::object(
      Map([
        ("schema", Json::string("swarmcrate.audit-manifest.v1")),
        (
          "tasks",
          Json::array([
            task("release", "seed.torrent", "input"),
            task("unavailable", "missing.torrent", "input"),
            task("missing-payload", "seed.torrent", "absent"),
            task("selected", "seed.torrent", "input", files=Some(["a.txt"])),
            task("distribution-edit", "edited.torrent", "input"),
            task("later", "seed.torrent", "input"),
          ]),
        ),
      ]),
    )
    @host.write_new(root + "/jobs.json", @utf8.encode(manifest.stringify()))
    let result = @cli.execute([
      "audit-batch",
      root + "/jobs.json",
      root + "/summary.json",
    ])
    assert_eq(result.code, 1) // the expected unavailable task takes precedence over FAIL
    assert_eq(
      @host.read_metainfo(root + "/summary.json"),
      @utf8.encode(result.output),
    )
    let fields = match @json.parse(result.output) {
      Object(fields) => fields
      _ => abort("invalid summary")
    }
    assert_eq(fields.get("processed_tasks"), Some(Json::number(6)))
    assert_eq(fields.get("pass_tasks"), Some(Json::number(3)))
    assert_eq(fields.get("partial_pass_tasks"), Some(Json::number(1)))
    assert_eq(fields.get("failed_tasks"), Some(Json::number(1)))
    assert_eq(fields.get("error_tasks"), Some(Json::number(1)))
    println(result.output)
    println(
      "DISK BATCH EXAMPLE PASS: manifest-relative inputs, isolated errors and atomic summary",
    )
  } catch {
    error => {
      cleanup(root)
      abort("disk batch example failed: \{error}")
    }
  }
  cleanup(root)
}
