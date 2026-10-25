///|
/// Read only real files into the callback index space. BEP 47 padding belongs
/// to the SHA-1 storage stream, never to the filesystem or real-file indices.
fn read_v1_layout(
  info : BNode,
  name : String,
  piece : Int64,
) -> (Array[SourceFile], Array[DataEntry], Bool, Int64) raise CrateError {
  let single = lookup(info, "length") is Some(_)
  let nodes = if single {
    if lookup(info, "files") is Some(_) {
      reject("metainfo", "length and files are mutually exclusive")
    }
    [info]
  } else {
    as_list(require_key(info, "files"))
  }
  if nodes.is_empty() || nodes.length() > 65536 {
    reject("limit", "expected 1..65536 v1 storage entries including padding")
  }
  let files : Array[SourceFile] = []
  let entries : Array[DataEntry] = []
  let mut total = 0L
  for node in nodes {
    let attr = match lookup(node, "attr") {
      Some(value) => as_text(value)
      None => ""
    }
    if (attr != "" && (attr != "p" || single)) ||
      lookup(node, "symlink path") is Some(_) {
      reject("metainfo", "unsupported v1 file attribute or symlink")
    }
    let length = as_int(require_key(node, "length"))
    if length < 0L || length > 9007199254740991L - total {
      reject("limit", "invalid v1 storage length")
    }
    // The extension permits an omitted padding path. Present paths still use
    // our safe component subset, but are not resolved, opened or deduplicated.
    let path : Array[String] = if single {
      [name]
    } else {
      match lookup(node, "path") {
        None => {
          if attr != "p" {
            reject("metainfo", "missing real-file path")
          }
          []
        }
        Some(value) => {
          let parts : Array[String] = []
          for component in as_list(value) {
            let part = as_text(component)
            check_component(part)
            parts.push(part)
          }
          if parts.is_empty() || parts.length() > 32 {
            reject("path", "expected 1..32 v1 path components")
          }
          parts
        }
      }
    }
    if attr == "p" {
      if length == 0L || length >= piece || total % piece + length != piece {
        reject("padding", "v1 padding must fill a partial piece boundary")
      }
      entries.push({ source: -1, length, padding: true, })
    } else {
      entries.push({ source: files.length(), length, padding: false, })
      files.push({ path, length, })
    }
    total += length
  }
  if (total + piece - 1L) / piece > 400000L {
    reject("limit", "too many v1 storage pieces including padding")
  }
  (files, entries, single, total)
}
