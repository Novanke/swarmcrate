///|
fn main {
  let result = @cli.execute(@cli.arguments())
  println(result.output)
  @cli.set_exit_code(result.code)
}
