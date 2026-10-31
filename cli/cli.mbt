///|
extern "js" fn raw_arguments() -> FixedArray[String] =
  #| () => process.argv.slice(2)

///|
pub fn arguments() -> Array[String] {
  raw_arguments()[:].to_owned()
}

///|
pub extern "js" fn set_exit_code(code : Int32) -> Unit =
  #| code => {process.exitCode=code}

///|
pub(all) struct CommandResult {
  code : Int32
  output : String
}

///|
priv struct Arguments {
  positionals : Array[String]
  values : Map[String, Array[String]]
  private_flag : Bool
}

///|
fn fail(detail : String) -> Unit raise @lib.CrateError {
  raise @lib.CrateError("usage", detail)
}

///|
fn parse_args(
  args : Array[String],
  allowed : Array[String],
  private_allowed : Bool,
) -> Arguments raise @lib.CrateError {
  let positionals : Array[String] = []
  let values : Map[String, Array[String]] = Map([])
  let mut private_flag = false
  let mut literal = false
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if literal {
      positionals.push(arg)
    } else if arg == "--" {
      literal = true
    } else if arg == "--private" && private_allowed {
      if private_flag {
        fail("duplicate --private")
      }
      private_flag = true
    } else if arg.has_prefix("--") {
      if !allowed.contains(arg) || i + 1 >= args.length() {
        fail("unknown option or missing value: " + arg)
      }
      let list = values.get_or_init(arg, fn() { [] })
      if !list.is_empty() &&
        arg != "--tracker" &&
        arg != "--web-seed" &&
        arg != "--file" {
        fail("duplicate option: " + arg)
      }
      i += 1
      list.push(args[i])
    } else {
      positionals.push(arg)
    }
    i += 1
  }
  { positionals, values, private_flag, }
}

///|
fn one(args : Arguments, key : String, fallback : String) -> String {
  match args.values.get(key) {
    Some(v) => v[0]
    None => fallback
  }
}

///|
fn many(args : Arguments, key : String) -> Array[String] {
  args.values.get(key).unwrap_or([])
}

///|
fn arity(args : Arguments, n : Int32) -> Unit raise @lib.CrateError {
  if args.positionals.length() != n {
    fail("wrong number of paths; run help for usage")
  }
}

///|
priv struct PreparedInput {
  snapshot : @host.ScanSnapshot
  files : Array[@lib.SourceFile]
  options : @lib.CreateOptions
}

///|
fn prepare_input(args : Arguments) -> PreparedInput raise @lib.CrateError {
  let input = args.positionals[0]
  let snapshot = @host.scan_snapshot(input)
  let base = snapshot.name
  let single = snapshot.single_file
  let sources = snapshot.sources
  let name = one(args, "--name", base)
  let files = sources.map(fn(s) {
    if single {
      { ..s.descriptor, path: [name], }
    } else {
      s.descriptor
    }
  })
  let mode = match one(args, "--mode", "hybrid") {
    "v1" => @lib.V1
    "v2" => @lib.V2
    "hybrid" => @lib.Hybrid
    _ => {
      fail("mode must be v1 v2 or hybrid")
      @lib.Hybrid
    }
  }
  let piece_option = one(args, "--piece-length", "auto")
  let piece = if piece_option == "auto" {
    @lib.recommend_piece_length(files, mode~)
  } else {
    @string.parse_int(piece_option) catch {
      _ => {
        fail("--piece-length must be auto or an integer byte count")
        0
      }
    }
  }
  let options : @lib.CreateOptions = {
    ..@lib.create_options(name),
    mode,
    single_file: single,
    piece_length: piece,
    private_torrent: args.private_flag,
    trackers: many(args, "--tracker").map(fn(url) { [url] }),
    web_seeds: many(args, "--web-seed"),
    comment: one(args, "--comment", ""),
  }
  { snapshot, files, options, }
}

///|
fn plan(args : Arguments) -> CommandResult raise @lib.CrateError {
  arity(args, 1)
  let input = prepare_input(args)
  let result = @lib.plan_torrent(input.files, input.options)
  @host.check_scan_unchanged(input.snapshot)
  { code: 0, output: @lib.plan_json(result).stringify(indent=2), }
}

///|
fn create(args : Arguments) -> CommandResult raise @lib.CrateError {
  create_impl(args, None)
}

