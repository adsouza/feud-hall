import Config

config :feud_hall, ecto_repos: [FeudHall.Infrastructure.Repo]

config :feud_hall, FeudHall.Web.Endpoint, render_errors: [formats: [json: FeudHall.Web.ErrorJSON], layout: false]

import_config "#{config_env()}.exs"
