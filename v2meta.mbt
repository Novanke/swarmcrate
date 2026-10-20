///|
fn insert_file_tree(
  tree : BNode,
  path : Array[String],
  depth : Int32,
  length : Int64,
  root : Bytes,
) -> Unit raise CrateError {
  let pairs = dict_pairs(tree)
  if depth == path.length() {
    if !pairs.is_empty() {
      reject("path", "file-tree collision")
    }
    let leaf = [("length", bn_int(length))]
    if length > 0L {
      leaf.push(("pieces root", bn(Blob(root))))
    }
    pairs.push((b"", bn_dict(leaf)))
    return
  }
  let key = @utf8.encode(path[depth])
  for (k, child) in pairs {
    if k == key {
      insert_file_tree(child, path, depth + 1, length, root)
      return
    }
  }
  let child = bn(Dictionary([]))
  insert_file_tree(child, path, depth + 1, length, root)
  pairs.push((key, child))
}

///|
fn v2_components(
  files : Array[SourceFile],
  options : CreateOptions,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
) -> (BNode, BNode) raise CrateError {
  let tree = bn(Dictionary([]))
  let layers : Array[(Bytes, BNode)] = []
  let seen : Map[String, Bool] = Map([])
  for index in sorted_source_indices(files) {
    let file = files[index]
    let hashes = hash_v2_file(file.length, options.piece_length, (offset, n) => {
      read(index, offset, n)
    })
    insert_file_tree(tree, file.path, 0, file.length, hashes.root)
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
  if lookup(info, "pieces") is Some(_) {
    reject("mode", "hybrid not available in this build")
  }
  let name = as_text(require_key(info, "name"))
  let piece = as_int(require_key(info, "piece length"))
  if piece < 16384L || piece > 16777216L {
    reject("piece_length", "invalid piece length")
  }
  check_piece_length(piece.to_int())
  let files : Array[SourceFile] = []
  let roots : Array[Bytes] = []
  walk_file_tree(require_key(info, "file tree"), [], files, roots)
  let single = files.length() == 1 && files[0].path == [name]
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
      let mut found = false
      for (key, value) in layers {
        if key == roots[i] {
          found = true
          layer = as_blob(value)
          used.set(@crypto.bytes_to_hex_string(key), true)
        }
      }
      if !found {
        reject("piece_layers", "missing file piece layer")
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
  {
    summary: {
      name,
      mode: V2,
      piece_length: piece.to_int(),
      files,
      single_file: single,
      private_torrent: private_flag,
      trackers: options.trackers,
      web_seeds: options.web_seeds,
      comment: options.comment,
      info_hash_v1: None,
      info_hash_v2: Some(
        @crypto.bytes_to_hex_string(@crypto.sha256(data[info.start:info.end])),
      ),
    },
    pieces: b"",
    roots: hashes,
  }
}
