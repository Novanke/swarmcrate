///|
#external
priv type IoResult

///|
extern "js" fn IoResult::error(self : Self) -> String =
  #| r => r.error

///|
extern "js" fn IoResult::text(self : Self) -> String =
  #| r => r.text || ""

///|
extern "js" fn IoResult::bytes(self : Self) -> Bytes =
  #| r => r.bytes || new Uint8Array(0)

///|
// This bridge performs OS I/O only. Hashing, metadata, traversal policy and CLI are MoonBit.
extern "js" fn os_io(
  op : String,
  path : String,
  offset : Double,
  size : Int32,
  content : Bytes,
  expected_stamp : String,
) -> IoResult =
  #| (op, input, offset, size, content, expected) => {
  #|   let fd;
  #|   let created = false;
  #|   let fs, path, target;
  #|   try {
  #|     fs = process.getBuiltinModule('node:fs');
  #|     path = process.getBuiltinModule('node:path');
  #|     target = path.resolve(input);
  #|     if (op === 'resolve') return {error:'', text:target};
  #|     const root = path.parse(target).root;
  #|     const parts = target.slice(root.length).split(path.sep).filter(Boolean);
  #|     let cursor = root;
  #|     for (let i = 0; i < parts.length; i++) {
  #|       cursor = path.join(cursor, parts[i]);
  #|       try {
  #|         if (fs.lstatSync(cursor).isSymbolicLink()) throw Error('symbolic links are unsupported');
  #|       } catch (e) {
  #|         if (e.code === 'ENOENT' && (op === 'stat' || (i === parts.length-1 && op === 'write'))) break;
  #|         throw e;
  #|       }
  #|     }
  #|     const stamp = s => `${s.dev}:${s.ino}:${s.size}:${s.mtimeNs}:${s.ctimeNs}`;
  #|     if (op === 'stat') {
  #|       try {
  #|         const s = fs.lstatSync(target,{bigint:true});
  #|         if (s.size > 9007199254740991n) throw Error('file too large');
  #|         return {error:'',text:JSON.stringify({kind:s.isFile()?'file':s.isDirectory()?'directory':'special',length:String(s.size),stamp:stamp(s)})};
  #|       } catch (e) {
  #|         if (e.code === 'ENOENT') return {error:'',text:'{"kind":"missing","length":"0","stamp":""}'};
  #|         throw e;
  #|       }
  #|     }
  #|     if (op === 'list') return {error:'',text:JSON.stringify(fs.readdirSync(target))};
  #|     if (op === 'read') {
  #|       if (!Number.isSafeInteger(offset) || offset < 0 || size < 0 || size > 1048576) throw Error('invalid read range');
  #|       fd = fs.openSync(target,fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  #|       const before = fs.fstatSync(fd,{bigint:true});
  #|       if (!before.isFile() || (expected && stamp(before) !== expected)) throw Error('source changed since scan');
  #|       const bytes = new Uint8Array(size);
  #|       let used = 0;
  #|       while (used < size) {
  #|         const n = fs.readSync(fd,bytes,used,size-used,offset+used);
  #|         if (!n) throw Error('short read');
  #|         used += n;
  #|       }
  #|       if (stamp(before) !== stamp(fs.fstatSync(fd,{bigint:true}))) throw Error('source changed during read');
  #|       return {error:'',bytes};
  #|     }
  #|     if (op === 'write') {
  #|       fd = fs.openSync(target,'wx',0o644);
  #|       created = true;
  #|       let used = 0;
  #|       while (used < content.length) {
  #|         const n = fs.writeSync(fd,content,used,content.length-used);
  #|         if (!n) throw Error('short write');
  #|         used += n;
  #|       }
  #|       fs.fsyncSync(fd);
  #|       return {error:'',text:target};
  #|     }
  #|     throw Error('unknown I/O operation');
  #|   } catch (e) {
  #|     if (fd !== undefined) { try { fs.closeSync(fd); } catch {} fd = undefined; }
  #|     if (created) { try { fs.unlinkSync(target); } catch {} }
  #|     return {error:String(e.message || e)};
  #|   } finally { if (fd !== undefined) fs.closeSync(fd); }
  #| }

///|
fn io(
  op : String,
  path : String,
  offset~ : Double = 0.0,
  size~ : Int32 = 0,
  content~ : Bytes = b"",
  stamp~ : String = "",
) -> IoResult raise @lib.CrateError {
  let result = os_io(op, path, offset, size, content, stamp)
  if result.error() != "" {
    raise @lib.CrateError("io", result.error())
  }
  result
}