///|
fn create_impl(
  args : Arguments,
  on_progress : ((@lib.CreationProgress) -> Bool raise @lib.CrateError)?,
) -> CommandResult raise @lib.CrateError {
  arity(args, 2)
  let output = @host.resolve(args.positionals[1])
  ignore(@host.canonical_path(output))
  if @host.stat(output).kind != "missing" ||
    @host.stat(output + "/..").kind != "directory" {
    fail("creation requires a new output and an existing parent directory")
  }
  let input = prepare_input(args)
  let read = fn(i : Int32, offset : Int64, n : Int32) raise @lib.CrateError {
    @host.read_source(input.snapshot.sources, i, offset, n)
  }
  let mut final_progress : @lib.CreationProgress? = None
  let torrent = match on_progress {
    None => @lib.create_torrent(input.files, input.options, read)
    Some(callback) =>
      @lib.create_torrent_with_control(input.files, input.options, read, fn(
        event,
      ) raise @lib.CrateError {
        final_progress = Some(event)
        callback(event)
      })
  }
  // Recheck both file contents/identity tokens and the scanned directory roster.
  @host.check_scan_unchanged(input.snapshot)
  let info = @lib.inspect_torrent(torrent)
  let magnet = @lib.torrent_magnet(torrent)
  match on_progress {
    None => @host.write_new(output, torrent)
    Some(callback) => {
      let event = { ..final_progress.unwrap(), phase: "before_write", }
      if !callback(event) {
        raise @lib.CrateError(
          "cancelled", "torrent creation cancelled before publication",
        )
      }
      // The observer itself may have edited a source after the first recheck.
      @host.check_scan_unchanged(input.snapshot)
      @host.write_new_atomic(output, torrent)
    }
  }
  {
    code: 0,
    output: Json::object(
      Map([
        ("output", Json::string(@host.resolve(output))),
        ("magnet", Json::string(magnet)),
        ("info", @lib.info_json(info)),
      ]),
    ).stringify(indent=2),
  }
}

///|
fn output_key(
  path : String,
  input~ : Bool = false,
) -> String raise @lib.CrateError {
  // Invalid/unreadable inputs remain task/scope-local errors. Never authorize
  // a link traversal here; keep their lexical guard while outputs stay strict.
  let canonical = @host.canonical_path(path) catch {
    @lib.CrateError(code, detail) =>
      if input {
        @host.resolve(path)
      } else {
        raise @lib.CrateError(code, detail)
      }
  }
  let key = canonical
    .split("\\")
    .map(fn(s) { s.to_owned() })
    .to_array()
    .join("/")
    .to_lower()
  if key.has_prefix("//?/unc/") {
    "//" + key[8:].to_owned()
  } else if (key.has_prefix("//?/") || (input && key.has_prefix("//./"))) &&
    key.length() >= 7 &&
    key[5] == ':' &&
    key[6] == '/' {
    key[4:].to_owned()
  } else if !input && (key.has_prefix("//?/") || key.has_prefix("//./")) {
    fail("unsupported device namespace")
    ""
  } else {
    key
  }
}

///|
fn path_key_contains(parent : String, child : String) -> Bool {
  parent == child ||
  child.has_prefix(if parent.has_suffix("/") { parent } else { parent + "/" })
}

///|
fn preflight_reports(
  outputs : Array[String],
  payload_paths : Array[String],
) -> Unit raise @lib.CrateError {
  if outputs.is_empty() {
    return
  }
  let keys : Map[String, Bool] = Map([])
  let payload_keys = payload_paths.map(fn(path) raise @lib.CrateError {
    output_key(path, input=true)
  })
  for output in outputs {
    let key = output_key(output)
    if keys.contains(key) {
      fail("report outputs must use distinct paths")
    }
    keys[key] = true
    for payload in payload_keys {
      if path_key_contains(payload, key) || path_key_contains(key, payload) {
        fail("report output overlaps a listed payload path: " + output)
      }
    }
    if @host.stat(output).kind != "missing" {
      fail("report output already exists: " + output)
    }
    if @host.stat(@host.resolve(output) + "/..").kind != "directory" {
      fail("report output parent must be an existing directory: " + output)
    }
  }
}

