defmodule FeudHall.Web.EndpointTest do
  use ExUnit.Case, async: false

  alias FeudHall.Web.{Endpoint, ErrorJSON}

  test "the endpoint sends a JSON error for malformed request bodies" do
    start_supervised!({Endpoint, server: false})

    conn =
      Plug.Test.conn(:post, "/api/commands", "{")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert_raise Plug.Parsers.ParseError, fn -> Endpoint.call(conn, []) end
    assert {400, _, body} = Plug.Test.sent_resp(conn)
    assert Jason.decode!(body) == %{"error" => "invalid_command"}
  end

  test "unexpected server failures report unavailability without exposing details" do
    assert ErrorJSON.render("500.json", %{status: 500, reason: "private failure details"}) ==
             %{error: :unavailable}
  end
end
