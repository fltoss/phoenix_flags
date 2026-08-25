# Used by "mix format"
[
  # dev.exs and bench/ were outside these globs, so CI's --check-formatted never
  # looked at them and they were free to drift.
  inputs: ["{mix,.formatter,dev}.exs", "{config,lib,test,bench}/**/*.{ex,exs}"]
]
