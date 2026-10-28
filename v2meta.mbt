///|
fn insert_file_tree(
  tree : BNode,
  directories : Map[String, BNode],
  path : Array[String],
  length : Int64,
  root : Bytes,
) -> Unit raise CrateError {
  // Source validation already rules out file/directory and duplicate paths.
  // Index directories by their full path instead of scanning every sibling.
  let mut parent = tree
  let mut prefix = ""
  for depth in 0..<(path.length() - 1) {
    prefix = if depth == 0 { path[depth] } else { prefix + "/" + path[depth] }
    let child = match directories.get(prefix) {
      Some(node) => node
      None => {
        let node = bn(Dictionary([]))
        dict_pairs(parent).push((@utf8.encode(path[depth]), node))
        directories.set(prefix, node)
        node
      }
    }
    parent = child
  }
  let properties = [("length", bn_int(length))]
  if length > 0L {
    properties.push(("pieces root", bn(Blob(root))))
  }
  let leaf = bn(Dictionary([(b"", bn_dict(properties))]))
  dict_pairs(parent).push((@utf8.encode(path[path.length() - 1]), leaf))
}

///|
fn v2_components(
  files : Array[SourceFile],
  options : CreateOptions,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
) -> (BNode, BNode) raise CrateError {
  let tree = bn(Dictionary([]))
  let directories : Map[String, BNode] = Map([])
  let layers : Array[(Bytes, BNode)] = []
  let seen : Map[String, Bool] = Map([])
  let mut count = 0L
  for file in files {
    count += (file.length + options.piece_length.to_int64() - 1L) /
      options.piece_length.to_int64()
  }
  if count > 400000L {
    reject("limit", "too many file pieces")
  }
  for index in sorted_source_indices(files) {
    let file = files[index]
    let hashes = hash_v2_file(file.length, options.piece_length, (offset, n) => {
      read(index, offset, n)
    })
    insert_file_tree(tree, directories, file.path, file.length, hashes.root)
    if !hashes.piece_layer.is_empty() {
      let key = @crypto.bytes_to_hex_string(hashes.root)
      if !seen.contains(key) {
        seen.set(key, true)
        layers.push((hashes.root, bn(Blob(hashes.piece_layer))))
      }
    }
  }
  (tree, bn(Dictionary(layers)))
}

///|
fn create_v2_torrent(
  files : Array[SourceFile],
  options : CreateOptions,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  control : CreateControl?,
) -> Bytes raise CrateError {
  let (tree, layers) = v2_components(files, options, read)
  let fields = [
    ("name", bn_text(options.name)),
    ("piece length", bn_int(options.piece_length.to_int64())),
    ("meta version", bn_int(2L)),
    ("file tree", tree),
  ]
  if options.private_torrent {
    fields.push(("private", bn_int(1L)))
  }
  let top = top_fields(bn_dict(fields), options)
  top.push(("piece layers", layers))
  emit_creation_progress(control, "before_encode")
  encode_bencode(bn_dict(top))
}

///|
fn walk_file_tree(
  tree : BNode,
  path : Array[String],
  files : Array[SourceFile],
  roots : Array[Bytes],
) -> Unit raise CrateError {
  if path.length() > 32 || files.length() > 65536 {
    reject("limit", "file tree exceeds limits")
  }
  let pairs = dict_pairs(tree)
  if pairs.is_empty() {
    reject("file_tree", "empty directory")
  }
  for (key, child) in pairs {
    if key.is_empty() {
      if path.is_empty() || pairs.length() != 1 {
        reject("file_tree", "invalid file leaf")
      }
      if lookup(child, "attr") is Some(_) {
        reject("file_tree", "symlinks and attributes are unsupported")
      }
      let length = as_int(require_key(child, "length"))
      let root = match lookup(child, "pieces root") {
        Some(value) => as_blob(value)
        None => b""
      }
      if (length > 0L && root.length() != 32) ||
        (length == 0L && !root.is_empty()) {
        reject("file_tree", "invalid pieces root for file length")
      }
      files.push({ path: path.copy(), length, })
      roots.push(root)
    } else {
      let name = as_text(bn(Blob(key)))
      check_component(name)
      let child_path = path.copy()
      child_path.push(name)
      walk_file_tree(child, child_path, files, roots)
    }
  }
}

