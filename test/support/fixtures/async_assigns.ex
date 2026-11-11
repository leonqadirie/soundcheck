defmodule SoundcheckFixtures.AsyncAssignsLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Phoenix.LiveView.AsyncResult

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:profile, AsyncResult.loading())
     |> assign_async(:org, fn -> {:ok, %{org: %{name: "Acme"}}} end)
     |> assign_async([:profile, :stats], fn -> {:ok, %{profile: %{}, stats: %{}}} end)
     |> assign(:user, %{name: "Ada"})}
  end

  def render(assigns) do
    ~H"""
    <h1>{@org.name}</h1>
    <p :if={@org.ok?}>{@org.result.name}</p>
    <.async_result :let={profile} assign={@profile}>{profile.bio}</.async_result>
    <p>{@profile.bio}</p>
    <p>{@user.name}</p>
    """
  end
end
