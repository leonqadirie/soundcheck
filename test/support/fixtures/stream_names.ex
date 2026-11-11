defmodule SoundcheckFixtures.StreamNamesLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, socket |> stream(:posts, []) |> stream_configure(:comments, dom_id: & &1.id)}
  end

  def render(assigns) do
    ~H"""
    <div id="posts" phx-update="stream">
      <div :for={{id, post} <- @streams.post} id={id}>{post.title}</div>
    </div>
    <div id="comments" phx-update="stream">
      <div :for={{id, comment} <- @streams[:comments]} id={id}>{comment.body}</div>
    </div>
    """
  end

  def handle_info({:created, post}, socket), do: {:noreply, stream_insert(socket, :posts, post)}
  def handle_info({:deleted, post}, socket), do: {:noreply, stream_delete(socket, :post, post)}
end

defmodule SoundcheckFixtures.HelperStreamsLive do
  @moduledoc false
  use Phoenix.LiveView

  # A helper elsewhere defines the stream: the check skips the module.
  def mount(_params, _session, socket), do: {:ok, SoundcheckFixtures.StreamHelpers.load(socket)}

  def render(assigns) do
    ~H"""
    <div id="items" phx-update="stream">
      <div :for={{id, item} <- @streams.items} id={id}>{item.name}</div>
    </div>
    """
  end
end

defmodule SoundcheckFixtures.DynamicStreamsLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, stream(socket, name(), [])}

  def render(assigns), do: ~H(<div :for={{id, row} <- @streams.rows} id={id}>{row}</div>)

  defp name, do: :rows
end

defmodule SoundcheckFixtures.StreamHelpers do
  @moduledoc false
  def load(socket), do: Phoenix.LiveView.stream(socket, :items, [])
end
