///|
/// Creation checkpoints describe real reads, not proof that metainfo is encoded or saved.
/// before_write is emitted only by the controlled CLI adapter, before atomic publication.
pub(all) struct CreationProgress {
  phase : String
  mode : TorrentMode
  file_count : Int32
  total_bytes : Int64
  read_calls : Int32
  validated_read_bytes : Int64
  file : Int32?
  offset : Int64?
  length : Int32?
  metainfo_bytes : Int32?
}

///|
priv struct CreateControl {
  callback : (CreationProgress) -> Bool raise CrateError
  plan : TorrentPlan
  mut reads : Int32
  mut bytes : Int64
}

///|
fn emit_creation_progress(
  control : CreateControl?,
  phase : String,
  file~ : Int32? = None,
  offset~ : Int64? = None,
  length~ : Int32? = None,
  metainfo_bytes~ : Int32? = None,
) -> Unit raise CrateError {
  if control is Some(control) {
    let event : CreationProgress = {
      phase,
      mode: control.plan.mode,
      file_count: control.plan.file_count,
      total_bytes: control.plan.real_bytes,
      read_calls: control.reads,
      validated_read_bytes: control.bytes,
      file,
      offset,
      length,
      metainfo_bytes,
    }
    if !(control.callback)(event) {
      reject("cancelled", "torrent creation cancelled by progress callback")
    }
  }
}

///|
/// Create complete, validated metainfo with synchronous cooperative cancellation.
/// Callback false or any error returns no metainfo. No filesystem writes occur here.
pub fn create_torrent_with_control(
  files : Array[SourceFile],
  options : CreateOptions,
  read : (Int32, Int64, Int32) -> Bytes raise CrateError,
  on_progress : (CreationProgress) -> Bool raise CrateError,
) -> Bytes raise CrateError {
  let plan = plan_torrent(files, options)
  // Freeze caller-owned path/endpoint arrays before callbacks can modify them.
  let files = files.map(fn(file) {
    SourceFile::{ path: file.path.copy(), length: file.length, }
  })
  let options : CreateOptions = {
    ..options,
    trackers: options.trackers.map(fn(tier) { tier.copy() }),
    web_seeds: options.web_seeds.copy(),
  }
  create_torrent_impl(files, options, read, Some(on_progress), plan)
}
