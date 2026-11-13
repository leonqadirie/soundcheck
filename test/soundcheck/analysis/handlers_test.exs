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

    test "reads the literal a `=` in an event head binds" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.PatternsLive, :handle_event, [])

      assert [{:literal, "save"}, _binary] = set.patterns
    end

    test "an event head that is neither a literal, a prefix, nor a variable accepts everything" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.PatternsLive, :handle_event, [])

      assert [_save, :any] = set.patterns
      assert Handlers.handles?(set, {:literal, "anything"})
    end

    test "a guard that is not a chain of literal comparisons leaves the clause open" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.GuardedEventsLive, :handle_event, [])
      assert set.patterns == [:any]
    end

    test "several `when` guards leave the clause open" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.TwoGuardsLive, :handle_event, [])
      assert set.patterns == [:any]
    end

    test "reads tuple, tagged tuple, `=`, and map message patterns" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.PatternsLive, :handle_info, [])

      assert set.patterns == [
               {:tagged, :loaded, 3},
               {:tuple, 2},
               {:tuple, 4},
               {:atom, :tick},
               :other
             ]
    end

    test "an untagged tuple pattern accepts every tagged message of its size" do
      {:ok, set} = Handlers.handler_set(SoundcheckFixtures.PatternsLive, :handle_info, [])

      assert Handlers.handles?(set, {:tagged, :anything, 2})
      assert Handlers.handles?(set, {:tagged, :DOWN, 4})
      assert Handlers.handles?(set, {:tagged, :loaded, 3})
      refute Handlers.handles?(set, {:tagged, :saved, 3})
      refute Handlers.handles?(set, {:atom, :ping})
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

  test "self_sends/1 reads tagged tuples of any size and skips dynamic messages and other pids" do
    {:ok, sends} = Handlers.self_sends(SoundcheckFixtures.PatternsLive)

    assert Enum.map(sends, &{&1.call, &1.message}) == [{"send", {:tagged, :done, 3}}]
  end

  test "map_pattern_pairs/1 reads both sides of a `=` and no pairs from other patterns" do
    pattern = quote(do: %{"id" => id} = %{"name" => name})

    assert [{"id", {:id, _, _}}, {"name", {:name, _, _}}] = Handlers.map_pattern_pairs(pattern)
    assert Handlers.map_pattern_pairs(quote(do: params)) == []
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
