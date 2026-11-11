defmodule SoundcheckFixtures.KeywordAttrsLive do
  @moduledoc false
  use Phoenix.LiveView

  # Phoenix.HTML-style helpers that take attributes as a keyword list.
  def render(assigns) do
    ~H"""
    {link("Reload", to: "#", phx_click: "reload")}
    {link("Typo", to: "#", phx_click: "reloads")}
    <div {if @open, do: [phx_window_keyup: "keyup"], else: []}></div>
    {tag(:span, phx_hook: "Clock")}
    {text_input(:form, :name, phx_hook: "Clock")}
    """
  end

  def handle_event("reload", _params, socket), do: {:noreply, socket}
  def handle_event("keyup", _params, socket), do: {:noreply, socket}

  defp link(_text, _opts), do: ""
  defp tag(_name, _opts), do: ""
  defp text_input(_form, _field, _opts), do: ""
end
