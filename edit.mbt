///|
/// Replace distribution endpoints without changing the exact encoded info dictionary.
/// Unknown top-level extension fields are retained. Private torrents must retain a tracker.
pub fn edit_distribution(
  data : Bytes,
  trackers : Array[Array[String]],
  web_seeds : Array[String],
) -> Bytes raise CrateError {
  let summary = inspect_torrent(data)
  validate_options(summary.files, {
    name: summary.name,
    mode: summary.mode,
    piece_length: summary.piece_length,
    single_file: summary.single_file,
    private_torrent: summary.private_torrent,
    trackers,
    web_seeds,
    comment: summary.comment,
  })
  let top = decode_bencode(data)
  let info = require_key(top, "info")
  let pairs = dict_pairs(top).filter(fn(p) {
    p.0 != b"announce" && p.0 != b"announce-list" && p.0 != b"url-list"
  })
  if !trackers.is_empty() {
    pairs.push((b"announce", bn_text(trackers[0][0])))
    pairs.push(
      (
        b"announce-list",
        bn(Sequence(trackers.map(fn(t) { bn(Sequence(t.map(bn_text))) }))),
      ),
    )
  }
  if !web_seeds.is_empty() {
    pairs.push((b"url-list", bn(Sequence(web_seeds.map(bn_text)))))
  }
  pairs.sort_by(fn(a, b) { byte_compare(a.0, b.0) })
  let out : Array[Byte] = [100]
  for (key, value) in pairs {
    append_bytes(out, encode_bencode(bn(Blob(key))))
    if key == b"info" {
      append_bytes(out, data[info.start:info.end].to_owned())
    } else {
      append_bytes(out, encode_bencode(value))
    }
  }
  out.push(101)
  if out.length() > 16777216 {
    reject("limit", "edited metainfo exceeds 16 MiB")
  }
  let result = Bytes::from_array(out)
  let after = inspect_torrent(result)
  if summary.info_hash_v1 != after.info_hash_v1 ||
    summary.info_hash_v2 != after.info_hash_v2 {
    reject("internal", "distribution edit changed content identity")
  }
  result
}
