defmodule SoundcheckFixtures.EventPayloadsLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Phoenix.LiveView.JS

  def render(assigns) do
    ~H"""
    <button phx-click="delete">missing id</button>
    <div phx-click={JS.push("delete", value: %{slug: @slug})}>pushes the wrong key</div>
    <a phx-click="open" phx-value-postId={@post_id}>camel case</a>
    <button phx-click="delete" phx-value-id={@id}>ok</button>
    <a phx-click={JS.push("delete", value: %{"id" => @id})}>ok through the push</a>
    <a phx-click={JS.push("delete", value: @value)}>dynamic value</a>
    <div {@attrs} phx-click="delete">spread attributes</div>
    <select phx-click="pick">value property</select>
    <span phx-click="pick">no value</span>
    <a phx-click="filter">a catch-all clause accepts it</a>
    """
  end

  def handle_event("delete", %{"id" => _id}, socket), do: {:noreply, socket}
  def handle_event("open", %{"postId" => _id}, socket), do: {:noreply, socket}
  def handle_event("pick", %{"value" => _value}, socket), do: {:noreply, socket}
  def handle_event("filter", %{"q" => _q}, socket), do: {:noreply, socket}
  def handle_event("filter", _params, socket), do: {:noreply, socket}
end
