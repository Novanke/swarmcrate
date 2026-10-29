///|
/// Immutable, unsigned snapshot of one verification and its exact metainfo input.
/// Constructed by verify_with_receipt, rather than by pairing an arbitrary report and subject.
pub struct VerificationReceipt {
  priv text : String
  priv diagnostics_text : String
}

///|
/// Verify and capture identity, real-file mapping, observed sizes and actual scope together.
/// The caller supplies stable contents and sizes; no clock, filesystem or authentication is implied.
pub fn verify_with_receipt(
  torrent : Bytes,
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  detail_limit~ : Int32 = 4096,
  selected_files~ : Array[Int32]? = None,
) -> (VerificationReport, VerificationReceipt) raise CrateError {
  verify_receipt_impl(
    torrent,
    lengths,
    read,
    None,
    detail_limit,
    selected_files,
  )
}

///|
/// Cooperatively verify with synchronous progress and cancellation checkpoints.
/// False raises CrateError("cancelled", ...); observer errors propagate unchanged.
/// Cancellation returns neither a report nor a receipt, including at finalization.
pub fn verify_with_control(
  torrent : Bytes,
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  on_progress : (VerificationProgress) -> Bool raise CrateError,
  detail_limit~ : Int32 = 4096,
  selected_files~ : Array[Int32]? = None,
) -> (VerificationReport, VerificationReceipt) raise CrateError {
  verify_receipt_impl(
    torrent,
    lengths,
    read,
    Some(on_progress),
    detail_limit,
    selected_files,
  )
}

///|
fn verify_receipt_impl(
  torrent : Bytes,
  lengths : Array[Int64?],
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  on_progress : ((VerificationProgress) -> Bool raise CrateError)?,
  detail_limit : Int32,
  selected_files : Array[Int32]?,
) -> (VerificationReport, VerificationReceipt) raise CrateError {
  let parsed = parse_torrent(torrent)
  // Capture raw identity and caller-owned sizes before invoking any read callback.
  let metainfo_sha256 = @crypto.bytes_to_hex_string(@crypto.sha256(torrent))
  let metainfo_bytes = torrent.length().to_string()
  let sizes = lengths.copy()
  let report = verify_parsed(
    parsed, sizes, read, detail_limit, selected_files, on_progress,
  )
  let info = parsed.summary
  let diagnostics = file_diagnostics_json(
    info, report, metainfo_sha256, metainfo_bytes,
  )
  let subject = j_object([
    ("metainfo_sha256", Json::string(metainfo_sha256)),
    ("metainfo_bytes", Json::string(metainfo_bytes)),
    ("info_hash_v1", optional_text(info.info_hash_v1)),
    ("info_hash_v2", optional_text(info.info_hash_v2)),
    ("name", Json::string(info.name)),
    ("mode", Json::string(mode_name(info.mode))),
    ("piece_length", Json::number(info.piece_length.to_double())),
    ("single_file", Json::boolean(info.single_file)),
    (
      "files",
      Json::array(
        info.files.mapi(fn(i, file) {
          j_object([
            ("index", Json::number(i.to_double())),
            ("path", Json::array(file.path.map(Json::string))),
            ("length", Json::string(file.length.to_string())),
          ])
        }),
      ),
    ),
  ])
  let observations = report.scope.required_files.map(fn(i) {
    j_object([
      ("file", Json::number(i.to_double())),
      ("actual_bytes", optional_text(sizes[i].map(fn(n) { n.to_string() }))),
    ])
  })
  let result = j_object([
    ("schema", Json::string("swarmcrate.receipt.v1")),
    (
      "producer",
      j_object([
        ("name", Json::string("SwarmCrate")),
        ("version", Json::string("0.11.1")),
      ]),
    ),
    ("subject", subject),
    ("observations", Json::array(observations)),
    ("verification", verification_json(report)),
    ("file_diagnostics", diagnostics),
    (
      "outcome",
      Json::string(
        if !report.ok {
          "FAIL"
        } else if report.scope.complete {
          "PASS"
        } else {
          "PARTIAL_PASS"
        },
      ),
    ),
    ("is_digital_signature", Json::boolean(false)),
    ("publisher_authenticated", Json::boolean(false)),
  ])
  // Snapshot before returning the mutable report arrays to the consumer.
  (
    report,
    VerificationReceipt::{
      text: result.stringify(indent=2),
      diagnostics_text: diagnostics.stringify(indent=2),
    },
  )
}

///|
/// Serialize the immutable receipt snapshot. This does not reverify a saved JSON document.
pub fn receipt_json_text(receipt : VerificationReceipt) -> String {
  receipt.text
}

///|
/// Export immutable per-file candidate ranges bound to the same receipt and scope.
/// Truncated failure details make the range inventory incomplete, never a complete repair plan.
pub fn receipt_diagnostics_json_text(receipt : VerificationReceipt) -> String {
  receipt.diagnostics_text
}
