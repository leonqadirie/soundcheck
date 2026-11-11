defmodule Soundcheck.Analysis.HandlersTest do
  use Soundcheck.CheckCase

  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Beam.Introspect
  alias SoundcheckFixtures.AsyncLive

  describe "handler_set/3" do
    test "reads literal, prefix, and guard-restricted event patterns" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.CounterLive, :handle_event, [])

      assert set.patterns == [
               {:literal, "inc"},
               {:prefix, "row-"},
               {:literal, "reset"},
               {:literal, "clear"}
             ]

      assert set.closed?
      assert Handlers.handles?(set, {:literal, "row-12"})
      refute Handlers.handles?(set, {:literal, "save"})
    end

    test "reads atom and tagged tuple patterns" do
      {:ok, set} = Handlers.handler_set(AsyncLive, :handle_async, [])
      assert set.patterns == [{:atom, :load_users}, {:tagged, :fetch, 2}]
      assert Handlers.handles?(set, {:tagged, :fetch, 2})
      refute Handlers.handles?(set, {:atom, :load_stats})
    end

    test "a catch-all clause accepts everything" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.CatchAllLive, :handle_info, [])
      assert Handlers.handles?(set, {:atom, :whatever})
    end

    test "attach_hook for the stage opens the set" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.AttachedLive, :handle_info, [])
      refute set.closed?
      assert set.open_reasons == [:attach_hook]

      {:ok, events} = Handlers.handler_set(SoundcheckFixtures.AttachedLive, :handle_event, [])
      assert events.closed?
    end

    test "attach_hook in a live_session on_mount hook opens the set" do
      {:ok, routes} = Introspect.live_routes(SoundcheckFixtures.SessionHookRouter)

      {:ok, set} =
        Handlers.handler_set(SoundcheckFixtures.SessionHookedLive, :handle_event, routes)

      assert set.open_reasons == [:attach_hook]
    end

    test "without the route, the live_session hook does not apply" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.SessionHookedLive, :handle_event, [])
      assert set.closed?
    end

    test "a memoized answer for one route table does not leak into another" do
      {:ok, routes} = Introspect.live_routes(SoundcheckFixtures.SessionHookRouter)

      for {given, closed?} <- [{[], true}, {routes, false}, {[], true}] do
        {:ok, set} =
          Handlers.handler_set(SoundcheckFixtures.SessionHookedLive, :handle_event, given)

        assert set.closed? == closed?
      end
    end

    test "a module without the callback has a closed, empty set" do
      assert {:ok, %{patterns: [], closed?: true}} =
               Handlers.handler_set(SoundcheckFixtures.AttachedLive, :handle_async, [])
    end

    test "reports unreadable modules" do
      assert {:error, :no_debug_info} =
               Handlers.handler_set(SoundcheckFixtures.NoDebugInfoLive, :handle_info, [])
    end
  end

  test "async_starts/1 finds start_async calls through pipes" do
    {:ok, starts} = Handlers.async_starts(AsyncLive)

    assert Enum.map(starts, & &1.message) == [
             {:atom, :load_stats},
             {:atom, :load_users},
             {:tagged, :fetch, 2}
           ]

    # start_async is a macro; its expansion keeps the line but not the column.
    assert Enum.all?(
             starts,
             &(&1.call == "start_async" and is_integer(&1.line) and is_nil(&1.column))
           )
  end

  test "self_sends/1 finds messages sent to self" do
    {:ok, sends} = Handlers.self_sends(AsyncLive)

    assert Enum.map(sends, &{&1.call, &1.message}) == [
             {"Process.send_after", {:atom, :tick}},
             {"send", {:tagged, :loaded, 2}},
             {"send", {:atom, :ping}}
           ]
  end
end
