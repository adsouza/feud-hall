defmodule FeudHall.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :feud_hall

  socket("/socket", FeudHall.Web.Socket, websocket: true, longpoll: false)

  plug(Plug.Static, at: "/", from: {:feud_hall, "priv/static"}, gzip: false)
  plug(Plug.Parsers, parsers: [:json], pass: [], json_decoder: Jason, length: 65_536)
  plug(FeudHall.Web.Router)
end

defmodule FeudHall.Web.Socket do
  use Phoenix.Socket
  channel("hall:public", FeudHall.Web.PublicHallChannel)

  @impl true
  def connect(_params, socket, _info), do: {:ok, socket}
  @impl true
  def id(_socket), do: nil
end

defmodule FeudHall.Web.PublicHallChannel do
  use Phoenix.Channel

  @impl true
  def join("hall:public", _params, socket), do: {:ok, socket}
end
