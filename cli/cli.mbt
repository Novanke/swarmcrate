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
      if !list.is_empty() && arg != "--tracker" && arg != "--web-seed" {
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
fn create(args : Arguments) -> CommandResult raise @lib.CrateError {
  arity(args, 2)
  let input = args.positionals[0]
  let output = args.positionals[1]
  let (base, single, sources) = @host.scan(input)
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
  let piece = @string.parse_int(one(args, "--piece-length", "262144")) catch {
    _ => {
      fail("invalid --piece-length")
      0
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
  let torrent = @lib.create_torrent(files, options, (i, offset, n) => {
    @host.read_source(sources, i, offset, n)
  })
  // A final scan catches edits after a source's last block and changes to empty files.
  for source in sources {
    if @host.stat(source.absolute_path).stamp != source.stamp {
      raise @lib.CrateError("io", "source changed before output was committed")
    }
  }
  let info = @lib.inspect_torrent(torrent)
  let magnet = @lib.torrent_magnet(torrent)
  @host.write_new(output, torrent)
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
fn verify(args : Arguments) -> CommandResult raise @lib.CrateError {
  arity(args, 2)
  let torrent = @host.read_metainfo(args.positionals[0])
  let info = @lib.inspect_torrent(torrent)
  let root = args.positionals[1]
  let paths = info.files.map(fn(f) {
    if info.single_file {
      root
    } else {
      root + "/" + f.path.join("/")
    }
  })
  let stats : Array[@host.FileStat] = []
  let sizes : Array[Int64?] = []
  for path in paths {
    let stat = @host.stat(path)
    stats.push(stat)
    sizes.push(if stat.kind == "file" { Some(stat.length) } else { None })
  }
  let report = @lib.verify_payload(torrent, sizes, (i, offset, n) => {
    @host.read_range(paths[i], offset, n, stamp=stats[i].stamp)
  })
  let html = one(args, "--html", "")
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
  if args.is_empty() || ["help", "--help", "-h"].contains(args[0]) {
    return {
      code: 0,
      output: "SwarmCrate 0.1.0 — offline BitTorrent metadata and payload verification\n" +
      "create INPUT OUTPUT.torrent [--mode v1|v2|hybrid] [--piece-length BYTES] [--name NAME] [--tracker URL]... [--web-seed URL]... [--private] [--comment TEXT]\n" +
      "inspect INPUT.torrent\nmagnet INPUT.torrent\nverify INPUT.torrent PAYLOAD [--html REPORT.html]\n" +
      "edit INPUT.torrent OUTPUT.torrent [--tracker URL]... [--web-seed URL]...\n" +
      "For a single-file torrent PAYLOAD is the file; for a multifile torrent it is the directory containing the listed paths.\n" +
      "Outputs are new files; existing files are never overwritten. Exit: 0 success, 1 input/I/O error, 2 failed verification.\n" +
      "Core library: Wasm GC and JS. Filesystem CLI: Node.js >=22.16. No network operations.",
    }
  }
  match args[0] {
    "create" =>
      create(
        parse_args(
          args,
          [
            "--mode", "--piece-length", "--name", "--tracker", "--web-seed", "--comment",
          ],
          true,
        ),
      )
    "verify" => verify(parse_args(args, ["--html"], false))
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
