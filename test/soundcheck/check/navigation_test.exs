defmodule Soundcheck.Check.NavigationTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Analysis.Routes
  alias Soundcheck.Check.Refactor.NavigateAcrossLiveSession
  alias Soundcheck.Check.Warning.LiveRouteWithoutAuthHook
  alias Soundcheck.Check.Warning.PatchToForeignLiveView
  alias Soundcheck.Check.Warning.PatchWithoutHandleParams
  alias Soundcheck.Check.Warning.SubscribedWithoutHandleInfo

  @fixture "test/support/fixtures/navigation.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  describe "PatchToForeignLiveView (SC701)" do
    test "fires on server-side patches to routes another LiveView renders" do
      diagnostics = analyze(PatchToForeignLiveView, fixture())
      texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

      assert texts == ["push_patch"]
      assert Enum.all?(diagnostics, &(&1.message =~ "SoundcheckFixtures.CounterLive"))
    end

    test "near miss: patches within the same LiveView, and client-side patch links" do
      diagnostics = analyze(PatchToForeignLiveView, fixture())
      texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

      # `<.link patch="/users/2">` falls back to navigation instead of raising.
      refute "/users/2" in texts
      refute Enum.any?(diagnostics, &(&1.primary.start == {15, 31}))
      assert [_profile] = diagnostics
    end
  end

  describe "PatchWithoutHandleParams (SC703)" do
    test "fires on patches back to a LiveView without handle_params/3" do
      diagnostics = analyze(PatchWithoutHandleParams, fixture())
      texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

      assert texts == ["/posts", "Phoenix.LiveView.JS.patch", "push_patch"]
      assert Enum.all?(diagnostics, &(&1.message =~ "`SoundcheckFixtures.PatchingLive`"))
    end

    test "near miss: patches to another LiveView and LiveViews with handle_params/3" do
      diagnostics = analyze(PatchWithoutHandleParams, fixture())
      texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

      refute "/users/2" in texts
      refute "/filters?sort=name" in texts
    end
  end

  describe "Routes" do
    test "match literal and interpolated paths against route patterns" do
      routes = [%{path: "/posts/:id/edit"}, %{path: "/users/:id"}, %{path: "/files/*path"}]

      {:ok, sigil_path} =
        "~p\"/posts/\#{post.id}/edit?tab=1\"" |> Code.string_to_quoted!() |> Routes.segments()

      assert [%{path: "/posts/:id/edit"}] = Routes.matching(routes, sigil_path)
      assert [%{path: "/files/*path"}] = Routes.matching(routes, ["files", "a", "b"])
      assert [] = Routes.matching(routes, ["missing"])
      assert :error = Routes.segments({:path, [], nil})
    end

    test "a plain-string interpolation spans any number of segments" do
      routes = [
        %{path: "/projects/:id"},
        %{path: "/projects/:id/streams/:stream_id/requirements"},
        %{path: "/requirements"},
        %{path: "/projects"}
      ]

      {:ok, segments} =
        "\"\#{stream_path(socket)}/requirements\""
        |> Code.string_to_quoted!()
        |> Routes.segments()

      assert [:any, "requirements"] = segments

      # The prefix can be empty, one segment (`/projects`), or several.
      assert [
               %{path: "/projects/:id"},
               %{path: "/projects/:id/streams/:stream_id/requirements"},
               %{path: "/requirements"}
             ] = Routes.matching(routes, segments)
    end
  end

  describe "SubscribedWithoutHandleInfo (SC601)" do
    test "fires on a subscribing LiveView without handle_info/2" do
      assert [diagnostic] = analyze(SubscribedWithoutHandleInfo, fixture())
      assert text_at(File.read!(@fixture), diagnostic.primary) == "Phoenix.PubSub.subscribe"
      assert diagnostic.message =~ "SoundcheckFixtures.SubscriberLive"
    end

    test "near miss: any handle_info/2 clause, even a catch-all" do
      catch_all = "test/support/fixtures/messages.ex"
      assert [] = analyze(SubscribedWithoutHandleInfo, [{catch_all, File.read!(catch_all)}])
    end
  end

  describe "NavigateAcrossLiveSession (SC702)" do
    test "fires on navigation into another live_session" do
      assert [_admin, _js, push] = diagnostics = analyze(NavigateAcrossLiveSession, fixture())
      texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

      assert texts == ["/admin", "Phoenix.LiveView.JS.navigate", "push_navigate"]

      assert push.message =~
               "from live_session :public goes to live_session :settings"
    end

    test "near miss: navigation within a session and ignored sessions" do
      diagnostics = analyze(NavigateAcrossLiveSession, fixture())
      refute Enum.any?(diagnostics, &(text_at(File.read!(@fixture), &1.primary) == "/about"))

      assert [_admin_link, _admin_js] =
               analyze(NavigateAcrossLiveSession, fixture(), ignore_sessions: [:settings])
    end
  end

  describe "LiveRouteWithoutAuthHook (SC402)" do
    test "fires on live routes without an auth hook, at the live declaration" do
      diagnostics = analyze(LiveRouteWithoutAuthHook, fixture())
      paths = Enum.map(diagnostics, &(&1.message |> String.split("`") |> Enum.at(1)))

      # `/users/:id` renders CounterLive, defined outside the analyzed sources.
      assert paths == [
               "/posts",
               "/posts/:id/edit",
               "/filters",
               "/",
               "/about",
               "/preview",
               "/members"
             ]

      assert Enum.all?(diagnostics, &(text_at(File.read!(@fixture), &1.primary) == "live"))
    end

    test "an auth hook that never halts protects nothing" do
      diagnostics = analyze(LiveRouteWithoutAuthHook, fixture())

      assert [members] = Enum.filter(diagnostics, &(&1.message =~ "`/members`"))

      assert members.message =~
               "runs only auth hooks that never halt (`SoundcheckFixtures.UserAuth` :mount_current_user)"
    end

    test "names the protected route of a LiveView also served without auth" do
      diagnostics = analyze(LiveRouteWithoutAuthHook, fixture())

      assert [preview] = Enum.filter(diagnostics, &(&1.message =~ "`/preview`"))
      assert preview.message =~ "also served at `/admin` behind live_session :admin"
    end

    test "near miss: session hooks, module hooks, and public_paths" do
      diagnostics =
        analyze(LiveRouteWithoutAuthHook, fixture(),
          public_paths: [~r/^\/(posts|users|filters|preview|members)/, "/"]
        )

      assert [diagnostic] = diagnostics
      assert diagnostic.message =~ "`/about`"
    end

    test ":auto stays silent when no route uses an auth hook" do
      router = """
      defmodule SoundcheckFixtures.NavigationRouter do
        use Phoenix.Router
      end

      defmodule SoundcheckFixtures.PatchingLive do
      end
      """

      assert [] = analyze(LiveRouteWithoutAuthHook, router)
      assert [_ | _] = analyze(LiveRouteWithoutAuthHook, router, auth_hooks: [MyApp.Auth])
    end
  end
end
