///|
fn staging_command(args : Array[String]) -> CommandResult raise @lib.CrateError {
  let cleaning = args[0] == "staging-clean"
  let parsed = parse_args(
    args,
    if cleaning {
      ["--operation"]
    } else {
      []
    },
    false,
  )
  arity(parsed, 1)
  if cleaning {
    let id = one(parsed, "--operation", "")
    if !@lib.valid_staging_operation_id(id) {
      fail(
        "--operation requires the exact 32-character operation ID from staging-list",
      )
    }
    let inspection = @host.inspect_staging(parsed.positionals[0])
    @host.cleanup_staging(inspection, id)
    {
      code: 0,
      output: Json::object(
        Map([
          ("status", Json::string("removed")),
          ("operation_id", Json::string(id)),
        ]),
      ).stringify(indent=2),
    }
  } else {
    let inspections = @host.scan_staging(parsed.positionals[0])
    {
      code: 0,
      output: Json::object(
        Map([
          ("schema", Json::string("swarmcrate.staging-list.v1")),
          (
            "stages",
            Json::array(inspections.map(@host.staging_inspection_json)),
          ),
        ]),
      ).stringify(indent=2),
    }
  }
}
