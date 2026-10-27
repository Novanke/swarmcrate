// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Novanke/swarmcrate"

version = "0.8.0"

readme = "README.md"

repository = "https://github.com/Novanke/swarmcrate"

license = "Apache-2.0"

keywords = [ "bittorrent", "metainfo", "integrity", "cli" ]

preferred_target = "js"

description = "Offline BitTorrent v1/v2 metainfo creation and payload integrity verification"

import {
  "moonbitlang/x@0.5.5",
}
