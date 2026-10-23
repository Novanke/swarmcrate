///|
test "reports escape untrusted paths and serialize sizes losslessly" {
  let info : TorrentInfo = {
    name: "<script>&'",
    mode: V1,
    piece_length: 16384,
    files: [{ path: ["file"], length: 9007199254740991L, }],
    single_file: true,
    private_torrent: false,
    trackers: [],
    web_seeds: [],
    comment: "",
    info_hash_v1: None,
    info_hash_v2: None,
  }
  let report : VerificationReport = {
    ok: false,
    scope: { complete: true, selected_files: [0], required_files: [0], },
    checked_pieces: 0,
    skipped_pieces: 0,
    failed_pieces: 0,
    unreadable_pieces: 0,
    file_issues: [
      {
        file: 0,
        path: "<script>&'",
        expected: 9007199254740991L,
        actual: None,
        reason: "missing",
      },
    ],
    failures: [],
    details_truncated: false,
  }
  assert_true(info_json(info).stringify().contains("9007199254740991"))
  assert_true(verification_json(report).stringify().contains("missing"))
  let html = verification_html(info, report)
  assert_true(!html.contains("<script>"))
  assert_true(html.contains("&lt;script&gt;&amp;&#39;"))
  let partial : VerificationReport = {
    ..report,
    ok: true,
    scope: { complete: false, selected_files: [0], required_files: [0], },
    skipped_pieces: 2,
    file_issues: [],
  }
  assert_true(verification_html(info, partial).contains("PARTIAL PASS"))
  assert_true(
    verification_html(info, partial).contains("other files are not certified"),
  )
  let json = verification_json(partial).stringify()
  assert_true(json.contains("\"complete\":false"))
  assert_true(json.contains("\"skipped_pieces\":2"))
}