///|
pub(all) struct FileStat {
  kind : String
  length : Int64
  stamp : String
}

///|
fn json_text(value : Json) -> String raise @lib.CrateError {
  match value {
    String(s) => s
    _ => raise @lib.CrateError("io", "invalid OS response")
  }
}

///|
pub fn stat(path : String) -> FileStat raise @lib.CrateError {
  let value = @json.parse(io("stat", path).text()) catch {
    _ => raise @lib.CrateError("io", "invalid OS JSON")
  }
  let fields = match value {
    Object(m) => m
    _ => raise @lib.CrateError("io", "invalid OS stat")
  }
  let length = @string.parse_int64(json_text(fields.get("length").unwrap())) catch {
    _ => raise @lib.CrateError("io", "invalid OS length")
  }
  {
    kind: json_text(fields.get("kind").unwrap()),
    length,
    stamp: json_text(fields.get("stamp").unwrap()),
  }
}

///|
pub fn resolve(path : String) -> String raise @lib.CrateError {
  io("resolve", path).text()
}

///|
pub fn read_range(
  path : String,
  offset : Int64,
  size : Int32,
  stamp~ : String = "",
) -> Bytes raise @lib.CrateError {
  io("read", path, offset=offset.to_double(), size~, stamp~).bytes()
}

///|
pub fn write_new(path : String, data : Bytes) -> Unit raise @lib.CrateError {
  ignore(io("write", path, content=data))
}

///|
pub fn read_metainfo(path : String) -> Bytes raise @lib.CrateError {
  let entry = stat(path)
  if entry.kind != "file" || entry.length > 16777216L {
    raise @lib.CrateError(
      "io", "expected a regular metainfo file of at most 16 MiB",
    )
  }
  let out : Array[Byte] = []
  let mut offset = 0L
  while offset < entry.length {
    let n = if entry.length - offset > 1048576L {
      1048576
    } else {
      (entry.length - offset).to_int()
    }
    for b in read_range(path, offset, n, stamp=entry.stamp) {
      out.push(b)
    }
    offset += n.to_int64()
  }
  Bytes::from_array(out)
}

///|
pub(all) struct DiskSource {
  descriptor : @lib.SourceFile
  absolute_path : String
  stamp : String
}

///|
fn visit(
  directory : String,
  path : Array[String],
  out : Array[DiskSource],
) -> Unit raise @lib.CrateError {
  if path.length() > 32 || out.length() > 65536 {
    raise @lib.CrateError("limit", "directory exceeds limits")
  }
  let value = @json.parse(io("list", directory).text()) catch {
    _ => raise @lib.CrateError("io", "invalid OS directory JSON")
  }
  let names = match value {
    Array(a) => a
    _ => raise @lib.CrateError("io", "invalid OS directory")
  }
  for value in names {
    let name = json_text(value)
    let child = directory + "/" + name
    let child_path = path.copy()
    child_path.push(name)
    let info = stat(child)
    if info.kind == "directory" {
      visit(child, child_path, out)
    } else if info.kind == "file" {
      out.push({
        descriptor: { path: child_path, length: info.length, },
        absolute_path: child,
        stamp: info.stamp,
      })
    } else {
      raise @lib.CrateError("io", "non-regular source: " + child)
    }
  }
}

///|
/// Scan without following symbolic links. File tokens detect edits during hashing.
pub fn scan(
  path : String,
) -> (String, Bool, Array[DiskSource]) raise @lib.CrateError {
  let absolute = resolve(path)
  let normalized = absolute
    .split("\\")
    .map(fn(p) { p.to_owned() })
    .to_array()
    .join("/")
  let parts = normalized.split("/").to_array()
  let name = parts[parts.length() - 1].to_owned()
  let info = stat(absolute)
  let out : Array[DiskSource] = []
  if info.kind == "file" {
    out.push({
      descriptor: { path: [name], length: info.length, },
      absolute_path: absolute,
      stamp: info.stamp,
    })
  } else if info.kind == "directory" {
    visit(absolute, [], out)
  } else {
    raise @lib.CrateError("io", "expected a regular file or directory")
  }
  ignore(@lib.validate_sources(out.map(fn(s) { s.descriptor })))
  (name, info.kind == "file", out)
}

///|
pub fn read_source(
  sources : Array[DiskSource],
  index : Int32,
  offset : Int64,
  n : Int32,
) -> Bytes raise @lib.CrateError {
  let source = sources[index]
  read_range(source.absolute_path, offset, n, stamp=source.stamp)
}
