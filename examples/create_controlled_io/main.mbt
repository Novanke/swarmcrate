///|
extern "js" fn progress_log(text : String) -> Unit =
  #| text => process.stderr.write(text+'\n')

///|
fn main {
  let args = @cli.arguments()
  let phases = [
    "start", "before_read", "after_read", "before_encode", "finalize", "before_write",
  ]
  if args.length() < 4 ||
    !(args[0] == "full" ||
    phases.any(fn(p) { args[0] == "cancel-" + p || args[0] == "error-" + p })) {
    println(
      "Usage: full|cancel-PHASE|error-PHASE create INPUT NEW.torrent [creation options]",
    )
    @cli.set_exit_code(1)
  } else {
    let action = args[0]
    let result = @cli.execute_create_with_control(args[1:].to_owned(), fn(
      event,
    ) raise @swarm.CrateError {
      progress_log(
        Json::object(
          Map([
            ("phase", Json::string(event.phase)),
            ("mode", Json::string(@swarm.mode_name(event.mode))),
            ("read_calls", Json::number(event.read_calls.to_double())),
            (
              "validated_read_bytes",
              Json::string(event.validated_read_bytes.to_string()),
            ),
            ("total_bytes", Json::string(event.total_bytes.to_string())),
            ("file_count", Json::number(event.file_count.to_double())),
          ]),
        ).stringify(),
      )
      if action == "error-" + event.phase {
        raise @swarm.CrateError("observer", "creation observer failure")
      }
      action != "cancel-" + event.phase
    })
    println(result.output)
    @cli.set_exit_code(result.code)
  }
}
