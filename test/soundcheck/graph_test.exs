defmodule Soundcheck.GraphTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Graph

  @tag :tmp_dir
  test "skips JavaScript files it cannot read", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "app.js"), "export const Hooks = {}\n")
    File.ln_s!(Path.join(tmp_dir, "missing.js"), Path.join(tmp_dir, "broken.js"))

    assert [%{file: file}] = Graph.build([], js_paths: [tmp_dir]).js
    assert Path.basename(file) == "app.js"
  end

  @tag :tmp_dir
  test "names an embedded template's owner after its file", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "pages.ex")

    source = """
    defmodule Demo.Pages do
      use Phoenix.Component
      embed_templates "pages/*"
    end
    """

    File.mkdir_p!(Path.join(tmp_dir, "pages"))
    File.write!(Path.join(tmp_dir, "pages/landing_page.html.heex"), "<h1>Welcome</h1>\n")

    {:ok, input} = Graph.Input.parse(file, source)
    graph = Graph.build([input], js_paths: [])

    assert [%{origin: :file, owner: {Demo.Pages, :landing_page}}] = graph.templates
    assert [_template] = Graph.templates_of(graph, Demo.Pages, :landing_page)
  end

  @tag :tmp_dir
  test "applies embed_templates' :root and :suffix options", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "web/pages.ex")

    source = """
    defmodule Demo.Pages do
      use Phoenix.Component
      embed_templates "*", root: "../templates", suffix: "_page"
    end
    """

    File.mkdir_p!(Path.join(tmp_dir, "templates"))
    template = Path.join(tmp_dir, "templates/about.html.heex")
    File.write!(template, "<h1>About</h1>\n")

    {:ok, input} = Graph.Input.parse(file, source)
    graph = Graph.build([input], js_paths: [])

    assert [%{file: ^template, owner: {Demo.Pages, :about_page}}] = graph.templates
  end

  test "a link's accessor raises until Graph.Link adds it" do
    graph = Graph.build([], js_paths: [])

    assert_raise ArgumentError, ~r/no :routes link/, fn -> Graph.routes(graph) end
    assert Graph.routes(Graph.Link.link(graph, [:routes])) == []
  end

  test "Graph.Link keeps the links a graph already holds" do
    graph = %{Graph.build([], js_paths: []) | routes: [:kept]}

    assert Graph.Link.link(graph, [:routes]).routes == [:kept]
  end

  test "build/2 rejects unknown options" do
    assert_raise ArgumentError, ~r/unknown keys \[:js_path\]/, fn ->
      Graph.build([], js_path: ["assets/js"])
    end
  end
end
