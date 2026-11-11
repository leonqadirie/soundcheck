defmodule Soundcheck.Check.Warning.OptionalAttrWithoutDefaultTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.OptionalAttrWithoutDefault

  defp component(body) do
    """
    defmodule MyAppWeb.Components do
      use Phoenix.Component

    #{body}
    end
    """
  end

  test "fires on an optional attr without a default read as @key" do
    source =
      component(~S'''
        attr :icon, :string

        def badge(assigns), do: ~H"<span :if={@icon}>{@icon}</span>"
      ''')

    assert [diagnostic] = analyze(OptionalAttrWithoutDefault, source)

    assert diagnostic.message =~
             "`badge/1` reads `@icon`, but `attr :icon` is optional without a default"

    assert text_at(source, diagnostic.primary) == "@icon"
  end

  test "near miss: a default, required: true, a global attr, or assigns[:key]" do
    source =
      component(~S'''
        attr :icon, :string, default: nil
        attr :title, :string, required: true
        attr :rest, :global
        attr :badge, :string

        def badge(assigns), do: ~H"<span {@rest}>{@icon}{@title}{assigns[:badge]}</span>"
      ''')

    assert [] = analyze(OptionalAttrWithoutDefault, source)
  end

  test "near miss: the clause head matches the key; other clauses still count" do
    source =
      component(~S'''
        attr :href, :string
        attr :patch, :string

        def button(%{href: _} = assigns), do: ~H"<a href={@href}>go</a>"
        def button(%{patch: patch} = assigns) when not is_nil(patch), do: ~H"<a>{@patch}</a>"
        def button(assigns), do: ~H"<button>{@href}</button>"
      ''')

    assert [diagnostic] = analyze(OptionalAttrWithoutDefault, source)
    assert text_at(source, diagnostic.primary) == "@href"
    assert diagnostic.primary.start |> elem(0) == 9
  end

  test "near miss: the body assigns the key before rendering" do
    source =
      component(~S'''
        attr :icon, :string

        def badge(assigns) do
          assigns = assign_new(assigns, :icon, fn -> "dot" end)
          ~H"<span>{@icon}</span>"
        end
      ''')

    assert [] = analyze(OptionalAttrWithoutDefault, source)
  end
end
