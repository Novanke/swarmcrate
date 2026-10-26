///|
pub fn mode_name(mode : TorrentMode) -> String {
  match mode {
    V1 => "v1"
    V2 => "v2"
    Hybrid => "hybrid"
  }
}

///|
fn optional_text(value : String?) -> Json {
  match value {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
fn j_object(pairs : Array[(String, Json)]) -> Json {
  Json::object(Map(pairs))
}

///|
/// Sizes are decimal strings so consumers never round 64-bit file offsets.
pub fn info_json(info : TorrentInfo) -> Json {
  let mut total = 0L
  for file in info.files {
    total += file.length
  }
  j_object([
    ("schema", Json::string("swarmcrate.info.v1")),
    ("name", Json::string(info.name)),
    ("mode", Json::string(mode_name(info.mode))),
    ("piece_length", Json::number(info.piece_length.to_double())),
    ("total_bytes", Json::string(total.to_string())),
    ("single_file", Json::boolean(info.single_file)),
    ("private", Json::boolean(info.private_torrent)),
    ("info_hash_v1", optional_text(info.info_hash_v1)),
    ("info_hash_v2", optional_text(info.info_hash_v2)),
    ("comment", Json::string(info.comment)),
    (
      "trackers",
      Json::array(info.trackers.map(fn(t) { Json::array(t.map(Json::string)) })),
    ),
    ("web_seeds", Json::array(info.web_seeds.map(Json::string))),
    (
      "files",
      Json::array(
        info.files.map(fn(f) {
          j_object([
            ("path", Json::array(f.path.map(Json::string))),
            ("length", Json::string(f.length.to_string())),
          ])
        }),
      ),
    ),
  ])
}

///|
pub fn verification_json(report : VerificationReport) -> Json {
  j_object([
    ("schema", Json::string("swarmcrate.verify.v2")),
    ("ok", Json::boolean(report.ok)),
    ("complete", Json::boolean(report.scope.complete)),
    (
      "selected_files",
      Json::array(
        report.scope.selected_files.map(fn(i) { Json::number(i.to_double()) }),
      ),
    ),
    (
      "required_files",
      Json::array(
        report.scope.required_files.map(fn(i) { Json::number(i.to_double()) }),
      ),
    ),
    ("checked_pieces", Json::number(report.checked_pieces.to_double())),
    ("skipped_pieces", Json::number(report.skipped_pieces.to_double())),
    ("failed_pieces", Json::number(report.failed_pieces.to_double())),
    ("unreadable_pieces", Json::number(report.unreadable_pieces.to_double())),
    ("details_truncated", Json::boolean(report.details_truncated)),
    (
      "file_issues",
      Json::array(
        report.file_issues.map(fn(f) {
          j_object([
            ("file", Json::number(f.file.to_double())),
            ("path", Json::string(f.path)),
            ("expected", Json::string(f.expected.to_string())),
            (
              "actual",
              match f.actual {
                Some(n) => Json::string(n.to_string())
                None => Json::null()
              },
            ),
            ("reason", Json::string(f.reason)),
          ])
        }),
      ),
    ),
    (
      "failures",
      Json::array(
        report.failures.map(fn(p) {
          j_object([
            ("scheme", Json::string(p.scheme)),
            ("piece", Json::number(p.piece.to_double())),
            ("reason", Json::string(p.reason)),
            (
              "spans",
              Json::array(
                p.spans.map(fn(s) {
                  j_object([
                    ("file", Json::number(s.file.to_double())),
                    ("offset", Json::string(s.offset.to_string())),
                    ("length", Json::number(s.length.to_double())),
                  ])
                }),
              ),
            ),
          ])
        }),
      ),
    ),
  ])
}

///|
fn html_escape(text : String) -> String {
  let mut result = text
  for
    (from, to) in [
      ("&", "&amp;"),
      ("<", "&lt;"),
      (">", "&gt;"),
      ("\"", "&quot;"),
      ("'", "&#39;"),
    ] {
    result = result.split(from).map(fn(p) { p.to_owned() }).to_array().join(to)
  }
  result
}

///|
/// A self-contained, script-free report that can be opened offline or attached to a release.
pub fn verification_html(
  info : TorrentInfo,
  report : VerificationReport,
) -> String {
  let rows : Array[String] = []
  for file in report.file_issues {
    let actual = match file.actual {
      Some(n) => n.to_string()
      None => "missing"
    }
    rows.push(
      "<tr><td>" +
      html_escape(file.path) +
      "</td><td>" +
      html_escape(file.reason) +
      "</td><td>" +
      file.expected.to_string() +
      "</td><td>" +
      actual +
      "</td></tr>",
    )
  }
  let pieces : Array[String] = []
  for failure in report.failures {
    let locations = failure.spans.map(fn(s) {
      html_escape(info.files[s.file].path.join("/")) +
      " @ " +
      s.offset.to_string() +
      " + " +
      s.length.to_string()
    })
    pieces.push(
      "<tr><td>" +
      html_escape(failure.scheme) +
      "</td><td>" +
      failure.piece.to_string() +
      "</td><td>" +
      html_escape(failure.reason) +
      "</td><td>" +
      locations.join("<br>") +
      "</td></tr>",
    )
  }
  let status = if !report.ok {
    "FAIL"
  } else if report.scope.complete {
    "PASS"
  } else {
    "PARTIAL PASS"
  }
  let selected = report.scope.selected_files
    .map(fn(i) { html_escape(info.files[i].path.join("/")) })
    .join("<br>")
  let required = report.scope.required_files
    .map(fn(i) { html_escape(info.files[i].path.join("/")) })
    .join("<br>")
  "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>SwarmCrate verification</title>" +
  "<style>body{font:16px system-ui;max-width:1100px;margin:3rem auto;padding:0 1rem;color:#172533;background:#fafbfc}table{border-collapse:collapse;width:100%;margin:1rem 0}td,th{border:1px solid #ccd3db;padding:.6rem;text-align:left;overflow-wrap:anywhere}h1{color:#164e63}code{overflow-wrap:anywhere}small{color:#52616d}</style>" +
  "<h1>" +
  status +
  " · " +
  html_escape(info.name) +
  "</h1><p>Mode: " +
  mode_name(info.mode) +
  " · Checked: " +
  report.checked_pieces.to_string() +
  " · Failed: " +
  report.failed_pieces.to_string() +
  " · Unreadable: " +
  report.unreadable_pieces.to_string() +
  " · Skipped: " +
  report.skipped_pieces.to_string() +
  "</p>" +
  "<p>Scope: " +
  (if report.scope.complete {
    "all files"
  } else {
    "selected files only; other files are not certified"
  }) +
  "</p><details><summary>Selected files</summary>" +
  selected +
  "</details><details><summary>Required files (includes shared v1 boundaries)</summary>" +
  required +
  "</details>" +
  "<p>SHA-1: <code>" +
  html_escape(info.info_hash_v1.unwrap_or("—")) +
  "</code><br>SHA-256: <code>" +
  html_escape(info.info_hash_v2.unwrap_or("—")) +
  "</code></p>" +
  "<h2>File issues</h2><table><tr><th>File</th><th>Reason</th><th>Expected bytes</th><th>Actual bytes</th></tr>" +
  rows.join("") +
  "</table>" +
  "<h2>Piece failures</h2><table><tr><th>Scheme</th><th>Index (zero-based)</th><th>Reason</th><th>File @ offset + length</th></tr>" +
  pieces.join("") +
  "</table>" +
  "<small>SwarmCrate 0.5.0 · Hash checks show consistency with this metainfo, not publisher authenticity. Detail list truncated: " +
  report.details_truncated.to_string() +
  ".</small></html>"
}
