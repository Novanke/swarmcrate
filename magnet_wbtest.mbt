///|
test "magnets round trip unicode and normalize base32 and multihashes" {
  let magnet : Magnet = {
    v1: Some("0123456789012345678901234567890123456789"),
    v2: Some("0123456789012345678901234567890123456789012345678901234567890123"),
    name: Some("中文 + & /"),
    trackers: ["https://example.org/a?x=1&b=2"],
  }
  let result = parse_magnet(format_magnet(magnet))
  assert_eq(result.name, magnet.name)
  assert_eq(result.trackers, magnet.trackers)
  assert_eq(result.v2, magnet.v2)
  assert_eq(
    parse_magnet("magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").v1,
    Some("0000000000000000000000000000000000000000"),
  )
  for
    uri in [
      "magnet:?xt=urn:btih:x", "magnet:?xt=urn:btmh:ff00", "magnet:?dn=%FF", "magnet:?dn=%XZ",
      "magnet:?dn=x",
    ] {
    assert_true(
      try {
        ignore(parse_magnet(uri))
        false
      } catch {
        _ => true
      },
    )
  }
}
