///|
pub(all) struct TorrentInfo {
  name : String
  mode : TorrentMode
  piece_length : Int32
  files : Array[SourceFile]
  single_file : Bool
  private_torrent : Bool
  trackers : Array[Array[String]]
  web_seeds : Array[String]
  comment : String
  info_hash_v1 : String?
  info_hash_v2 : String?
}

///|
fn bn(value : BValue) -> BNode {
  { value, start: 0, end: 0, }
}

///|
fn bn_text(text : String) -> BNode {
  bn(Blob(@utf8.encode(text)))
}

///|
fn bn_int(n : Int64) -> BNode {
  bn(Integer(n))
}

///|
fn bn_dict(pairs : Array[(String, BNode)]) -> BNode {
  bn(Dictionary(pairs.map(fn(p) { (@utf8.encode(p.0), p.1) })))
}

///|
fn dict_pairs(node : BNode) -> Array[(Bytes, BNode)] raise CrateError {
  match node.value {
    Dictionary(pairs) => pairs
    _ => {
      reject("metainfo", "expected dictionary")
      []
    }
  }
}

///|
fn lookup(node : BNode, name : String) -> BNode? raise CrateError {
  let key = @utf8.encode(name)
  for (k, value) in dict_pairs(node) {
    if k == key {
      return Some(value)
    }
  }
  None
}

///|
fn require_key(node : BNode, name : String) -> BNode raise CrateError {
  match lookup(node, name) {
    Some(value) => value
    None => {
      reject("metainfo", "missing field: " + name)
      bn_int(0L)
    }
  }
}

///|
fn as_blob(node : BNode) -> Bytes raise CrateError {
  match node.value {
    Blob(data) => data
    _ => {
      reject("metainfo", "expected byte string")
      b""
    }
  }
}

///|
fn as_text(node : BNode) -> String raise CrateError {
  @utf8.decode(as_blob(node)) catch {
    _ => {
      reject("utf8", "invalid UTF-8 metadata text")
      ""
    }
  }
}

///|
fn as_int(node : BNode) -> Int64 raise CrateError {
  match node.value {
    Integer(n) => n
    _ => {
      reject("metainfo", "expected integer")
      0L
    }
  }
}

///|
fn as_list(node : BNode) -> Array[BNode] raise CrateError {
  match node.value {
    Sequence(items) => items
    _ => {
      reject("metainfo", "expected list")
      []
    }
  }
}

///|
fn read_trackers(top : BNode) -> Array[Array[String]] raise CrateError {
  match lookup(top, "announce-list") {
    Some(tiers) => {
      let result : Array[Array[String]] = []
      for tier in as_list(tiers) {
        let urls : Array[String] = []
        for url in as_list(tier) {
          urls.push(as_text(url))
        }
        result.push(urls)
      }
      result
    }
    None =>
      match lookup(top, "announce") {
        Some(url) => [[as_text(url)]]
        None => []
      }
  }
}

///|
fn read_web_seeds(top : BNode) -> Array[String] raise CrateError {
  match lookup(top, "url-list") {
    Some({ value: Blob(_), .. } as value) => [as_text(value)]
    Some(value) => {
      let out : Array[String] = []
      for item in as_list(value) {
        out.push(as_text(item))
      }
      out
    }
    None => []
  }
}

///|
fn top_fields(info : BNode, options : CreateOptions) -> Array[(String, BNode)] {
  let fields = [("info", info), ("created by", bn_text("SwarmCrate 0.1.0"))]
  if !options.trackers.is_empty() {
    fields.push(("announce", bn_text(options.trackers[0][0])))
    fields.push(
      (
        "announce-list",
        bn(
          Sequence(
            options.trackers.map(fn(tier) { bn(Sequence(tier.map(bn_text))) }),
          ),
        ),
      ),
    )
  }
  if !options.web_seeds.is_empty() {
    fields.push(("url-list", bn(Sequence(options.web_seeds.map(bn_text)))))
  }
  if options.comment != "" {
    fields.push(("comment", bn_text(options.comment)))
  }
  fields
}

///|
fn v1_file_node(file : SourceFile) -> BNode {
  bn_dict([
    ("length", bn_int(file.length)),
    ("path", bn(Sequence(file.path.map(bn_text)))),
  ])
}

