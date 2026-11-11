defmodule Soundcheck.Elixir.ModuleIndexTest do
  use ExUnit.Case, async: true

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Elixir.ModuleIndex

  defp modules(source) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true, token_metadata: true)
    ModuleIndex.modules(ast, source, "lib/demo.ex")
  end

  test "infers kinds from use calls" do
    source = ~S"""
    defmodule MyAppWeb.PostLive.Index do
      use MyAppWeb, :live_view
    end

    defmodule MyAppWeb.Modal do
      use Phoenix.LiveComponent
    end

    defmodule MyAppWeb.CoreComponents do
      use Phoenix.Component
    end

    defmodule MyAppWeb.Router do
      use MyAppWeb, :router
    end

    defmodule MyApp.Accounts do
    end
    """

    assert Enum.map(modules(source), &{&1.name, &1.kind}) == [
             {MyAppWeb.PostLive.Index, :live_view},
             {MyAppWeb.Modal, :live_component},
             {MyAppWeb.CoreComponents, :component},
             {MyAppWeb.Router, :router},
             {MyApp.Accounts, :other}
           ]
  end

  test "resolves aliases, including multi-alias and as:" do
    source = ~S"""
    defmodule MyAppWeb.PostLive.Index do
      alias MyApp.Blog
      alias MyApp.Blog.{Post, Comment}
      alias MyAppWeb.CoreComponents, as: UI
      alias __MODULE__.Row
      import MyAppWeb.CoreComponents
    end
    """

    [module] = modules(source)

    assert module.aliases == %{
             Blog: MyApp.Blog,
             Post: MyApp.Blog.Post,
             Comment: MyApp.Blog.Comment,
             UI: MyAppWeb.CoreComponents,
             Row: MyAppWeb.PostLive.Index.Row
           }

    assert module.imports == [MyAppWeb.CoreComponents]
  end

  test "a nested module inherits the aliases its parent defines above it" do
    source = ~S"""
    defmodule MyAppWeb.Outer do
      alias Phoenix.LiveView, as: LV
      alias MyAppWeb.Hooks

      defmodule Inner do
        use LV
        on_mount Hooks.Auth
      end
    end
    """

    [_outer, inner] = modules(source)

    assert inner.name == MyAppWeb.Outer.Inner
    assert inner.kind == :live_view
    assert Enum.map(inner.uses, & &1.module) == [Phoenix.LiveView]
    assert Enum.map(inner.on_mount, & &1.module) == [MyAppWeb.Hooks.Auth]
    assert inner.aliases[:Hooks] == MyAppWeb.Hooks
  end

  test "a nested defmodule aliases its name for the modules after it" do
    source = ~S"""
    defmodule MyAppWeb.Outer do
      defmodule Hook do
      end

      defmodule Live do
        use Phoenix.LiveView
        on_mount Hook
      end
    end
    """

    [outer, _hook, live] = modules(source)

    assert Enum.map(live.on_mount, & &1.module) == [MyAppWeb.Outer.Hook]
    assert outer.aliases == %{Hook: MyAppWeb.Outer.Hook, Live: MyAppWeb.Outer.Live}
  end

  test "an alias applies only to the statements after it" do
    source = ~S"""
    defmodule MyAppWeb.Page do
      use LiveView
      alias Phoenix.LiveView
    end
    """

    [module] = modules(source)

    assert module.kind == :other
    assert Enum.map(module.uses, & &1.module) == [LiveView]
    assert module.aliases == %{LiveView: Phoenix.LiveView}
  end

  test "attaches attr and slot declarations to the next function" do
    source = ~S'''
    defmodule MyAppWeb.CoreComponents do
      use Phoenix.Component

      attr :title, :string, required: true
      attr :rest, :global
      slot :inner_block
      slot :action do
        attr :label, :string
      end

      def card(assigns) do
        ~H"""
        <div>{@title}</div>
        """
      end

      def helper(x), do: x

      attr :name, :string
      defp badge(assigns), do: ~H"<b>{@name}</b>"
    end
    '''

    [module] = modules(source)

    assert %{attrs: attrs, slots: slots} = module.components.card
    assert Enum.map(attrs, & &1.name) == [:title, :rest]
    assert Enum.map(slots, & &1.name) == [:inner_block, :action]
    assert hd(attrs).opts == [required: true]
    refute Map.has_key?(module.components, :helper)
    assert [%{name: :name}] = module.components.badge.attrs
  end

  test "records function clauses with heads, guards, and bodies" do
    source = ~S"""
    defmodule Demo do
      def handle_event("save", params, socket), do: {:noreply, socket}
      def handle_event(event, _params, socket) when event in ["a"], do: {:noreply, socket}
      defp go, do: :ok
    end
    """

    [module] = modules(source)
    [save, guarded] = module.functions[{:handle_event, 3}]

    assert %{kind: :def, args: ["save", _, _], guards: []} = save
    assert %{guards: [{:in, _, _}]} = guarded
    assert [%{kind: :defp, args: [], body: :ok}] = module.functions[{:go, 0}]
  end

  test "indexes nested modules and assigns templates to their owners" do
    source = ~S'''
    defmodule Outer do
      def render(assigns), do: ~H"<p></p>"

      defmodule Inner do
        def row(assigns), do: ~H"<tr></tr>"
      end
    end
    '''

    [outer, inner] = modules(source)

    assert inner.name == Outer.Inner
    assert [%{owner: {Outer, :render}}] = outer.templates
    assert [%{owner: {Outer.Inner, :row}}] = inner.templates
  end

  test "records embed_templates and the module span" do
    source = ~S"""
    defmodule MyAppWeb.Layouts do
      use MyAppWeb, :html
      embed_templates "layouts/*"
    end
    """

    [module] = modules(source)

    assert [%{pattern: "layouts/*", root: nil, suffix: "", line: 3, column: 3}] =
             module.embed_templates

    assert text_at(source, module.span) =~ ~r/\Adefmodule MyAppWeb.Layouts do.*end\z/s
  end

  test "records embed_templates options and skips calls it cannot read" do
    source = ~S"""
    defmodule MyAppWeb.Pages do
      use MyAppWeb, :html
      embed_templates "*", root: "../templates", suffix: "_page"
      embed_templates "cards/*", suffix: @suffix
      embed_templates pattern()
    end
    """

    [module] = modules(source)

    assert [%{pattern: "*", root: "../templates", suffix: "_page"}] = module.embed_templates
  end

  test "records on_mount hooks from live_session wrappers and on_mount calls" do
    source = ~S"""
    defmodule MyAppWeb.Router do
      use Phoenix.Router
      alias MyAppWeb.UserAuth

      scope "/", MyAppWeb do
        ash_authentication_live_session :app, on_mount: [{UserAuth, :required}, MyAppWeb.Nav] do
          live "/", HomeLive
        end
      end
    end

    defmodule MyAppWeb.HomeLive do
      use Phoenix.LiveView
      on_mount MyAppWeb.Nav
    end
    """

    [router, live] = modules(source)

    assert [
             %{module: MyAppWeb.UserAuth, arg: :required} = auth,
             %{module: MyAppWeb.Nav, arg: :default}
           ] = router.on_mount

    assert text_at(source, auth.span) == "UserAuth"
    assert [%{module: MyAppWeb.Nav, arg: :default}] = live.on_mount
  end

  test "resolves a leading __MODULE__ in a module name against the enclosing module" do
    source = "defmodule Parent do\n  defmodule __MODULE__.Child do\n  end\nend"
    assert [Parent, Parent.Child] = Enum.map(modules(source), & &1.name)

    assert [%{name: TopLevel}] = modules("defmodule __MODULE__.TopLevel do\nend")
  end

  test "keeps modules with non-literal names, without a name" do
    [module] = modules("defmodule unquote(name) do\nend")
    assert module.name == nil
  end
end
