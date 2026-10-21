///|
pub(all) enum TorrentMode {
  V1
  V2
  Hybrid
} derive(Eq, Debug)

///|
pub extend TorrentMode with Eq::{equal, not_equal}

///|
pub extend TorrentMode with Debug::{to_repr}

///|
pub(all) struct SourceFile {
  path : Array[String]
  length : Int64
}

///|
pub(all) struct CreateOptions {
  name : String
  mode : TorrentMode
  piece_length : Int32
  single_file : Bool
  private_torrent : Bool
  trackers : Array[Array[String]]
  web_seeds : Array[String]
  comment : String
}

///|
pub fn create_options(name : String) -> CreateOptions {
  {
    name,
    mode: Hybrid,
    piece_length: 262144,
    single_file: false,
    private_torrent: false,
    trackers: [],
    web_seeds: [],
    comment: "",
  }
}

///|
fn check_component(part : String) -> Unit raise CrateError {
  if part.is_empty() ||
    @utf8.encode(part).length() > 255 ||
    part == "." ||
    part == ".." {
    reject("path", "empty dot traversal or oversized path component")
  }
  if part.has_suffix(".") || part.has_suffix(" ") {
    reject("path", "trailing dot/space is not portable: " + part)
  }
  for c in part.iter() {
    if c.to_int() < 32 || "/\\:*?\"<>|".contains_char(c) {
      reject("path", "unsafe path component: " + part)
    }
  }
  let stem = part.split(".").next().unwrap_or("").to_owned().to_lower()
  if [
      "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6",
      "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7",
      "lpt8", "lpt9",
    ].contains(stem) {
    reject("path", "reserved device name: " + part)
  }
}

///|
/// The creator uses a portable path subset and reserves .pad for hybrid alignment.
pub fn validate_sources(files : Array[SourceFile]) -> Int64 raise CrateError {
  if files.is_empty() || files.length() > 65536 {
    reject("limit", "expected 1..65536 source files")
  }
  let paths : Map[String, Bool] = Map([])
  let folded : Map[String, Bool] = Map([])
  let mut total = 0L
  for file in files {
    if file.path.is_empty() || file.path.length() > 32 {
      reject("path", "expected 1..32 path components")
    }
    for component in file.path {
      check_component(component)
    }
    if file.path[0].to_lower() == ".pad" {
      reject("path", ".pad is reserved for virtual padding")
    }
    let path = file.path.join("/")
    if paths.contains(path) || folded.contains(path.to_lower()) {
      reject("path", "duplicate or case-colliding file: " + path)
    }
    paths.set(path, true)
    folded.set(path.to_lower(), true)
    if file.length < 0 || file.length > 9007199254740991L - total {
      reject(
        "limit", "negative length or total exceeds exact host offset range",
      )
    }
    total += file.length
  }
  for file in files {
    let mut prefix = ""
    for index in 0..<(file.path.length() - 1) {
      prefix = if index == 0 {
        file.path[index]
      } else {
        prefix + "/" + file.path[index]
      }
      if folded.contains(prefix.to_lower()) {
        reject("path", "file/directory path collision: " + prefix)
      }
    }
  }
  total
}

///|
fn path_compare(a : Array[String], b : Array[String]) -> Int32 {
  let count = if a.length() < b.length() { a.length() } else { b.length() }
  for index in 0..<count {
    let order = byte_compare(@utf8.encode(a[index]), @utf8.encode(b[index]))
    if order != 0 {
      return order
    }
  }
  a.length() - b.length()
}

///|
/// Return indices rather than silently reordering a caller's read callback mapping.
pub fn sorted_source_indices(
  files : Array[SourceFile],
) -> Array[Int32] raise CrateError {
  ignore(validate_sources(files))
  let indices = Array::makei(files.length(), fn(i) { i })
  indices.sort_by(fn(a, b) { path_compare(files[a].path, files[b].path) })
  indices
}

///|
fn check_url(url : String, tracker : Bool) -> Unit raise CrateError {
  let allowed = url.has_prefix("https://") ||
    url.has_prefix("http://") ||
    (tracker && url.has_prefix("udp://"))
  if !allowed || url.length() > 4096 {
    reject("url", "unsupported or oversized URL")
  }
  for c in url.iter() {
    if c.to_int() <= 32 || c.to_int() == 127 {
      reject("url", "URL contains whitespace or control characters")
    }
  }
  let rest = url.split_once("://").unwrap().1.to_owned()
  let authority = rest
    .split("/")
    .next()
    .unwrap_or("")
    .split("?")
    .next()
    .unwrap_or("")
  if rest.is_empty() ||
    authority.is_empty() ||
    authority.contains("@") ||
    authority.has_prefix(":") ||
    rest.contains("#") ||
    rest.contains("\\") ||
    rest.has_prefix("/") ||
    rest.has_prefix("?") ||
    rest.has_prefix("#") {
    reject("url", "URL has no host")
  }
}

///|
pub fn validate_options(
  files : Array[SourceFile],
  options : CreateOptions,
) -> Unit raise CrateError {
  let total = validate_sources(files)
  check_component(options.name)
  let piece = options.piece_length
  if piece < 16384 || piece > 16777216 || (piece & (piece - 1)) != 0 {
    reject("piece_length", "expected a power of two in 16 KiB..16 MiB")
  }
  if (total + piece.to_int64() - 1) / piece.to_int64() > 400000L {
    reject("limit", "too many pieces; select a larger piece length")
  }
  if options.single_file &&
    (
      files.length() != 1 ||
      files[0].path.length() != 1 ||
      files[0].path[0] != options.name
    ) {
    reject("path", "single-file name must match its only source file")
  }
  if options.private_torrent && options.trackers.is_empty() {
    reject("tracker", "private torrents require at least one tracker")
  }
  if options.trackers.length() > 64 ||
    options.web_seeds.length() > 64 ||
    options.comment.length() > 16384 {
    reject("limit", "too much metadata")
  }
  for tier in options.trackers {
    if tier.is_empty() || tier.length() > 64 {
      reject("tracker", "expected 1..64 tracker URLs per tier")
    }
    for url in tier {
      check_url(url, true)
    }
  }
  for url in options.web_seeds {
    check_url(url, false)
  }
}
