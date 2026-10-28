///|
#external
priv type IoResult

///|
extern "js" fn IoResult::error(self : Self) -> String =
  #| r => r.error

///|
extern "js" fn IoResult::code(self : Self) -> String =
  #| r => r.code || "io"

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
  #|   let stageDirectory, stageFile;
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
  #|         if (e.code === 'ENOENT' && (op === 'stat' || (i === parts.length-1 && (op === 'write' || op === 'publish')))) break;
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
  #|     if (op === 'list') {
  #|       if (!Number.isInteger(size) || size < 0) return {error:'invalid directory entry limit',code:'limit'};
  #|       const directory = fs.opendirSync(target);
  #|       try {
  #|         const names = [];
  #|         let entry;
  #|         while ((entry = directory.readSync()) !== null) {
  #|           if (names.length >= size) return {error:'directory entry limit exceeded',code:'limit'};
  #|           names.push(entry.name);
  #|         }
  #|         return {error:'',text:JSON.stringify(names)};
  #|       } finally { directory.closeSync(); }
  #|     }
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
  #|     if (op === 'publish') {
  #|       stageDirectory = fs.mkdtempSync(path.join(path.dirname(target), '.swarmcrate-'));
  #|       stageFile = path.join(stageDirectory, 'data');
  #|       fd = fs.openSync(stageFile,'wx',0o644);
  #|       let used = 0;
  #|       while (used < content.length) {
  #|         const n = fs.writeSync(fd,content,used,content.length-used);
  #|         if (!n) throw Error('short staged write');
  #|         used += n;
  #|       }
  #|       fs.fsyncSync(fd);
  #|       fs.closeSync(fd); fd = undefined;
  #|       // Atomic, non-replacing publication on filesystems supporting hard links.
  #|       fs.linkSync(stageFile,target);
  #|       return {error:'',text:target};
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
  #|   } finally {
  #|     if (fd !== undefined) fs.closeSync(fd);
  #|     if (stageFile) { try { fs.unlinkSync(stageFile); } catch {} }
  #|     if (stageDirectory) { try { fs.rmdirSync(stageDirectory); } catch {} }
  #|   }
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
    raise @lib.CrateError(result.code(), result.error())
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
  let encoded = io("stat", path).text()
  let value = @json.parse(encoded) catch {
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
/// Detect changes after a file's last read, including empty or missing files.
/// This is a consistency check for ordinary local edits, not an atomic snapshot.
pub fn check_unchanged(
  path : String,
  before : FileStat,
) -> Unit raise @lib.CrateError {
  let after = stat(path)
  if before.kind != after.kind ||
    before.length != after.length ||
    before.stamp != after.stamp {
    raise @lib.CrateError(
      "changed",
      "payload changed before completion: " + path,
    )
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
/// Stage and fsync bytes, then atomically publish without replacement using a hard link.
/// Unsupported filesystems fail without falling back to a partially visible target.
pub fn write_new_atomic(
  path : String,
  data : Bytes,
) -> Unit raise @lib.CrateError {
  ignore(io("publish", path, content=data))
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
pub fn read_source(
  sources : Array[DiskSource],
  index : Int32,
  offset : Int64,
  n : Int32,
) -> Bytes raise @lib.CrateError {
  let source = sources[index]
  read_range(source.absolute_path, offset, n, stamp=source.stamp)
}
