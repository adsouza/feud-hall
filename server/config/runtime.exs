import Config

if System.get_env("FEUD_HALL_SERVE") == "1" do
  secret = System.fetch_env!("FEUD_HALL_SECRET")
  if byte_size(secret) < 32, do: raise("FEUD_HALL_SECRET must be at least 32 bytes")
  origin = System.get_env("FEUD_HALL_ORIGIN") || System.get_env("RENDER_EXTERNAL_URL") || "http://localhost:4000"
  uri = URI.parse(origin)

  unless is_binary(uri.host) and is_nil(uri.userinfo) and uri.path in [nil, ""] and
           is_nil(uri.query) and is_nil(uri.fragment) and
           (uri.scheme == "https" or (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1"])) do
    raise("FEUD_HALL_ORIGIN must be HTTPS except on loopback")
  end

  port = String.to_integer(System.get_env("PORT", "4000"))
  config :feud_hall, :serve, true
  config :feud_hall, :hall_id, System.get_env("FEUD_HALL_ID", "public")
  config :feud_hall, FeudHall.Web.Token, secret: secret
  config :feud_hall, FeudHall.Web.Router, origin: origin, admin_key: System.get_env("FEUD_HALL_ADMIN_KEY")

  config :feud_hall, FeudHall.Infrastructure.Repo,
    database: System.get_env("FEUD_HALL_DB", "feud_hall_management"),
    log: false

  database_url =
    if config_env() == :prod, do: System.fetch_env!("DATABASE_URL"), else: System.get_env("DATABASE_URL")

  if url = database_url do
    config :feud_hall, FeudHall.Infrastructure.Repo, url: url
  end

  config :feud_hall, FeudHall.Web.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    http: [ip: if(uri.scheme == "https", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}), port: port],
    url: [host: uri.host, scheme: uri.scheme, port: uri.port],
    check_origin: [origin],
    pubsub_server: FeudHall.PubSub,
    secret_key_base: :crypto.hash(:sha512, secret) |> Base.encode64(),
    server: true
end
