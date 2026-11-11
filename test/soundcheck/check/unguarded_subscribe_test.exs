defmodule Soundcheck.Check.Warning.UnguardedSubscribeTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UnguardedSubscribe

  defp live(mount_body) do
    """
    defmodule MyAppWeb.FeedLive do
      use MyAppWeb, :live_view
      alias Phoenix.PubSub

      def mount(_params, _session, socket) do
    #{mount_body}
        {:ok, socket}
      end
    end
    """
  end

  test "fires on an unguarded PubSub subscription, through aliases" do
    source = live("    PubSub.subscribe(MyApp.PubSub, \"posts\")")
    assert [diagnostic] = analyze(UnguardedSubscribe, source)
    assert text_at(source, diagnostic.primary) == "PubSub.subscribe"
    assert diagnostic.message =~ "not guarded by `connected?(socket)`"
  end

  test "fires on any *.subscribe call by default" do
    assert [_diagnostic] =
             analyze(UnguardedSubscribe, live("    MyAppWeb.Endpoint.subscribe(\"posts\")"))
  end

  test "near miss: guarded by connected?, including negations and else branches" do
    for body <- [
          "    if connected?(socket), do: PubSub.subscribe(MyApp.PubSub, \"posts\")",
          "    unless !connected?(socket), do: PubSub.subscribe(MyApp.PubSub, \"posts\")",
          "    if not connected?(socket), do: :ok, else: PubSub.subscribe(MyApp.PubSub, \"posts\")"
        ] do
      assert [] = analyze(UnguardedSubscribe, live(body)), "expected no finding for: #{body}"
    end
  end

  test "honors subscribe_functions" do
    source = live("    MyApp.Feed.listen(\"posts\")")
    assert [] = analyze(UnguardedSubscribe, source)
    assert [_diagnostic] = analyze(UnguardedSubscribe, source, subscribe_functions: [~r/listen$/])
  end
end
