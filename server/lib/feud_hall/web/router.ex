defmodule FeudHall.Web.Router do
  use Plug.Router
  alias FeudHall.Infrastructure.HallAuthority
  alias FeudHall.Web.{Protocol, RateLimit, Token}

  @cookie "_feud_device"
  plug(:secure_headers)
  plug(:match)
  plug(:dispatch)

  get "/api/state" do
    run(conn, fn -> HallAuthority.management_view(authority(), device(conn)) end)
  end

  get "/api/dining-history" do
    before = fetch_query_params(conn).query_params["before"]
    run(conn, fn -> HallAuthority.dining_history(authority(), device(conn), before) end)
  end

  post "/api/device" do
    if write_allowed?(conn) and RateLimit.allow?({:device, conn.remote_ip}, 20) do
      case device(conn) do
        existing when is_binary(existing) ->
          respond(conn, 200, %{ready: true})

        _ ->
          token = Token.sign(:device, Token.new_id())
          conn |> put_resp_cookie(@cookie, token, cookie_options()) |> respond(201, %{ready: true})
      end
    else
      respond(conn, 403, %{error: :device_denied})
    end
  end

  post "/api/commands" do
    if write_allowed?(conn) and RateLimit.allow?({:command, conn.remote_ip}, 300) do
      with device when is_binary(device) <- device(conn),
           {:ok, command} <- Protocol.command(conn.body_params) do
        run(conn, fn -> HallAuthority.management_execute(authority(), device, command) end)
      else
        _ -> respond(conn, 400, %{error: :invalid_command})
      end
    else
      respond(conn, 403, %{error: :command_denied})
    end
  end

  post "/api/operator/seed" do
    configured = Application.fetch_env!(:feud_hall, __MODULE__)[:admin_key]
    provided = get_req_header(conn, "authorization")

    with key when is_binary(key) and byte_size(key) >= 32 <- configured,
         ["Bearer " <> candidate] <- provided,
         true <- Plug.Crypto.secure_compare(candidate, key),
         %{"command_id" => id, "principal" => principal} <- conn.body_params,
         true <- is_binary(id) and is_binary(principal) do
      run(conn, fn ->
        HallAuthority.execute(authority(), %{
          command_id: id,
          actor: {:system, :admin},
          command: {:seed_owner, %{principal: principal, reviewer?: true}}
        })
      end)
    else
      _ -> respond(conn, 403, %{error: :forbidden})
    end
  end

  get "/api/quote" do
    with {:ok, params} <- Protocol.fields(fetch_query_params(conn).query_params) do
      run(conn, fn -> HallAuthority.management_quote(authority(), device(conn), params) end)
    else
      _ -> respond(conn, 400, %{error: :invalid_quote})
    end
  end

  get "/" do
    file = Application.app_dir(:feud_hall, "priv/static/index.html")

    if File.regular?(file),
      do: conn |> put_resp_content_type("text/html") |> send_file(200, file),
      else: send_resp(conn, 503, "Feud Hall frontend is not built.")
  end

  match(_, do: respond(conn, 404, %{error: :not_found}))

  defp secure_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'self'; frame-ancestors 'none'; base-uri 'none'")
  end

  defp device(conn) do
    case Token.verify(:device, fetch_cookies(conn).req_cookies[@cookie]) do
      {:ok, device} -> device
      _ -> nil
    end
  end

  defp write_allowed?(conn) do
    [origin] = configured_origin()
    get_req_header(conn, "origin") == [origin] and get_req_header(conn, "x-feud-command") == ["1"]
  end

  defp configured_origin do
    [Keyword.fetch!(Application.fetch_env!(:feud_hall, __MODULE__), :origin)]
  end

  defp cookie_options do
    secure = Enum.any?(configured_origin(), &String.starts_with?(&1, "https://"))
    [path: "/", http_only: true, same_site: "Lax", secure: secure, max_age: 365 * 24 * 60 * 60]
  end

  defp authority, do: FeudHall.LiveAuthority

  defp run(conn, operation) do
    case operation.() do
      {:ok, %{profile: profile} = response} ->
        respond(conn, 200, %{response | profile: sign_codes(profile)})

      {:ok, response} ->
        respond(conn, 200, response)

      {status, receipt} when status in [:accepted, :rejected, :replayed] ->
        receipt = Map.take(receipt, [:command_id, :position, :outcome])

        outcome =
          case receipt.outcome do
            :accepted -> %{accepted: true}
            {:rejected, reason} -> %{accepted: false, reason: error_code(reason)}
          end

        conn =
          if outcome.accepted and conn.body_params["kind"] == "revoke_device",
            do: delete_resp_cookie(conn, @cookie, cookie_options()),
            else: conn

        respond(conn, 200, Map.merge(Map.delete(receipt, :outcome), outcome))

      {:uncertain, id} ->
        respond(conn, 503, %{error: :unknown_outcome, command_id: id})

      {:error, reason} ->
        respond(conn, 409, %{error: error_code(reason)})
    end
  catch
    :exit, {:noproc, _} -> respond(conn, 503, %{error: :unavailable})
    :exit, {:timeout, _} -> respond(conn, 503, %{error: :unknown_outcome})
  end

  defp sign_codes(nil), do: nil

  defp sign_codes(profile) do
    profile
    |> update_in(
      [:invitations],
      &Enum.map(&1, fn
        %{id: id, status: :unused} = invitation -> Map.put(invitation, :code, Token.sign(:invite, id))
        invitation -> invitation
      end)
    )
    |> update_in([:recovery_codes], &Enum.map(&1, fn id -> Token.sign(:recovery, id) end))
  end

  defp error_code(reason) when is_atom(reason), do: reason
  defp error_code({reason, _}) when is_atom(reason), do: reason
  defp error_code({reason, _, _}) when is_atom(reason), do: reason
  defp error_code(_), do: :rejected

  defp respond(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