///|
fn verify(args : Arguments) -> CommandResult raise @lib.CrateError {
  arity(args, 2)
  let torrent = @host.read_metainfo(args.positionals[0])
  let info = @lib.inspect_torrent(torrent)
  let root = args.positionals[1]
  let names = many(args, "--file")
  let selected : Array[Int32]? = if names.is_empty() {
    None
  } else {
    let indices : Array[Int32] = []
    let by_path : Map[String, Int32] = Map([])
    for i, file in info.files {
      by_path[file.path.join("/")] = i
    }
    for name in names {
      match by_path.get(name) {
        Some(i) => indices.push(i)
        None =>
          fail("--file must exactly match an inspected relative path: " + name)
      }
    }
    Some(indices)
  }
  let scope = @lib.verification_scope(torrent, selected_files=selected)
  let paths = info.files.map(fn(f) {
    if info.single_file {
      root
    } else {
      root + "/" + f.path.join("/")
    }
  })
  let html = one(args, "--html", "")
  let receipt_path = one(args, "--receipt", "")
  let diagnostics_path = one(args, "--diagnostics", "")
  for
    (key, path) in [
      ("--receipt", receipt_path),
      ("--diagnostics", diagnostics_path),
    ] {
    if args.values.contains(key) && path == "" {
      fail(key + " requires a nonempty output path")
    }
  }
  let detail_limit = @string.parse_int(one(args, "--detail-limit", "4096")) catch {
    _ => {
      fail("--detail-limit must be an integer in 1..10000")
      0
    }
  }
  if detail_limit < 1 || detail_limit > 10000 {
    fail("--detail-limit must be an integer in 1..10000")
  }
  let outputs : Array[String] = []
  if receipt_path != "" {
    outputs.push(receipt_path)
  }
  if diagnostics_path != "" {
    outputs.push(diagnostics_path)
  }
  if html != "" {
    outputs.push(html)
  }
  preflight_reports(outputs, paths)
  let stats : Array[@host.FileStat?] = Array::make(paths.length(), None)
  let sizes : Array[Int64?] = Array::make(paths.length(), None)
  for i in scope.required_files {
    let stat = @host.stat(paths[i])
    stats[i] = Some(stat)
    sizes[i] = if stat.kind == "file" { Some(stat.length) } else { None }
  }
  let read = fn(i : Int32, offset : Int64, n : Int32) raise @lib.CrateError {
    @host.read_range(paths[i], offset, n, stamp=stats[i].unwrap().stamp)
  }
  let (report, receipt) = if receipt_path != "" || diagnostics_path != "" {
    let (report, receipt) = @lib.verify_with_receipt(
      torrent,
      sizes,
      read,
      detail_limit~,
      selected_files=selected,
    )
    (report, Some(receipt))
  } else {
    (
      @lib.verify_payload(
        torrent,
        sizes,
        read,
        detail_limit~,
        selected_files=selected,
      ),
      None,
    )
  }
  for i in scope.required_files {
    @host.check_unchanged(paths[i], stats[i].unwrap())
  }
  if receipt is Some(receipt) {
    if receipt_path != "" {
      @host.write_new(
        receipt_path,
        @utf8.encode(@lib.receipt_json_text(receipt)),
      )
    }
    if diagnostics_path != "" {
      @host.write_new(
        diagnostics_path,
        @utf8.encode(@lib.receipt_diagnostics_json_text(receipt)),
      )
    }
  }
  if html != "" {
    @host.write_new(html, @utf8.encode(@lib.verification_html(info, report)))
  }
  {
    code: if report.ok {
      0
    } else {
      2
    },
    output: @lib.verification_json(report).stringify(indent=2),
  }
}

