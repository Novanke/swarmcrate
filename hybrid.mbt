///|
fn create_hybrid_torrent(
  files : Array[SourceFile],
  options : CreateOptions,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
) -> Bytes raise CrateError {
  let order = sorted_source_indices(files)
  let entries : Array[DataEntry] = []
  let v1_files : Array[BNode] = []
  for pos, index in order {
    let file = files[index]
    entries.push({ source: index, length: file.length, padding: false, })
    v1_files.push(v1_file_node(file))
    let remainder = file.length % options.piece_length.to_int64()
    if pos + 1 < order.length() && remainder != 0L {
      let size = options.piece_length.to_int64() - remainder
      entries.push({ source: -1, length: size, padding: true, })
      v1_files.push(
        bn_dict([
          ("attr", bn_text("p")),
          ("length", bn_int(size)),
          ("path", bn(Sequence([bn_text(".pad"), bn_text("\{size}-\{pos}")]))),
        ]),
      )
    }
  }
  let pieces = v1_hash_entries(entries, options.piece_length, read)
  let (tree, layers) = v2_components(files, options, read)
  let fields = [
    ("name", bn_text(options.name)),
    ("piece length", bn_int(options.piece_length.to_int64())),
    ("pieces", bn(Blob(pieces))),
    ("meta version", bn_int(2L)),
    ("file tree", tree),
  ]
  if options.single_file {
    fields.push(("length", bn_int(files[0].length)))
  } else {
    fields.push(("files", bn(Sequence(v1_files))))
  }
  if options.private_torrent {
    fields.push(("private", bn_int(1L)))
  }
  let top = top_fields(bn_dict(fields), options)
  top.push(("piece layers", layers))
  encode_bencode(bn_dict(top))
}

///|
fn validate_hybrid(
  info : BNode,
  files : Array[SourceFile],
  single : Bool,
  piece : Int32,
) -> (Bytes, Array[DataEntry]) raise CrateError {
  let entries : Array[DataEntry] = []
  let mut total = 0L
  if single {
    if lookup(info, "files") is Some(_) ||
      files.length() != 1 ||
      files[0].path != [as_text(require_key(info, "name"))] ||
      as_int(require_key(info, "length")) != files[0].length {
      reject("hybrid", "single-file layouts disagree")
    }
    total = files[0].length
    entries.push({ source: 0, length: total, padding: false, })
  } else {
    let mut index = 0
    let mut previous_padding = false
    for f in as_list(require_key(info, "files")) {
      let length = as_int(require_key(f, "length"))
      if length < 0L || length > 9007199254740991L - total {
        reject("limit", "invalid hybrid storage length")
      }
      let path : Array[String] = []
      for p in as_list(require_key(f, "path")) {
        path.push(as_text(p))
      }
      let attr = match lookup(f, "attr") {
        Some(a) => as_text(a)
        None => ""
      }
      if attr == "p" {
        if index == 0 ||
          previous_padding ||
          length == 0L ||
          length >= piece.to_int64() ||
          total % piece.to_int64() + length != piece.to_int64() ||
          path.length() != 2 ||
          path[0] != ".pad" {
          reject("hybrid", "invalid virtual padding alignment")
        }
        check_component(path[1])
        entries.push({ source: -1, length, padding: true, })
        previous_padding = true
      } else {
        if attr != "" ||
          index >= files.length() ||
          path != files[index].path ||
          length != files[index].length ||
          (length > 0L && total % piece.to_int64() != 0L) {
          reject(
            "hybrid", "v1/v2 paths order lengths or piece alignment disagree",
          )
        }
        entries.push({ source: index, length, padding: false, })
        index += 1
        previous_padding = false
      }
      total += length
    }
    if index != files.length() {
      reject("hybrid", "missing v1 files")
    }
  }
  let pieces = as_blob(require_key(info, "pieces"))
  if (total + piece.to_int64() - 1L) / piece.to_int64() > 400000L ||
    pieces.length().to_int64() !=
    (total + piece.to_int64() - 1L) / piece.to_int64() * 20L {
    reject("hybrid", "v1 piece count does not match aligned storage")
  }
  (pieces, entries)
}
