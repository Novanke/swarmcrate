///|
test "portable file sets reject traversal collisions devices and overflow" {
  for
    url in [
      "https://@/announce", "https://:80/a", "http:///a", "https://host/#fragment",
      "https://host\\evil/a",
    ] {
    assert_true(
      try {
        check_url(url, true)
        false
      } catch {
        _ => true
      },
    )
  }
  let files : Array[SourceFile] = [
    { path: ["z"], length: 1L, },
    { path: ["目录", "a"], length: 2L, },
    { path: ["a"], length: 0L, },
  ]
  assert_eq(validate_sources(files), 3L)
  assert_eq(sorted_source_indices(files), [2, 0, 1])
  for path in [["..", "x"], ["a/b"], ["CON.txt"], ["a "], [".pad", "5"], [""]] {
    let bad = try {
      ignore(validate_sources([{ path, length: 0L, }]))
      false
    } catch {
      _ => true
    }
    assert_true(bad)
  }
  for
    sources in [
      [{ path: ["a"], length: 0L, }, { path: ["A"], length: 0L, }],
      [{ path: ["a"], length: 0L, }, { path: ["a", "b"], length: 0L, }],
      [{ path: ["a"], length: -1L, }],
    ] {
    let bad = try {
      ignore(validate_sources(sources))
      false
    } catch {
      _ => true
    }
    assert_true(bad)
  }
  let bad = try {
    validate_options(files, {
      ..create_options("dataset"),
      piece_length: 17000,
    })
    false
  } catch {
    _ => true
  }
  assert_true(bad)
}