///|
fn dispatch(args : Array[String]) -> CommandResult raise @lib.CrateError {
  let help_flags = ["help", "--help", "-h"]
  if args.is_empty() ||
    help_flags.contains(args[0]) ||
    (
      args.length() == 2 &&
      [
        "plan", "create", "inspect", "magnet", "verify", "edit", "audit-batch", "staging-list",
        "staging-clean",
      ].contains(args[0]) &&
      help_flags.contains(args[1])
    ) {
    return {
      code: 0,
      output: "SwarmCrate 0.14.1 — offline BitTorrent metadata and payload verification\n" +
      "plan INPUT [--mode v1|v2|hybrid] [--piece-length auto|BYTES] [--name NAME] [--tracker URL]... [--web-seed URL]... [--private] [--comment TEXT]\n" +
      "create INPUT OUTPUT.torrent [--mode v1|v2|hybrid] [--piece-length auto|BYTES] [--name NAME] [--tracker URL]... [--web-seed URL]... [--private] [--comment TEXT]\n" +
      "inspect INPUT.torrent\nmagnet INPUT.torrent\nverify INPUT.torrent PAYLOAD [--file RELATIVE/PATH]... [--receipt RECEIPT.json] [--diagnostics FILES.json] [--html REPORT.html] [--detail-limit 1..10000]\n" +
      "edit INPUT.torrent OUTPUT.torrent [--tracker URL]... [--web-seed URL]...\n" +
      "audit-batch MANIFEST.json SUMMARY.json (relative inputs use the manifest directory; atomic output requires hard links)\n" +
      "staging-list PARENT (read-only, at most 4096 direct entries)\nstaging-clean STAGE --operation ID (one verified dead-owner stage, no recursive deletion)\n" +
      "For a single-file torrent PAYLOAD is the file; for a multifile torrent it is the directory containing the listed paths.\n" +
      "Create defaults to auto piece sizing (aims for 4096 pieces, accounts for v2/hybrid file alignment). Use an explicit byte count for a fixed layout.\n" +
      "Plan reads filesystem metadata only: no payload hashes or output files. Piece-layer bytes are an upper bound, not total metainfo size.\n" +
      "--file selects exact inspected paths (use /). V1 shared boundary pieces can require neighbour files. Partial success is not a full-payload certificate.\n" +
      "--receipt saves unsigned JSON bound to the exact metainfo SHA-256, infohash, file mapping and checked scope; stdout stays swarmcrate.verify.v2.\n" +
      "--diagnostics saves per-file merged candidate ranges for hash mismatch, unreadable pieces, missing/extra bytes. Truncated details mean an incomplete range inventory.\n" +
      "Outputs are new files; existing files are never overwritten. Exit: 0 success, 1 input/I/O error, 2 failed verification.\n" +
      "Core library: Wasm GC and JS. Filesystem CLI: Node.js >=22.16. No network operations.",
    }
  }
  match args[0] {
    "staging-list" | "staging-clean" => staging_command(args)
    "audit-batch" => audit_batch_command(parse_args(args, [], false))
    "plan" | "create" => {
      let parsed = parse_args(
        args,
        [
          "--mode", "--piece-length", "--name", "--tracker", "--web-seed", "--comment",
        ],
        true,
      )
      if args[0] == "plan" {
        plan(parsed)
      } else {
        create(parsed)
      }
    }
    "verify" =>
      verify(
        parse_args(
          args,
          ["--html", "--file", "--receipt", "--diagnostics", "--detail-limit"],
          false,
        ),
      )
    "inspect" | "magnet" => {
      let parsed = parse_args(args, [], false)
      arity(parsed, 1)
      let torrent = @host.read_metainfo(parsed.positionals[0])
      {
        code: 0,
        output: if args[0] == "inspect" {
          @lib.info_json(@lib.inspect_torrent(torrent)).stringify(indent=2)
        } else {
          @lib.torrent_magnet(torrent)
        },
      }
    }
    "edit" => {
      let parsed = parse_args(args, ["--tracker", "--web-seed"], false)
      arity(parsed, 2)
      let data = @host.read_metainfo(parsed.positionals[0])
      let result = @lib.edit_distribution(
        data,
        many(parsed, "--tracker").map(fn(url) { [url] }),
        many(parsed, "--web-seed"),
      )
      @host.write_new(parsed.positionals[1], result)
      {
        code: 0,
        output: @lib.info_json(@lib.inspect_torrent(result)).stringify(indent=2),
      }
    }
    _ => {
      fail("unknown command: " + args[0])
      { code: 1, output: "", }
    }
  }
}

///|
pub fn execute(args : Array[String]) -> CommandResult {
  dispatch(args) catch {
    @lib.CrateError(code, detail) =>
      {
        code: 1,
        output: Json::object(
          Map([("error", Json::string(code)), ("detail", Json::string(detail))]),
        ).stringify(indent=2),
      }
  }
}

///|
/// Controlled creation command. Cancellation exits 3, other errors 1; success matches create.
/// args includes "create" and the normal creation arguments. Atomic publication needs hard links.
pub fn execute_create_with_control(
  args : Array[String],
  on_progress : (@lib.CreationProgress) -> Bool raise @lib.CrateError,
) -> CommandResult {
  try {
    if args.is_empty() || args[0] != "create" {
      fail("expected create and its arguments")
    }
    let parsed = parse_args(
      args,
      [
        "--mode", "--piece-length", "--name", "--tracker", "--web-seed", "--comment",
      ],
      true,
    )
    create_impl(parsed, Some(on_progress))
  } catch {
    @lib.CrateError(code, detail) =>
      {
        code: if code == "cancelled" {
          3
        } else {
          1
        },
        output: Json::object(
          Map([("error", Json::string(code)), ("detail", Json::string(detail))]),
        ).stringify(indent=2),
      }
  }
}
