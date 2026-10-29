///|
priv struct BatchDiskState {
  mut metainfo : String
  mut metainfo_stat : @host.FileStat?
  mut paths : Array[String]
  mut stats : Array[@host.FileStat?]
  mut finished : Bool
}

///|
fn check_batch_disk_source(
  state : BatchDiskState,
) -> Unit raise @lib.CrateError {
  @host.check_unchanged(state.metainfo, state.metainfo_stat.unwrap())
  for file, before in state.stats {
    if before is Some(before) {
      @host.check_unchanged(state.paths[file], before)
    }
  }
}

///|
fn batch_disk_locator(
  base : String,
  input : String,
) -> String raise @lib.CrateError {
  if input.split_once(":") is Some((drive, rest)) &&
    drive.length() == 1 &&
    !rest.has_prefix("/") &&
    !rest.has_prefix("\\") {
    fail(
      "drive-relative paths are ambiguous; use an absolute or ordinary relative path",
    )
  }
  @host.resolve_from(base, input)
}

///|
fn audit_batch_command(args : Arguments) -> CommandResult raise @lib.CrateError {
  audit_batch_command_impl(args, None)
}

///|
fn audit_batch_command_impl(
  args : Arguments,
  on_progress : ((@lib.BatchProgress) -> Bool raise @lib.CrateError)?,
) -> CommandResult raise @lib.CrateError {
  arity(args, 2)
  let manifest_path = @host.resolve(args.positionals[0])
  // Freeze the preflighted destination before any observer can change the process CWD.
  let output = @host.resolve(args.positionals[1])
  let manifest_stat = @host.stat(manifest_path)
  if manifest_stat.kind != "file" || manifest_stat.length > 1048576L {
    fail("expected a regular batch manifest of at most 1 MiB")
  }
  let manifest = @lib.parse_batch_manifest(@host.read_metainfo(manifest_path))
  @host.check_unchanged(manifest_path, manifest_stat)
  let base = @host.resolve(manifest_path + "/..")
  let tasks = @lib.batch_manifest_tasks(manifest).map(fn(
    task,
  ) raise @lib.CrateError {
    {
      ..task,
      metainfo: batch_disk_locator(base, task.metainfo),
      payload: batch_disk_locator(base, task.payload),
    }
  })
  let input_paths = [manifest_path]
  for task in tasks {
    input_paths.push(task.metainfo)
    input_paths.push(task.payload)
  }
  // Protect every declared root, including later tasks that cannot parse or load.
  // Conservatively disallow summary publication anywhere within a payload root.
  preflight_reports([output], input_paths)
  let state : BatchDiskState = {
    metainfo: "",
    metainfo_stat: None,
    paths: [],
    stats: [],
    finished: false,
  }
  let load = fn(index : Int32, _ : @lib.BatchTask) raise @lib.CrateError {
    state.metainfo = tasks[index].metainfo
    state.metainfo_stat = None
    state.paths = []
    state.stats = []
    state.finished = false
    state.metainfo_stat = Some(@host.stat(state.metainfo))
    @host.read_metainfo(state.metainfo)
  }
  let observe = fn(
    index : Int32,
    info : @lib.TorrentInfo,
    scope : @lib.VerificationScope,
  ) raise @lib.CrateError {
    let root = tasks[index].payload
    state.paths = info.files.map(fn(file) {
      if info.single_file {
        root
      } else {
        root + "/" + file.path.join("/")
      }
    })
    state.stats = Array::make(info.files.length(), None)
    let sizes : Array[Int64?] = Array::make(info.files.length(), None)
    for file in scope.required_files {
      let observed = @host.stat(state.paths[file])
      state.stats[file] = Some(observed)
      sizes[file] = if observed.kind == "file" {
        Some(observed.length)
      } else {
        None
      }
    }
    sizes
  }
  let read = fn(
    _ : Int32,
    file : Int32,
    offset : Int64,
    n : Int32,
  ) raise @lib.CrateError {
    @host.read_range(
      state.paths[file],
      offset,
      n,
      stamp=state.stats[file].unwrap().stamp,
    )
  }
  let finish = Some(fn(_ : Int32) raise @lib.CrateError {
    check_batch_disk_source(state)
    state.finished = true
  })
  let mut final_progress : @lib.BatchProgress? = None
  let audit = match on_progress {
    None => @lib.audit_batch(manifest, load, observe, read, finish~)
    Some(callback) =>
      @lib.audit_batch_with_control(
        manifest,
        load,
        observe,
        read,
        fn(event) raise @lib.CrateError {
          final_progress = Some(event)
          let proceed = callback(event)
          // A successful final observer may itself have changed the current source.
          if proceed &&
            state.finished &&
            ["task_complete", "before_summary", "finalize"].contains(
              event.phase,
            ) {
            check_batch_disk_source(state)
          }
          proceed
        },
        finish~,
      )
  }
  // Bind this run to the exact manifest that defined it; do not publish after edits.
  @host.check_unchanged(manifest_path, manifest_stat)
  let text = @lib.batch_audit_json_text(audit)
  if on_progress is Some(callback) {
    let event = { ..final_progress.unwrap(), phase: "before_write", }
    if !callback(event) {
      raise @lib.CrateError(
        "cancelled", "batch audit cancelled before publication",
      )
    }
    @host.check_unchanged(manifest_path, manifest_stat)
    if state.finished {
      check_batch_disk_source(state)
    }
  }
  @host.write_new_atomic(output, @utf8.encode(text))
  { code: @lib.batch_audit_exit_code(audit), output: text, }
}

///|
/// Opt-in global batch control. Cancellation returns code 3 and never a candidate summary.
/// args includes audit-batch, the manifest and a new summary path.
pub fn execute_batch_with_control(
  args : Array[String],
  on_progress : (@lib.BatchProgress) -> Bool raise @lib.CrateError,
) -> CommandResult {
  try {
    if args.is_empty() || args[0] != "audit-batch" {
      fail("expected audit-batch and its paths")
    }
    audit_batch_command_impl(parse_args(args, [], false), Some(on_progress))
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
