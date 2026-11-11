defmodule SoundcheckFixtures.PatchingLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <.link patch="/posts">ok</.link>
    <.link patch="/users/2">wrong</.link>
    <button phx-click={Phoenix.LiveView.JS.patch("/posts?sort=title")}>sort</button>
    """
  end

  def handle_event("edit", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: "/posts/#{id}/edit")}

  def handle_event("profile", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: "/users/#{id}?tab=posts")}
end

defmodule SoundcheckFixtures.FilterLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H(<.link patch="/filters?sort=name">sort</.link>)

  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, :sort, params["sort"])}
end

defmodule SoundcheckFixtures.SubscriberLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(SoundcheckFixtures.PubSub, "posts")
    {:ok, socket}
  end

  def render(assigns), do: ~H"<p></p>"
end

defmodule SoundcheckFixtures.NavigationRouter do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  live "/posts", SoundcheckFixtures.PatchingLive, :index
  live "/posts/:id/edit", SoundcheckFixtures.PatchingLive, :edit
  live "/users/:id", SoundcheckFixtures.CounterLive, :show
  live "/filters", SoundcheckFixtures.FilterLive, :index
end

defmodule SoundcheckFixtures.UserAuth do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]

  # Loads the user and never halts: it authenticates nothing on its own.
  def on_mount(:mount_current_user, _params, session, socket),
    do: {:cont, assign(socket, :current_user, session["user"])}

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = assign(socket, :current_user, session["user"])
    if socket.assigns.current_user, do: {:cont, socket}, else: deny(socket)
  end

  defp deny(socket), do: {:halt, socket}
end

defmodule SoundcheckFixtures.MembersLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"
end

defmodule SoundcheckFixtures.HomeLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <.link navigate="/about">same session</.link>
    <.link navigate="/admin">other session</.link>
    <button phx-click={Phoenix.LiveView.JS.navigate("/admin")}>admin</button>
    """
  end

  def handle_event("settings", _params, socket),
    do: {:noreply, push_navigate(socket, to: "/admin/settings")}
end

defmodule SoundcheckFixtures.AboutLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"
end

defmodule SoundcheckFixtures.AdminLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"
end

defmodule SoundcheckFixtures.SettingsLive do
  @moduledoc false
  use Phoenix.LiveView

  on_mount {SoundcheckFixtures.UserAuth, :ensure_authenticated}

  def render(assigns), do: ~H"<p></p>"
end

defmodule SoundcheckFixtures.SessionsRouter do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  live_session :public do
    live "/", SoundcheckFixtures.HomeLive, :index
    live "/about", SoundcheckFixtures.AboutLive, :index
    live "/preview", SoundcheckFixtures.AdminLive, :preview
  end

  live_session :members, on_mount: [{SoundcheckFixtures.UserAuth, :mount_current_user}] do
    live "/members", SoundcheckFixtures.MembersLive, :index
  end

  scope "/admin" do
    live_session :admin, on_mount: [{SoundcheckFixtures.UserAuth, :ensure_authenticated}] do
      live "/", SoundcheckFixtures.AdminLive, :index
    end

    live_session :settings do
      live "/settings", SoundcheckFixtures.SettingsLive, :index
    end
  end
end
