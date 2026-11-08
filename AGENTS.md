# Local container execution

Never use Colima. Use Apple Container (`container`) for local container execution
on macOS, including Linux amd64 images through Rosetta. Apple Container is the
preferred local runtime for its substantially faster execution. Do not start,
configure, or fall back to Colima when a workflow assumes Docker; adapt the
workflow to Apple Container and retain the actual execution/coverage boundary.
Historical Colima evidence describes past runs only and is not a recipe to repeat.