///|
fn parse_v2_torrent(
  data : Bytes,
  top : BNode,
  info : BNode,
) -> ParsedTorrent raise CrateError {
  if as_int(require_key(info, "meta version")) != 2L {
    reject("mode", "unsupported meta version")
  }
  let hybrid = lookup(info, "pieces") is Some(_)
  let name = as_text(require_key(info, "name"))
  let piece = as_int(require_key(info, "piece length"))
  if piece < 16384L || piece > 16777216L {
    reject("piece_length", "invalid piece length")
  }
  check_piece_length(piece.to_int())
  let files : Array[SourceFile] = []
  let roots : Array[Bytes] = []
  walk_file_tree(require_key(info, "file tree"), [], files, roots)
  let single = if hybrid {
    lookup(info, "length") is Some(_)
  } else {
    files.length() == 1 && files[0].path == [name]
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
  let options : CreateOptions = {
    name,
    mode: V2,
    piece_length: piece.to_int(),
    single_file: single,
    private_torrent: private_flag,
    trackers: read_trackers(top),
    web_seeds: read_web_seeds(top),
    comment: match lookup(top, "comment") {
      Some(c) => as_text(c)
      None => ""
    },
  }
  validate_options(files, options)
  let layers = dict_pairs(require_key(top, "piece layers"))
  let layer_map : Map[String, Bytes] = Map([])
  for (key, value) in layers {
    if key.length() != 32 {
      reject("piece_layers", "piece layer key must be 32 bytes")
    }
    layer_map.set(@crypto.bytes_to_hex_string(key), as_blob(value))
  }
  let used : Map[String, Bool] = Map([])
  let hashes : Array[V2FileHash] = []
  let mut count = 0L
  for i, file in files {
    count += (file.length + piece - 1L) / piece
    if count > 400000L {
      reject("limit", "too many file pieces")
    }
    let mut layer = b""
    if file.length > piece {
      let key = @crypto.bytes_to_hex_string(roots[i])
      match layer_map.get(key) {
        Some(value) => {
          layer = value
          used.set(key, true)
        }
        None => reject("piece_layers", "missing file piece layer")
      }
      validate_piece_layer(roots[i], file.length, piece.to_int(), layer)
    }
    hashes.push({ root: roots[i], piece_layer: layer, })
  }
  for (key, _) in layers {
    if !used.contains(@crypto.bytes_to_hex_string(key)) {
      reject("piece_layers", "unreferenced piece layer")
    }
  }
  let (pieces, entries) = if hybrid {
    validate_hybrid(info, files, single, piece.to_int())
  } else {
    if lookup(info, "length") is Some(_) || lookup(info, "files") is Some(_) {
      reject("metainfo", "v1 layout without pieces")
    }
    (
      b"",
      files.mapi(fn(i, f) {
        DataEntry::{ source: i, length: f.length, padding: false, }
      }),
    )
  }
  {
    summary: {
      name,
      mode: if hybrid {
        Hybrid
      } else {
        V2
      },
      piece_length: piece.to_int(),
      files,
      single_file: single,
      private_torrent: private_flag,
      trackers: options.trackers,
      web_seeds: options.web_seeds,
      comment: options.comment,
      info_hash_v1: if hybrid {
        Some(
          @crypto.bytes_to_hex_string(@crypto.sha1(data[info.start:info.end])),
        )
      } else {
        None
      },
      info_hash_v2: Some(
        @crypto.bytes_to_hex_string(@crypto.sha256(data[info.start:info.end])),
      ),
    },
    pieces,
    entries,
    roots: hashes,
  }
}
