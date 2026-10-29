///|
extern "js" fn log_progress(text : String) -> Unit =
  #| text => process.stderr.write(text+'\n')

///|
fn main {
  let args = @cli.arguments()
  let file_mode = args.length() == 5 &&
    args[0] == "--cancel-file" &&
    !args[1].is_empty()
  let phases = [
    "start", "before_task", "after_load", "before_observe", "verification/start",
    "verification/before_read", "verification/after_read", "verification/check",
    "verification/finalize", "before_finish", "task_complete", "before_summary",
    "finalize", "before_write",
  ]
  if !file_mode &&
    (
      args.length() != 4 ||
      !(args[0] == "full" ||
      phases.any(fn(p) { args[0] == "cancel-" + p || args[0] == "error-" + p }))
    ) {
    println(
      "Usage: full|cancel-PHASE|error-PHASE audit-batch MANIFEST.json NEW-SUMMARY.json; or --cancel-file MARKER audit-batch MANIFEST.json NEW-SUMMARY.json",
    )
    @cli.set_exit_code(1)
  } else {
    let action = if file_mode { "full" } else { args[0] }
    let marker = if file_mode {
      Some(@host.resolve_from(".", args[1]))
    } else {
      None
    }
    let command = if file_mode {
      args[2:].to_owned()
    } else {
      args[1:].to_owned()
    }
    let result = @cli.execute_batch_with_control(command, fn(
      event,
    ) raise @swarm.CrateError {
      log_progress(@swarm.batch_progress_json(event).stringify())
      if marker is Some(path) {
        return @host.stat(path).kind == "missing"
      }
      let phase = match event.verification {
        Some(v) => "verification/" + v.phase
        None => event.phase
      }
      if action == "error-" + phase {
        raise @swarm.CrateError("observer", "batch observer failure")
      }
      action != "cancel-" + phase
    })
    println(result.output)
    @cli.set_exit_code(result.code)
  }
}
