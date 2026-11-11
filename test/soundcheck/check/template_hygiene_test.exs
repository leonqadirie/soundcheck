defmodule Soundcheck.Check.TemplateHygieneTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Design.ClickOnNonInteractiveElement
  alias Soundcheck.Check.Refactor.ChangeWithoutDebounce
  alias Soundcheck.Check.Refactor.ExpensiveCallInTemplate
  alias Soundcheck.Check.Refactor.FormForChangeset
  alias Soundcheck.Check.Warning.FormWithoutRecovery
  alias Soundcheck.Check.Warning.HookWithoutId
  alias Soundcheck.Check.Warning.InvalidLiveComponent
  alias Soundcheck.Check.Warning.InvalidLiveRender
  alias Soundcheck.Check.Warning.LiteralLiveComponentIdInLoop

  defp live(template) do
    """
    defmodule MyAppWeb.PostLive do
      use MyAppWeb, :live_view
      alias MyApp.Repo

      def render(assigns) do
        ~H\"\"\"
    #{template}
        \"\"\"
      end
    end
    """
  end

  defp texts(source, diagnostics), do: Enum.map(diagnostics, &text_at(source, &1.primary))

  describe "ExpensiveCallInTemplate (SC309)" do
    test "fires on repo, HTTP, and sorting calls, through aliases" do
      source =
        live(~S|    <p>{Repo.aggregate(Post, :count)} {Enum.sort_by(@posts, & &1.title)}</p>|)

      assert texts(source, analyze(ExpensiveCallInTemplate, source)) == [
               "Repo.aggregate",
               "Enum.sort_by"
             ]
    end

    test "near miss: assigns and cheap calls" do
      source = live(~S|    <p>{@post_count} {Enum.map(@posts, & &1.title)}</p>|)
      assert [] = analyze(ExpensiveCallInTemplate, source)
    end
  end

  describe "InvalidLiveComponent (SC311)" do
    test "fires on missing id or module, and on modules that are not LiveComponents" do
      source =
        live(~S"""
            <.live_component module={SoundcheckFixtures.EventsComponent} />
            <.live_component id="x" />
            <.live_component module={SoundcheckFixtures.EventsLive} id="x" />
            <.live_component module={SoundcheckFixtures.Policy} id="x" />
        """)

      messages = Enum.map(analyze(InvalidLiveComponent, source), & &1.message)

      assert [no_id, no_module, view, plain] = messages
      assert no_id =~ "has no `id`"
      assert no_module =~ "has no `module`"
      assert view =~ "`SoundcheckFixtures.EventsLive`, a LiveView"
      assert plain =~ "`SoundcheckFixtures.Policy`, which is not a LiveComponent"
    end

    test "near miss: complete calls, spreads, dynamic and unloadable modules" do
      source =
        live(~S"""
            <.live_component module={SoundcheckFixtures.EventsComponent} id="panel" />
            <.live_component {@component} />
            <.live_component module={MyAppWeb.NotCompiled} id="x" />
            <.live_component module={@module} id="x" />
        """)

      assert [] = analyze(InvalidLiveComponent, source)
    end
  end

  describe "InvalidLiveRender (SC312)" do
    test "fires on nested renders without an id or of a module that is not a LiveView" do
      source =
        live(~S"""
            {live_render(@socket, SoundcheckFixtures.EventsLive)}
            {live_render(@socket, SoundcheckFixtures.EventsLive, session: %{})}
            {live_render(@socket, SoundcheckFixtures.EventsComponent, id: "c")}
        """)

      assert [no_id, no_id_opts, component] =
               Enum.map(analyze(InvalidLiveRender, source), & &1.message)

      assert no_id =~ "passes no `:id`"
      assert no_id_opts =~ "passes no `:id`"
      assert component =~ "`SoundcheckFixtures.EventsComponent`, a LiveComponent"
    end

    test "near miss: an id, conn renders, and dynamic options" do
      source =
        live(~S"""
            {live_render(@socket, SoundcheckFixtures.EventsLive, id: "events")}
            {live_render(@conn, SoundcheckFixtures.EventsLive)}
            {live_render(@socket, SoundcheckFixtures.EventsLive, @opts)}
        """)

      assert [] = analyze(InvalidLiveRender, source)
    end
  end

  describe "LiteralLiveComponentIdInLoop (SC313)" do
    test "fires on literal ids under :for and inside for blocks" do
      source =
        live(~S"""
            <.live_component :for={post <- @posts} module={PostComponent} id="post" post={post} />
            <ul :for={post <- @posts}>
              <.live_component module={PostComponent} id={:row} post={post} />
            </ul>
            <%= for post <- @posts do %>
              <.live_component module={PostComponent} id={"card"} post={post} />
            <% end %>
        """)

      assert texts(source, analyze(LiteralLiveComponentIdInLoop, source)) == [
               "post",
               ":row",
               ~S|"card"|
             ]
    end

    test "near miss: ids from the loop item, and literal ids outside loops" do
      source =
        live(~S"""
            <.live_component :for={post <- @posts} module={PostComponent} id={"post-#{post.id}"} />
            <.live_component :for={post <- @posts} module={PostComponent} id={post.id} />
            <.live_component module={PostComponent} id="header" />
        """)

      assert [] = analyze(LiteralLiveComponentIdInLoop, source)
    end
  end

  describe "HookWithoutId (SC1003)" do
    test "fires on an HTML element with phx-hook and no id" do
      source = live(~S|    <div phx-hook="Chart"></div>|)
      assert texts(source, analyze(HookWithoutId, source)) == [~S|<div phx-hook="Chart">|]
    end

    test "near miss: an id, spread attributes, and component calls" do
      source =
        live(~S"""
            <div id={@id} phx-hook="Chart"></div>
            <div {@rest} phx-hook="Chart"></div>
            <.chart phx-hook="Chart" />
        """)

      assert [] = analyze(HookWithoutId, source)
    end

    test "reads keyword attributes; form input helpers carry the field's id" do
      file = "test/support/fixtures/keyword_attrs.ex"
      source = File.read!(file)

      assert [tag] = analyze(HookWithoutId, [{file, source}])
      assert text_at(source, tag.primary) == "tag"
      assert tag.message =~ "`<span>`"
    end
  end

  describe "FormForChangeset (SC801)" do
    test "fires on a form built from a changeset assign" do
      source = live(~S|    <.form for={@changeset} phx-change="validate"></.form>|)
      assert texts(source, analyze(FormForChangeset, source)) == ["@changeset"]
    end

    test "near miss: a form from to_form/2" do
      assert [] = analyze(FormForChangeset, live(~S|    <.form for={@form}></.form>|))
    end
  end

  describe "ChangeWithoutDebounce (SC802)" do
    test "fires on text-like inputs in a phx-change form" do
      source =
        live(~S'''
            <.form for={@form} phx-change="search">
              <.input field={@form[:q]} type="search" />
              <.input field={@form[:name]} />
              <textarea name="body"></textarea>
              <.input field={@form[:agree]} type="checkbox" />
            </.form>
        ''')

      assert [_search, _default_text, _textarea] = analyze(ChangeWithoutDebounce, source)
    end

    test "near miss: debounce on the input or the form, or no phx-change" do
      source =
        live(~S'''
            <.form for={@form} phx-change="search">
              <.input field={@form[:q]} type="search" phx-debounce="300" />
            </.form>
            <.form for={@form} phx-change="search" phx-debounce="blur"><.input field={@form[:a]} /></.form>
            <.form for={@form} phx-submit="save"><.input field={@form[:b]} /></.form>
        ''')

      assert [] = analyze(ChangeWithoutDebounce, source)
    end
  end

  describe "FormWithoutRecovery (SC803)" do
    test "fires on submit forms without an id or a recovery event" do
      source =
        live(~S'''
            <.form for={@form} phx-submit="save"><.input field={@form[:a]} /></.form>
            <.form for={@form} id="b" phx-submit="save"><.input field={@form[:b]} /></.form>
            <form phx-change="validate" phx-submit="save"><input name="c" /></form>
        ''')

      assert [both, change, id] = analyze(FormWithoutRecovery, source)
      assert both.message =~ "no `id` and no `phx-change`"
      assert change.message =~ "no `phx-change`,"
      assert id.message =~ "no `id`,"
      assert id.suggestion == "Give it a stable `id`."
    end

    test "near miss: recoverable, opted out, dynamic attrs, or no phx-submit" do
      source =
        live(~S'''
            <.form for={@form} id="a" phx-change="validate" phx-submit="save"></.form>
            <.form for={@form} id="b" phx-auto-recover="recover" phx-submit="save"></.form>
            <.form for={@form} phx-auto-recover="ignore" phx-submit="save"></.form>
            <.form for={@form} {@rest} phx-submit="save"></.form>
            <.form for={@form} phx-change="filter"></.form>
        ''')

      assert [] = analyze(FormWithoutRecovery, source)
    end
  end

  describe "ClickOnNonInteractiveElement (SC901)" do
    test "fires on phx-click on a div without role or keyboard support" do
      source = live(~S|    <div phx-click="open">Details</div>|)
      assert [diagnostic] = analyze(ClickOnNonInteractiveElement, source)
      assert text_at(source, diagnostic.primary) == ~S|<div phx-click="open">|
    end

    test "near miss: buttons, and divs with role, tabindex, or key handlers" do
      source =
        live(~S'''
            <button phx-click="open">a</button>
            <div phx-click="open" role="button" tabindex="0" phx-keydown="open" phx-key="Enter">b</div>
            <div phx-click="open" tabindex="0">c</div>
        ''')

      assert [] = analyze(ClickOnNonInteractiveElement, source)
    end
  end
end
