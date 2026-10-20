///|
pub(all) suberror CrateError {
  CrateError(String, String)
} derive(Debug)

///|
pub extend CrateError with Debug::{to_repr}

///|
fn reject(code : String, detail : String) -> Unit raise CrateError {
  raise CrateError(code, detail)
}

///|
priv enum BValue {
  Integer(Int64)
  Blob(Bytes)
  Sequence(Array[BNode])
  Dictionary(Array[(Bytes, BNode)])
}

///|
priv struct BNode {
  value : BValue
  start : Int32
  end : Int32
}

///|
priv struct BReader {
  data : Bytes
  mut cursor : Int32
  mut nodes : Int32
}

///|
fn byte_compare(a : Bytes, b : Bytes) -> Int32 {
  let length = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<length {
    if a[i] != b[i] {
      return a[i].to_int() - b[i].to_int()
    }
  }
  a.length() - b.length()
}

///|
fn read_blob(reader : BReader) -> Bytes raise CrateError {
  let start = reader.cursor
  let mut size = 0
  while reader.cursor < reader.data.length() {
    let c = reader.data[reader.cursor].to_int()
    if c == 58 {
      break
    }
    if c < 48 || c > 57 {
      reject("bencode", "invalid byte-string length at \{reader.cursor}")
    }
    if reader.cursor > start && reader.data[start] == 48 {
      reject("bencode", "leading zero in byte-string length")
    }
    size = size * 10 + c - 48
    if size > 16777216 {
      reject("limit", "byte string exceeds 16 MiB")
    }
    reader.cursor += 1
  }
  if reader.cursor == start || reader.cursor >= reader.data.length() {
    reject("bencode", "unterminated byte-string length")
  }
  reader.cursor += 1
  if size > reader.data.length() - reader.cursor {
    reject("bencode", "truncated byte string")
  }
  let data = reader.data[reader.cursor:reader.cursor + size].to_owned()
  reader.cursor += size
  data
}

///|
fn read_bnode(reader : BReader, depth : Int32) -> BNode raise CrateError {
  if depth > 64 || reader.nodes >= 200000 {
    reject("limit", "bencode depth/node limit exceeded")
  }
  if reader.cursor >= reader.data.length() {
    reject("bencode", "unexpected end of input")
  }
  reader.nodes += 1
  let start = reader.cursor
  let value = match reader.data[reader.cursor].to_int() {
    105 => {
      reader.cursor += 1
      let digits = reader.cursor
      if reader.cursor < reader.data.length() &&
        reader.data[reader.cursor] == 45 {
        reader.cursor += 1
      }
      let positive = reader.cursor
      while reader.cursor < reader.data.length() &&
            reader.data[reader.cursor] != 101 {
        let c = reader.data[reader.cursor].to_int()
        if c < 48 || c > 57 {
          reject("bencode", "non-decimal integer")
        }
        if reader.cursor - digits > 19 {
          reject("limit", "integer outside signed 64-bit range")
        }
        reader.cursor += 1
      }
      if reader.cursor == positive || reader.cursor >= reader.data.length() {
        reject("bencode", "unterminated or empty integer")
      }
      if reader.data[positive] == 48 &&
        (reader.cursor - positive > 1 || positive != digits) {
        reject("bencode", "noncanonical integer")
      }
      let text = @utf8.decode(reader.data[digits:reader.cursor]) catch {
        _ => {
          reject("bencode", "non-ASCII integer")
          ""
        }
      }
      let number = @string.parse_int64(text) catch {
        _ => {
          reject("limit", "integer outside signed 64-bit range")
          0L
        }
      }
      reader.cursor += 1
      Integer(number)
    }
    108 => {
      reader.cursor += 1
      let items : Array[BNode] = []
      while reader.cursor < reader.data.length() &&
            reader.data[reader.cursor] != 101 {
        items.push(read_bnode(reader, depth + 1))
      }
      if reader.cursor >= reader.data.length() {
        reject("bencode", "unterminated list")
      }
      reader.cursor += 1
      Sequence(items)
    }
    100 => {
      reader.cursor += 1
      let pairs : Array[(Bytes, BNode)] = []
      let mut previous : Bytes? = None
      while reader.cursor < reader.data.length() &&
            reader.data[reader.cursor] != 101 {
        let key = read_blob(reader)
        match previous {
          Some(previous) if byte_compare(previous, key) >= 0 =>
            reject("bencode", "dictionary keys must be unique and byte-sorted")
          _ => ()
        }
        previous = Some(key)
        pairs.push((key, read_bnode(reader, depth + 1)))
      }
      if reader.cursor >= reader.data.length() {
        reject("bencode", "unterminated dictionary")
      }
      reader.cursor += 1
      Dictionary(pairs)
    }
    48..<=57 => Blob(read_blob(reader))
    _ => {
      reject("bencode", "invalid token at \{reader.cursor}")
      Integer(0L)
    }
  }
  { value, start, end: reader.cursor, }
}

///|
fn decode_bencode(data : Bytes) -> BNode raise CrateError {
  if data.length() > 16777216 {
    reject("limit", "metainfo exceeds 16 MiB")
  }
  let reader : BReader = { data, cursor: 0, nodes: 0, }
  let node = read_bnode(reader, 0)
  if reader.cursor != data.length() {
    reject("bencode", "trailing bytes after root")
  }
  node
}

///|
fn append_bytes(out : Array[Byte], data : Bytes) -> Unit {
  for b in data {
    out.push(b)
  }
}

///|
fn write_bnode(
  node : BNode,
  out : Array[Byte],
  depth : Int32,
) -> Unit raise CrateError {
  if depth > 64 || out.length() > 16777216 {
    reject("limit", "encoded bencode exceeds limits")
  }
  match node.value {
    Integer(n) => append_bytes(out, @utf8.encode("i\{n}e"))
    Blob(data) => {
      append_bytes(out, @utf8.encode("\{data.length()}:"))
      append_bytes(out, data)
    }
    Sequence(items) => {
      out.push(108)
      for item in items {
        write_bnode(item, out, depth + 1)
      }
      out.push(101)
    }
    Dictionary(pairs) => {
      let sorted = pairs.copy()
      sorted.sort_by(fn(a, b) { byte_compare(a.0, b.0) })
      out.push(100)
      let mut previous : Bytes? = None
      for (key, value) in sorted {
        match previous {
          Some(old) if old == key =>
            reject("bencode", "duplicate dictionary key")
          _ => ()
        }
        previous = Some(key)
        write_bnode({ value: Blob(key), start: 0, end: 0, }, out, depth + 1)
        write_bnode(value, out, depth + 1)
      }
      out.push(101)
    }
  }
  if out.length() > 16777216 {
    reject("limit", "encoded bencode exceeds 16 MiB")
  }
}

///|
fn encode_bencode(node : BNode) -> Bytes raise CrateError {
  let out : Array[Byte] = []
  write_bnode(node, out, 0)
  Bytes::from_array(out)
}

///|
/// Validate canonical bencoding, including raw byte key order and signed Int64 bounds.
pub fn check_bencode(data : Bytes) -> Unit raise CrateError {
  let root = decode_bencode(data)
  if encode_bencode(root) != data[root.start:root.end].to_owned() {
    reject("bencode", "noncanonical encoding")
  }
}
