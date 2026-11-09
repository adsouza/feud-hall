import Config

config :feud_hall, ecto_repos: [FeudHall.Infrastructure.Repo]

import_config "#{config_env()}.exs"