///|
/// Create deterministic metainfo. Read indices refer to the original unsorted inputs.
pub fn create_torrent(
  files : Array[SourceFile],
  options : CreateOptions,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
) -> Bytes raise CrateError {
  validate_options(files, options)
  if options.mode == V2 {
    return create_v2_torrent(files, options, read)
  }
  if options.mode == Hybrid {
    reject("mode", "hybrid not available in this build")
  }
  let order = sorted_source_indices(files)
  let sorted = order.map(fn(i) { files[i] })
  let pieces = sha1_pieces(sorted, options.piece_length, (i, offset, n) => {
    read(order[i], offset, n)
  })
  let fields = [
    ("name", bn_text(options.name)),
    ("piece length", bn_int(options.piece_length.to_int64())),
    ("pieces", bn(Blob(pieces))),
  ]
  if options.single_file {
    fields.push(("length", bn_int(sorted[0].length)))
  } else {
    fields.push(("files", bn(Sequence(sorted.map(v1_file_node)))))
  }
  if options.private_torrent {
    fields.push(("private", bn_int(1L)))
  }
  encode_bencode(bn_dict(top_fields(bn_dict(fields), options)))
}

///|
priv struct ParsedTorrent {
  summary : TorrentInfo
  pieces : Bytes
  roots : Array[V2FileHash]
}

///|
fn parse_torrent(data : Bytes) -> ParsedTorrent raise CrateError {
  let top = decode_bencode(data)
  let info = require_key(top, "info")
  if lookup(info, "meta version") is Some(_) {
    return parse_v2_torrent(data, top, info)
  }
  let name = as_text(require_key(info, "name"))
  let piece = as_int(require_key(info, "piece length"))
  if piece < 16384L || piece > 16777216L {
    reject("piece_length", "invalid piece length")
  }
  check_piece_length(piece.to_int())
  let files : Array[SourceFile] = []
  let single = lookup(info, "length") is Some(_)
  if single {
    if lookup(info, "files") is Some(_) {
      reject("metainfo", "length and files are mutually exclusive")
    }
    files.push({ path: [name], length: as_int(require_key(info, "length")), })
  } else {
    for f in as_list(require_key(info, "files")) {
      if lookup(f, "attr") is Some(_) {
        reject("metainfo", "file attributes not supported in v1-only input")
      }
      let path : Array[String] = []
      for component in as_list(require_key(f, "path")) {
        path.push(as_text(component))
      }
      files.push({ path, length: as_int(require_key(f, "length")), })
    }
  }
  let private_flag = match lookup(info, "private") {
    None => false
    Some(n) => {
      let n = as_int(n)
      if n != 0L && n != 1L {
        reject("metainfo", "private must be 0 or 1")
      }
      n == 1L
    }
  }
  let trackers = read_trackers(top)
  let web_seeds = read_web_seeds(top)
  let comment = match lookup(top, "comment") {
    Some(c) => as_text(c)
    None => ""
  }
  let options : CreateOptions = {
    name,
    mode: V1,
    piece_length: piece.to_int(),
    single_file: single,
    private_torrent: private_flag,
    trackers,
    web_seeds,
    comment,
  }
  validate_options(files, options)
  let total = validate_sources(files)
  let pieces = as_blob(require_key(info, "pieces"))
  if pieces.length().to_int64() != (total + piece - 1L) / piece * 20L {
    reject("pieces", "piece hash count does not match payload length")
  }
  let hash = @crypto.bytes_to_hex_string(
    @crypto.sha1(data[info.start:info.end]),
  )
  {
    summary: {
      name,
      mode: V1,
      piece_length: piece.to_int(),
      files,
      single_file: single,
      private_torrent: private_flag,
      trackers,
      web_seeds,
      comment,
      info_hash_v1: Some(hash),
      info_hash_v2: None,
    },
    pieces,
    roots: [],
  }
}

///|
pub fn inspect_torrent(data : Bytes) -> TorrentInfo raise CrateError {
  parse_torrent(data).summary
}

///|
/// Expose expected v1 piece hashes for verification and integration with other clients.
pub fn expected_v1_pieces(data : Bytes) -> Bytes raise CrateError {
  parse_torrent(data).pieces
}

///|
pub fn expected_v2_files(data : Bytes) -> Array[V2FileHash] raise CrateError {
  parse_torrent(data).roots
}
