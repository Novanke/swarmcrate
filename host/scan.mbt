///|
pub(all) struct DiskSource {
  descriptor : @lib.SourceFile
  absolute_path : String
  stamp : String
}

///|
pub(all) struct DirectorySnapshot {
  absolute_path : String
  stat : FileStat
  names : Array[String]
}

///|
pub(all) struct ScanSnapshot {
  name : String
  single_file : Bool
  sources : Array[DiskSource]
  directories : Array[DirectorySnapshot]
}

///|
priv struct ScanState {
  sources : Array[DiskSource]
  directories : Array[DirectorySnapshot]
  mut remaining : Int32
}

///|
fn directory_names(
  directory : String,
  limit : Int32,
) -> Array[String] raise @lib.CrateError {
  let encoded = io("list", directory, size=limit).text()
  let value = @json.parse(encoded) catch {
    _ => raise @lib.CrateError("io", "invalid OS directory JSON")
  }
  let values = match value {
    Array(a) => a
    _ => raise @lib.CrateError("io", "invalid OS directory")
  }
  let names : Array[String] = []
  for value in values {
    names.push(json_text(value))
  }
  // Enumeration order is not a membership change.
  names.sort()
  names
}

///|
fn visit(
  directory : String,
  path : Array[String],
  state : ScanState,
) -> Unit raise @lib.CrateError {
  let before = stat(directory)
  if before.kind != "directory" {
    raise @lib.CrateError(
      "changed",
      "source directory was replaced: " + directory,
    )
  }
  let names = directory_names(directory, state.remaining)
  state.remaining -= names.length()
  state.directories.push({ absolute_path: directory, stat: before, names, })
  for name in names {
    let child = directory + "/" + name
    let child_path = path.copy()
    child_path.push(name)
    if child_path.length() > 32 {
      raise @lib.CrateError("limit", "directory depth exceeds 32 components")
    }
    let info = stat(child)
    if info.kind == "directory" {
      visit(child, child_path, state)
    } else if info.kind == "file" {
      if state.sources.length() >= 65536 {
        raise @lib.CrateError("limit", "source file count exceeds 65536")
      }
      state.sources.push({
        descriptor: { path: child_path, length: info.length, },
        absolute_path: child,
        stamp: info.stamp,
      })
    } else {
      raise @lib.CrateError("io", "non-regular source: " + child)
    }
  }
  check_unchanged(directory, before)
}

///|
/// Retain file tokens and directory membership, including empty directories.
/// The descendant-entry budget includes both files and directories, not the root.
pub fn scan_snapshot(
  path : String,
  max_entries~ : Int32 = 200000,
) -> ScanSnapshot raise @lib.CrateError {
  if max_entries < 1 || max_entries > 200000 {
    raise @lib.CrateError("limit", "scan entry budget must be in 1..200000")
  }
  let absolute = resolve(path)
  let normalized = absolute
    .split("\\")
    .map(fn(p) { p.to_owned() })
    .to_array()
    .join("/")
  let parts = normalized.split("/").to_array()
  let name = parts[parts.length() - 1].to_owned()
  let info = stat(absolute)
  let state : ScanState = {
    sources: [],
    directories: [],
    remaining: max_entries,
  }
  let single_file = info.kind == "file"
  if single_file {
    state.sources.push({
      descriptor: { path: [name], length: info.length, },
      absolute_path: absolute,
      stamp: info.stamp,
    })
  } else if info.kind == "directory" {
    visit(absolute, [], state)
  } else {
    raise @lib.CrateError("io", "expected a regular file or directory")
  }
  ignore(@lib.validate_sources(state.sources.map(fn(s) { s.descriptor })))
  { name, single_file, sources: state.sources, directories: state.directories, }
}

///|
fn check_directory_unchanged(
  snapshot : DirectorySnapshot,
) -> Unit raise @lib.CrateError {
  check_unchanged(snapshot.absolute_path, snapshot.stat)
  if directory_names(snapshot.absolute_path, 200000) != snapshot.names {
    raise @lib.CrateError(
      "changed",
      "source directory membership changed: " + snapshot.absolute_path,
    )
  }
  check_unchanged(snapshot.absolute_path, snapshot.stat)
}

///|
/// Recheck listed files and directories before committing created metadata.
/// These sequential checks are not an atomic filesystem snapshot.
pub fn check_scan_unchanged(
  snapshot : ScanSnapshot,
) -> Unit raise @lib.CrateError {
  for source in snapshot.sources {
    check_unchanged(source.absolute_path, {
      kind: "file",
      length: source.descriptor.length,
      stamp: source.stamp,
    })
  }
  for directory in snapshot.directories {
    check_directory_unchanged(directory)
  }
}

///|
/// Compatibility wrapper; use scan_snapshot/check_scan_unchanged for creation.
pub fn scan(
  path : String,
) -> (String, Bool, Array[DiskSource]) raise @lib.CrateError {
  let snapshot = scan_snapshot(path)
  (snapshot.name, snapshot.single_file, snapshot.sources)
}
