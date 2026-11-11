defmodule SoundcheckFixtures.AuthHooks do
  @moduledoc false
  # on_mount/4 shapes for Soundcheck.Analysis.MountHooks.can_halt?/2.

  def on_mount(:loads, _params, _session, socket), do: {:cont, socket}

  def on_mount(:raises, _params, session, socket) do
    if session["user"], do: {:cont, socket}, else: raise("unauthenticated")
  end

  def on_mount(:delegates, _params, session, socket),
    do: SoundcheckFixtures.Policy.check(session, socket)

  def on_mount(:with_no_else, _params, session, socket) do
    with {:ok, _user} <- fetch(session), do: {:cont, socket}
  end

  def on_mount(:recursive, params, session, socket), do: loop(params, session, socket)

  defp fetch(session), do: Map.fetch(session, "user")

  defp loop([], _session, socket), do: {:cont, socket}
  defp loop([_ | rest], session, socket), do: loop(rest, session, socket)
end

defmodule SoundcheckFixtures.Policy do
  @moduledoc false
  def check(_session, socket), do: {:halt, socket}
end
