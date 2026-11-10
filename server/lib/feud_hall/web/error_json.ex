defmodule FeudHall.Web.ErrorJSON do
  @moduledoc false

  def render(_template, %{status: status}) when status >= 500, do: %{error: :unavailable}
  def render("400.json", _assigns), do: %{error: :invalid_command}
  def render(template, _assigns), do: %{error: Phoenix.Controller.status_message_from_template(template)}
end
