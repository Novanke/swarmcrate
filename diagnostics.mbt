///|
priv struct DiagnosticRange {
  offset : Int64
  length : Int64
}

///|
priv struct FileDiagnostic {
  file : Int32
  path : Array[String]
  expected : Int64
  actual : Int64?
  selected : Bool
  issue : String?
  hash_mismatch : Array[DiagnosticRange]
  unreadable : Array[DiagnosticRange]
  missing : Array[DiagnosticRange]
  extra : Array[DiagnosticRange]
  attention : Array[DiagnosticRange]
}

///|
// Union physical byte intervals, including adjacent intervals. Never sum two hash schemes.
fn merge_diagnostic_ranges(
  ranges : Array[DiagnosticRange],
) -> Array[DiagnosticRange] {
  let sorted = ranges.copy()
  sorted.sort_by(fn(a, b) { a.offset.compare(b.offset) })
  let merged : Array[DiagnosticRange] = []
  for range in sorted {
    if range.length == 0L {
      continue
    }
    if merged.is_empty() {
      merged.push(range)
    } else {
      let last = merged[merged.length() - 1]
      let end = range.offset + range.length
      let previous_end = last.offset + last.length
      if range.offset <= previous_end {
        if end > previous_end {
          merged[merged.length() - 1] = {
            offset: last.offset,
            length: end - last.offset,
          }
        }
      } else {
        merged.push(range)
      }
    }
  }
  merged
}

///|
// Called with the same parsed subject and report. File issues are exhaustive even
// when stored piece failures are truncated. Unreadable spans are affected ranges,
// not proof that this particular file caused the read error in a shared v1 piece.
fn diagnostic_files(
  info : TorrentInfo,
  report : VerificationReport,
) -> Array[FileDiagnostic] {
  let hashes : Array[Array[DiagnosticRange]] = info.files.map(fn(_) { [] })
  let unreadable : Array[Array[DiagnosticRange]] = info.files.map(fn(_) { [] })
  for failure in report.failures {
    for span in failure.spans {
      let range : DiagnosticRange = {
        offset: span.offset,
        length: span.length.to_int64(),
      }
      if failure.reason == "hash_mismatch" {
        hashes[span.file].push(range)
      } else {
        unreadable[span.file].push(range)
      }
    }
  }
  let selected = Array::make(info.files.length(), false)
  for i in report.scope.selected_files {
    selected[i] = true
  }
  let issues : Map[Int32, FileIssue] = Map([])
  for issue in report.file_issues {
    issues[issue.file] = issue
  }
  let result : Array[FileDiagnostic] = []
  for i in report.scope.required_files {
    let file = info.files[i]
    let issue = issues.get(i)
    let actual = match issue {
      Some(issue) => issue.actual
      None => Some(file.length)
    }
    let missing : Array[DiagnosticRange] = []
    let extra : Array[DiagnosticRange] = []
    match actual {
      None =>
        if file.length > 0L {
          missing.push({ offset: 0L, length: file.length, })
        }
      Some(size) =>
        if size >= 0L && size < file.length {
          missing.push({ offset: size, length: file.length - size, })
        } else if size > file.length {
          extra.push({ offset: file.length, length: size - file.length, })
        }
    }
    let hash_ranges = merge_diagnostic_ranges(hashes[i])
    let unreadable_ranges = merge_diagnostic_ranges(unreadable[i])
    let attention = hash_ranges.copy()
    for range in unreadable_ranges {
      attention.push(range)
    }
    for range in missing {
      attention.push(range)
    }
    result.push({
      file: i,
      path: file.path,
      expected: file.length,
      actual,
      selected: selected[i],
      issue: issue.map(fn(f) { f.reason }),
      hash_mismatch: hash_ranges,
      unreadable: unreadable_ranges,
      missing,
      extra,
      attention: merge_diagnostic_ranges(attention),
    })
  }
  result
}

///|
fn diagnostic_range_bytes(ranges : Array[DiagnosticRange]) -> Int64 {
  let mut total = 0L
  for range in ranges {
    total += range.length
  }
  total
}

///|
fn diagnostic_ranges_json(ranges : Array[DiagnosticRange]) -> Json {
  Json::array(
    ranges.map(fn(range) {
      j_object([
        ("offset", Json::string(range.offset.to_string())),
        ("length", Json::string(range.length.to_string())),
      ])
    }),
  )
}

///|
fn file_has_diagnostic(file : FileDiagnostic) -> Bool {
  file.issue is Some(_) || !file.attention.is_empty()
}

