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

///|
test "automatic sizing respects mode alignment host limits and fixed piece powers" {
  assert_eq(recommend_piece_length([{ path: ["small"], length: 1L, }]), 16384)
  let two : Array[SourceFile] = [
    { path: ["a"], length: 8193L, },
    { path: ["b"], length: 8193L, },
  ]
  assert_eq(recommend_piece_length(two, mode=V1, target_pieces=1), 32768)
  assert_eq(recommend_piece_length(two, mode=V2, target_pieces=1), 16384)
  // Thousands of tiny files must not grow to enormous padded pieces trying
  // to meet an impossible target smaller than the nonempty file count.
  let small = Array::makei(5000, fn(i) {
    SourceFile::{ path: [i.to_string()], length: 1L, }
  })
  assert_eq(recommend_piece_length(small), 16384)
  let big : Array[SourceFile] = [{ path: ["large"], length: 1073741824L, }]
  assert_eq(recommend_piece_length(big), 262144)
  assert_eq(recommend_piece_length(big, target_pieces=1), 16777216)
  for n in [0L, 1L, 16777216L, 4294967296L] {
    let files : Array[SourceFile] = [
      { path: ["a"], length: n, },
      { path: ["b"], length: 7L, },
    ]
    for mode in [V1, V2, Hybrid] {
      let piece = recommend_piece_length(files, mode~)
      validate_options(files, {
        ..create_options("bundle"),
        mode,
        piece_length: piece,
      })
    }
  }
  for
    files in [
      [{ path: ["empty"], length: 0L, }],
      [{ path: ["too-large"], length: 9007199254740991L, }],
    ] {
    assert_true(
      try {
        ignore(recommend_piece_length(files))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(recommend_piece_length(big, target_pieces=0))
      false
    } catch {
      _ => true
    },
  )
}
