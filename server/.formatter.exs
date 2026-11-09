# Used by "mix format"; CI runs "mix format --check-formatted".
[
  import_deps: [:ecto, :ecto_sql],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,scripts}/**/*.{ex,exs}", "priv/*/migrations/*.exs"],
  line_length: 120
]
