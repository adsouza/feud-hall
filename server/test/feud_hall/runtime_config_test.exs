defmodule FeudHall.RuntimeConfigTest do
  # Not async: it sets the process environment that `config/runtime.exs` reads.
  use ExUnit.Case, async: false

  alias FeudHall.Infrastructure.Repo

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @env ~w(FEUD_HALL_SERVE FEUD_HALL_SECRET FEUD_HALL_ORIGIN DATABASE_URL)
  @neon "postgresql://hall:p%40ss@ep-quiet-sun-123456.us-east-1.aws.neon.tech/neondb?sslmode=require&channel_binding=require"

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env(%{
      "FEUD_HALL_SERVE" => "1",
      "FEUD_HALL_SECRET" => String.duplicate("s", 32),
      "FEUD_HALL_ORIGIN" => "https://hall.example.test"
    })
  end

  # The options Postgrex receives: Ecto merges the parsed URL over the repo's configuration.
  defp postgrex_options(url) do
    System.put_env("DATABASE_URL", url)
    repo = Config.Reader.read!(@runtime, env: :prod)[:feud_hall][Repo]
    Keyword.merge(repo, Ecto.Repo.Supervisor.parse_url(repo[:url]))
  end

  test "Ecto alone passes libpq's sslmode through as an option Postgrex ignores" do
    parsed = Ecto.Repo.Supervisor.parse_url(@neon)
    assert parsed[:sslmode] == "require"
    refute Keyword.has_key?(parsed, :ssl)
  end

  test "a Neon connection string enables verified TLS and drops the libpq-only parameters" do
    options = postgrex_options(@neon)

    assert options[:ssl] == true
    refute Keyword.has_key?(options, :sslmode)
    refute Keyword.has_key?(options, :channel_binding)
    assert options[:hostname] == "ep-quiet-sun-123456.us-east-1.aws.neon.tech"
    assert options[:username] == "hall"
    assert options[:password] == "p@ss"
    assert options[:database] == "neondb"
  end

  test "other query parameters survive the rewrite" do
    options = postgrex_options("postgresql://hall:pw@db.example.test/hall?sslmode=verify-full&pool_size=4")

    assert options[:ssl] == true
    assert options[:pool_size] == 4
    refute Keyword.has_key?(options, :sslmode)
  end

  test "sslmode=disable turns TLS off" do
    assert postgrex_options("postgresql://hall:pw@db.example.test/hall?sslmode=disable")[:ssl] == false
  end

  test "a URL without sslmode is passed through unchanged" do
    url = "postgresql://hall:pw@dpg-internal-a/hall"
    System.put_env("DATABASE_URL", url)
    repo = Config.Reader.read!(@runtime, env: :prod)[:feud_hall][Repo]

    assert repo[:url] == url
    refute Keyword.has_key?(repo, :ssl)
  end

  test "an sslmode that would fall back to plaintext is refused without echoing the URL" do
    for mode <- ~w(allow prefer bogus) do
      System.put_env("DATABASE_URL", "postgresql://hall:secret-pw@db.example.test/hall?sslmode=#{mode}")
      error = assert_raise RuntimeError, fn -> Config.Reader.read!(@runtime, env: :prod) end
      assert error.message =~ "sslmode"
      refute error.message =~ "secret-pw"
    end
  end
end
