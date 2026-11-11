defmodule SoundcheckFixtures.NavigatingLive do
  @moduledoc false
  use Phoenix.LiveView

  # The branch that skips :plan navigates away, so it never renders.
  def mount(params, _session, socket) do
    if params["token"] do
      {:ok, assign(socket, :plan, :pro)}
    else
      {:ok, push_navigate(socket, to: "/login")}
    end
  end

  # Only this clause assigns :label; the template it holds reads it.
  def render(%{plan: :pro} = assigns) do
    assigns = assign(assigns, :label, "Plan")

    ~H"""
    <h1>{@label}: {@plan}</h1>
    <p>{@missing}</p>
    """
  end

  def render(assigns), do: ~H"<p>{@plan}</p>"
end

defmodule SoundcheckFixtures.RedirectedWhenDisconnectedLive do
  @moduledoc false
  use Phoenix.LiveView

  # The disconnected mount always redirects, so it never renders :feed.
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: {:ok, assign(socket, :feed, [])},
      else: {:ok, redirect(socket, to: "/")}
  end

  def render(assigns), do: ~H"<ul>{@feed}</ul>"
end
