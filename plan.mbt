///|
pub(all) struct TorrentPlan {
  name : String
  mode : TorrentMode
  piece_length : Int32
  single_file : Bool
  file_count : Int32
  empty_files : Int32
  real_bytes : Int64
  storage_bytes : Int64
  padding_bytes : Int64
  v1_pieces : Int32
  v2_pieces : Int32
  v1_hash_bytes : Int64
  v2_piece_layer_bytes_upper_bound : Int64
}

///|
/// Plan the creator's layout without reading or hashing payload bytes. V2
/// piece-layer size is an upper bound because identical roots are deduplicated
/// only after hashing. This is not a prediction of complete metainfo size.
pub fn plan_torrent(
  files : Array[SourceFile],
  options : CreateOptions,
) -> TorrentPlan raise CrateError {
  validate_options(files, options)
  let piece = options.piece_length.to_int64()
  let mut real = 0L
  let mut padding = 0L
  let mut empty = 0
  let mut v2_count = 0L
  let mut layer_bound = 0L
  let padded = options.mode == Hybrid && !options.single_file
  let mut last = 0
  for index, file in files {
    let length = file.length
    real += length
    if length == 0L {
      empty += 1
    }
    if options.mode != V1 {
      let count = (length + piece - 1L) / piece
      v2_count += count
      if count > 1L {
        layer_bound += count * 32L
      }
    }
    if padded {
      if path_compare(file.path, files[last].path) > 0 {
        last = index
      }
      if length % piece != 0L {
        padding += piece - length % piece
      }
    }
  }
  // Only the last file in canonical path order avoids alignment padding.
  // Find it in one pass; planning does not need to sort the complete input.
  if padded && files[last].length % piece != 0L {
    padding -= piece - files[last].length % piece
  }
  let storage = real + padding
  if storage > 9007199254740991L {
    reject("limit", "planned storage exceeds exact host offsets")
  }
  let v1_count = if options.mode == V2 {
    0L
  } else {
    (storage + piece - 1L) / piece
  }
  if v1_count > 400000L || v2_count > 400000L {
    reject(
      "limit", "planned layout exceeds the piece limit; select larger pieces",
    )
  }
  {
    name: options.name,
    mode: options.mode,
    piece_length: options.piece_length,
    single_file: options.single_file,
    file_count: files.length(),
    empty_files: empty,
    real_bytes: real,
    storage_bytes: storage,
    padding_bytes: padding,
    v1_pieces: v1_count.to_int(),
    v2_pieces: v2_count.to_int(),
    v1_hash_bytes: v1_count * 20L,
    v2_piece_layer_bytes_upper_bound: layer_bound,
  }
}

///|
pub fn plan_json(plan : TorrentPlan) -> Json {
  j_object([
    ("schema", Json::string("swarmcrate.plan.v1")),
    ("name", Json::string(plan.name)),
    ("mode", Json::string(mode_name(plan.mode))),
    ("piece_length", Json::number(plan.piece_length.to_double())),
    ("single_file", Json::boolean(plan.single_file)),
    ("file_count", Json::number(plan.file_count.to_double())),
    ("empty_files", Json::number(plan.empty_files.to_double())),
    ("real_bytes", Json::string(plan.real_bytes.to_string())),
    ("storage_bytes", Json::string(plan.storage_bytes.to_string())),
    ("padding_bytes", Json::string(plan.padding_bytes.to_string())),
    ("v1_pieces", Json::number(plan.v1_pieces.to_double())),
    ("v2_pieces", Json::number(plan.v2_pieces.to_double())),
    ("v1_hash_bytes", Json::string(plan.v1_hash_bytes.to_string())),
    (
      "v2_piece_layer_bytes_upper_bound",
      Json::string(plan.v2_piece_layer_bytes_upper_bound.to_string()),
    ),
  ])
}
