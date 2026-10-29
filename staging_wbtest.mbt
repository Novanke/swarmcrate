///|
fn owner_fixture() -> StagingOwner {
  {
    operation_id: "0123456789abcdef0123456789abcdef",
    stage_path: "/local/.swarmcrate-id-ABCDEF",
    target_path: "/local/result.json",
    directory_id: "1:2:3",
    data_id: "1:4:5",
    pid: 123,
    host: "local",
    user: "tester",
    expected_bytes: 42L,
  }
}

///|
fn evidence_fixture() -> StagingEvidence {
  {
    stage_path: owner_fixture().stage_path,
    directory_id: "1:2:3",
    data_id: "1:4:5",
    actual_bytes: 13L,
    local_host: "local",
    local_user: "tester",
    owner_state: "dead",
  }
}

///|
test "stage ownership roundtrip is bounded strict and versioned" {
  let owner = owner_fixture()
  let bytes = staging_owner_bytes(owner)
  assert_eq(parse_staging_owner(bytes).operation_id, owner.operation_id)
  assert_eq(parse_staging_owner(bytes).expected_bytes, 42L)
  for invalid in [b"{}", b"{\"schema\":\"a\",\"schema\":\"b\"}", b"\xff"] {
    assert_true(
      try {
        ignore(parse_staging_owner(invalid))
        false
      } catch {
        _ => true
      },
    )
  }
  for
    invalid in [
      { ..owner, pid: 0, },
      { ..owner, expected_bytes: -1L, },
      { ..owner, operation_id: "../arbitrary", },
      { ..owner, host: "line\nbreak", },
    ] {
    assert_true(
      try {
        ignore(staging_owner_bytes(invalid))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(!valid_staging_operation_id("0123456789ABCDEF0123456789ABCDEF"))
}

///|
test "only exact local ownership and absent PID qualify as orphan" {
  let bytes = staging_owner_bytes(owner_fixture())
  let evidence = evidence_fixture()
  assert_eq(assess_staging(bytes, Some(bytes), evidence).status, "orphan")
  assert_eq(
    assess_staging(bytes, Some(bytes), { ..evidence, owner_state: "alive", }).status,
    "active",
  )
  for
    uncertain in [
      { ..evidence, owner_state: "unknown", },
      { ..evidence, local_host: "other", },
      { ..evidence, local_user: "other", },
      { ..evidence, directory_id: "replaced", },
      { ..evidence, data_id: "replaced", },
      { ..evidence, actual_bytes: 43L, },
      { ..evidence, actual_bytes: -1L, },
      { ..evidence, stage_path: "/other", },
    ] {
    assert_eq(
      assess_staging(bytes, Some(bytes), uncertain).status,
      "unverified",
    )
  }
  assert_eq(assess_staging(bytes, None, evidence).status, "unverified")
  assert_eq(
    assess_staging(bytes, Some(b"other"), evidence).status,
    "unverified",
  )
  assert_eq(assess_staging(b"partial", None, evidence).status, "unverified")
}
