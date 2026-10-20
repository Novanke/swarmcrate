///|
pub(all) struct Magnet {
  v1 : String?
  v2 : String?
  name : String?
  trackers : Array[String]
}

///|
fn hex_digit(n : Int32) -> Int32 {
  if n >= 48 && n <= 57 {
    n - 48
  } else if n >= 65 && n <= 70 {
    n - 55
  } else if n >= 97 && n <= 102 {
    n - 87
  } else {
    -1
  }
}

///|
fn normalized_hex(text : String, length : Int32) -> String raise CrateError {
  if text.length() != length {
    reject("magnet", "wrong info hash length")
  }
  for b in @utf8.encode(text) {
    if hex_digit(b.to_int()) < 0 {
      reject("magnet", "invalid hexadecimal info hash")
    }
  }
  text.to_lower()
}

///|
fn uri_encode(text : String) -> String {
  let out : Array[Byte] = []
  for byte in @utf8.encode(text) {
    let c = byte.to_int()
    if (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      [45, 46, 95, 126].contains(c) {
      out.push(byte)
    } else {
      out.push(37)
      out.push(b"0123456789ABCDEF"[c / 16])
      out.push(b"0123456789ABCDEF"[c % 16])
    }
  }
  @utf8.decode_lossy(Bytes::from_array(out))
}

///|
fn uri_decode(text : String) -> String raise CrateError {
  let bytes = @utf8.encode(text)
  let out : Array[Byte] = []
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == 37 {
      if i + 2 >= bytes.length() {
        reject("magnet", "incomplete percent escape")
      }
      let a = hex_digit(bytes[i + 1].to_int())
      let b = hex_digit(bytes[i + 2].to_int())
      if a < 0 || b < 0 {
        reject("magnet", "invalid percent escape")
      }
      out.push((a * 16 + b).to_byte())
      i += 3
    } else {
      out.push(bytes[i])
      i += 1
    }
  }
  @utf8.decode(Bytes::from_array(out)) catch {
    _ => {
      reject("magnet", "invalid UTF-8 URI value")
      ""
    }
  }
}

///|
fn decode_base32_hash(text : String) -> String raise CrateError {
  if text.length() != 32 {
    reject("magnet", "wrong base32 hash length")
  }
  let bytes : Array[Byte] = []
  let mut bits = 0
  let mut value = 0
  for c in @utf8.encode(text.to_upper()) {
    let c = c.to_int()
    let digit = if c >= 65 && c <= 90 {
      c - 65
    } else if c >= 50 && c <= 55 {
      c - 24
    } else {
      -1
    }
    if digit < 0 {
      reject("magnet", "invalid base32 hash")
    }
    value = (value << 5) | digit
    bits += 5
    if bits >= 8 {
      bits -= 8
      bytes.push(((value >> bits) & 255).to_byte())
      value = value & ((1 << bits) - 1)
    }
  }
  @crypto.bytes_to_hex_string(Bytes::from_array(bytes))
}

///|
pub fn format_magnet(magnet : Magnet) -> String raise CrateError {
  let params : Array[String] = []
  match magnet.v1 {
    Some(h) => params.push("xt=urn:btih:" + normalized_hex(h, 40))
    None => ()
  }
  match magnet.v2 {
    Some(h) => params.push("xt=urn:btmh:1220" + normalized_hex(h, 64))
    None => ()
  }
  if params.is_empty() {
    reject("magnet", "at least one info hash is required")
  }
  match magnet.name {
    Some(name) => params.push("dn=" + uri_encode(name))
    None => ()
  }
  for url in magnet.trackers {
    check_url(url, true)
    params.push("tr=" + uri_encode(url))
  }
  let uri = "magnet:?" + params.join("&")
  if uri.length() > 65536 {
    reject("limit", "magnet URI too large")
  }
  uri
}

///|
pub fn parse_magnet(uri : String) -> Magnet raise CrateError {
  if !uri.has_prefix("magnet:?") || uri.length() > 65536 || uri.contains("#") {
    reject("magnet", "invalid magnet URI")
  }
  let query = uri.strip_prefix("magnet:?").unwrap()
  let mut v1 : String? = None
  let mut v2 : String? = None
  let mut name : String? = None
  let trackers : Array[String] = []
  for pair in query.split("&") {
    let (key, value) = match pair.split_once("=") {
      Some(p) => p
      None => {
        reject("magnet", "query field lacks equals sign")
        ("", "")
      }
    }
    let value = uri_decode(value.to_owned())
    if key == "xt" && value.has_prefix("urn:btih:") {
      let h = value.strip_prefix("urn:btih:").unwrap().to_owned()
      let h = if h.length() == 32 {
        decode_base32_hash(h)
      } else {
        normalized_hex(h, 40)
      }
      if v1 is Some(old) && old != h {
        reject("magnet", "conflicting v1 hashes")
      }
      v1 = Some(h)
    } else if key == "xt" && value.has_prefix("urn:btmh:") {
      let h = value.strip_prefix("urn:btmh:").unwrap().to_owned()
      if !h.has_prefix("1220") {
        reject("magnet", "unsupported multihash")
      }
      let h = normalized_hex(h.strip_prefix("1220").unwrap().to_owned(), 64)
      if v2 is Some(old) && old != h {
        reject("magnet", "conflicting v2 hashes")
      }
      v2 = Some(h)
    } else if key == "dn" {
      if name is Some(_) {
        reject("magnet", "duplicate display name")
      }
      name = Some(value)
    } else if key == "tr" {
      check_url(value, true)
      trackers.push(value)
    }
  }
  if v1 is None && v2 is None {
    reject("magnet", "no supported info hash")
  }
  { v1, v2, name, trackers, }
}

///|
pub fn torrent_magnet(data : Bytes) -> String raise CrateError {
  let info = inspect_torrent(data)
  let trackers : Array[String] = []
  for tier in info.trackers {
    for url in tier {
      if !trackers.contains(url) {
        trackers.push(url)
      }
    }
  }
  format_magnet({
    v1: info.info_hash_v1,
    v2: info.info_hash_v2,
    name: Some(info.name),
    trackers,
  })
}
