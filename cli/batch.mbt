///|
priv struct BatchDiskState {
  mut metainfo : String
  mut metainfo_stat : @host.FileStat?
  mut paths : Array[String]
  mut stats : Array[@host.FileStat?]
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
  arity(args, 2)
  let manifest_path = @host.resolve(args.positionals[0])
  let output = args.positionals[1]
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
  }
  let audit = @lib.audit_batch(
    manifest,
    fn(index, _) raise @lib.CrateError {
      state.metainfo = tasks[index].metainfo
      state.metainfo_stat = Some(@host.stat(state.metainfo))
      state.paths = []
      state.stats = []
      @host.read_metainfo(state.metainfo)
    },
    fn(index, info, scope) raise @lib.CrateError {
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
    },
    fn(_, file, offset, n) raise @lib.CrateError {
      @host.read_range(
        state.paths[file],
        offset,
        n,
        stamp=state.stats[file].unwrap().stamp,
      )
    },
    finish=Some(fn(_) raise @lib.CrateError {
      @host.check_unchanged(state.metainfo, state.metainfo_stat.unwrap())
      for file, before in state.stats {
        if before is Some(before) {
          @host.check_unchanged(state.paths[file], before)
        }
      }
    }),
  )
  // Bind this run to the exact manifest that defined it; do not publish after edits.
  @host.check_unchanged(manifest_path, manifest_stat)
  let text = @lib.batch_audit_json_text(audit)
  @host.write_new_atomic(output, @utf8.encode(text))
  { code: @lib.batch_audit_exit_code(audit), output: text, }
}