///|
fn file_diagnostics_json(
  info : TorrentInfo,
  report : VerificationReport,
  metainfo_sha256 : String,
  metainfo_bytes : String,
) -> Json {
  let files = diagnostic_files(info, report)
  let mut affected = 0
  for file in files {
    if file_has_diagnostic(file) {
      affected += 1
    }
  }
  j_object([
    ("schema", Json::string("swarmcrate.diagnostics.v1")),
    ("metainfo_sha256", Json::string(metainfo_sha256)),
    ("metainfo_bytes", Json::string(metainfo_bytes)),
    ("info_hash_v1", optional_text(info.info_hash_v1)),
    ("info_hash_v2", optional_text(info.info_hash_v2)),
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
    ("ranges_complete", Json::boolean(!report.details_truncated)),
    (
      "omitted_failure_checks",
      Json::number(
        (report.failed_pieces - report.failures.length()).to_double(),
      ),
    ),
    ("files_with_recorded_issues", Json::number(affected.to_double())),
    (
      "unreadable_semantics",
      Json::string("affected_piece_ranges_not_exact_io_failure_locations"),
    ),
    (
      "range_semantics",
      Json::string("candidate_piece_ranges_not_exact_corrupt_bytes"),
    ),
    (
      "files",
      Json::array(
        files.map(fn(file) {
          j_object([
            ("file", Json::number(file.file.to_double())),
            ("path", Json::array(file.path.map(Json::string))),
            ("expected_bytes", Json::string(file.expected.to_string())),
            (
              "actual_bytes",
              optional_text(file.actual.map(fn(n) { n.to_string() })),
            ),
            ("selected", Json::boolean(file.selected)),
            ("size_issue", optional_text(file.issue)),
            ("has_recorded_issue", Json::boolean(file_has_diagnostic(file))),
            ("ranges_complete", Json::boolean(!report.details_truncated)),
            ("hash_mismatch_ranges", diagnostic_ranges_json(file.hash_mismatch)),
            (
              "hash_mismatch_bytes",
              Json::string(
                diagnostic_range_bytes(file.hash_mismatch).to_string(),
              ),
            ),
            ("unreadable_ranges", diagnostic_ranges_json(file.unreadable)),
            (
              "unreadable_bytes",
              Json::string(diagnostic_range_bytes(file.unreadable).to_string()),
            ),
            ("missing_ranges", diagnostic_ranges_json(file.missing)),
            (
              "missing_bytes",
              Json::string(diagnostic_range_bytes(file.missing).to_string()),
            ),
            ("extra_ranges", diagnostic_ranges_json(file.extra)),
            (
              "extra_bytes",
              Json::string(diagnostic_range_bytes(file.extra).to_string()),
            ),
            ("attention_ranges", diagnostic_ranges_json(file.attention)),
            (
              "attention_bytes",
              Json::string(diagnostic_range_bytes(file.attention).to_string()),
            ),
          ])
        }),
      ),
    ),
  ])
}

///|
fn diagnostic_ranges_html(ranges : Array[DiagnosticRange]) -> String {
  ranges
  .map(fn(range) { range.offset.to_string() + " + " + range.length.to_string() })
  .join("<br>")
}

///|
fn file_diagnostics_html(
  info : TorrentInfo,
  report : VerificationReport,
) -> String {
  let rows : Array[String] = []
  for file in diagnostic_files(info, report) {
    if file_has_diagnostic(file) {
      rows.push(
        "<tr><td>" +
        html_escape(file.path.join("/")) +
        "</td><td>" +
        (if file.selected { "selected" } else { "boundary dependency only" }) +
        "</td><td>" +
        html_escape(file.issue.unwrap_or("—")) +
        "</td><td>" +
        diagnostic_ranges_html(file.hash_mismatch) +
        "</td><td>" +
        diagnostic_ranges_html(file.unreadable) +
        "</td><td>" +
        diagnostic_ranges_html(file.missing) +
        "</td><td>" +
        diagnostic_ranges_html(file.extra) +
        "</td></tr>",
      )
    }
  }
  "<h2>Per-file attention ranges</h2><p>Offsets and lengths are bytes. Failed-piece ranges are candidates, not exact corrupt bytes; a shared v1 piece cannot identify which file caused a read error.</p>" +
  (if report.details_truncated {
    "<p><strong>INCOMPLETE: failure details were truncated. Additional affected files and ranges may be absent; an empty row set does not mean all files passed.</strong></p>"
  } else {
    "<p>Recorded ranges are complete for the selected scope, including required boundary dependencies.</p>"
  }) +
  "<table><tr><th>File</th><th>Scope</th><th>Size issue</th><th>Hash mismatch @ offset + length</th><th>Unreadable piece @ offset + length</th><th>Missing @ offset + length</th><th>Extra @ offset + length</th></tr>" +
  rows.join("") +
  "</table>"
}
