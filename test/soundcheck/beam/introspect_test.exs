defmodule Soundcheck.Beam.IntrospectTest do
  use ExUnit.Case, async: false

  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Cache
  alias SoundcheckFixtures.CounterLive
  alias SoundcheckFixtures.Hooks

  setup do
    Cache.clear()
    :ok
  end

  describe "live/1" do
    test "identifies a LiveView and its module-level on_mount hooks" do
      assert {:ok, %{kind: :view, on_mount: [{Hooks, :default}]}} = Introspect.live(CounterLive)
    end

    test "identifies a LiveComponent" do
      assert {:ok, %{kind: :component, on_mount: []}} =
               Introspect.live(SoundcheckFixtures.FormComponent)
    end

    test "rejects other modules" do
      assert {:error, :not_live} = Introspect.live(SoundcheckFixtures.Components)
      assert {:error, :not_loadable} = Introspect.live(SoundcheckFixtures.DoesNotExist)
    end
  end

  describe "components/1" do
    test "returns declared components with their attrs and slots" do
      {:ok, components} = Introspect.components(SoundcheckFixtures.Components)

      assert [:card] = Map.keys(components)
      assert %{kind: :def, attrs: attrs, slots: [%{name: :inner_block}]} = components.card
      assert attrs |> Enum.map(& &1.name) |> Enum.sort() == [:icon, :title]
    end

    test "reports modules without declared components" do
      assert {:error, :no_components} = Introspect.components(Hooks)
    end
  end

  describe "live_routes/1" do
    test "returns live routes with their session and on_mount hooks" do
      {:ok, routes} = Introspect.live_routes(SoundcheckFixtures.Router)

      assert [
               %{
                 path: "/",
                 action: :index,
                 live_session: :default,
                 on_mount: [{Hooks, :default}]
               },
               %{path: "/edit/:id", action: :edit, on_mount: [{Hooks, :default}]},
               %{path: "/outside", action: nil, live_session: :default, on_mount: []}
             ] = routes

      assert Enum.all?(routes, &(&1.live_view == CounterLive and &1.verb == :get))
    end

    test "rejects modules that are not routers" do
      assert {:error, :not_a_router} = Introspect.live_routes(CounterLive)
    end
  end

  test "functions/1 lists exported functions" do
    {:ok, functions} = Introspect.functions(CounterLive)
    assert {:handle_event, 3} in functions
    assert {:error, :not_loadable} = Introspect.functions(SoundcheckFixtures.DoesNotExist)
  end
end
