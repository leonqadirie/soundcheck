defmodule Bench.Corpus do
  @moduledoc """
  Generates the synthetic LiveView project the benchmarks analyze.

  Each size gets its own namespace (`Bench.Small`, `Bench.Medium`,
  `Bench.Large`) under `corpus/<size>/`, so all sizes compile into the bench
  project side by side. A size holds a router with three live_sessions,
  LiveViews with `~H` or colocated templates, function component modules,
  an `embed_templates` layouts module, and JavaScript hooks registered with
  `LiveSocket`. About 5% of the sites carry each violation kind, so the
  checks report findings and exercise their diagnostic paths.

  The output is deterministic: every size seeds its own `:rand` state, and
  the generator draws only from fixed lists. `FINGERPRINT` holds a sha256 over
  every generated file, which the benchmark task compares before loading
  saved results.
  """

  # {live_views, component_modules, hooks, seed}
  @sizes [small: {20, 8, 5, 1}, medium: {100, 40, 25, 2}, large: {400, 150, 100, 3}]
  @sessions [:public, :app, :admin]
  @violation_rate 0.05
  # The first LiveViews and component modules each carry one violation kind,
  # so every size exercises every kind on top of the random 5%.
  @live_violations ~w(unhandled_event undefined_hook unguarded_subscribe missing_handle_info
                      missing_stream_id form_mismatch missing_handle_async foreign_patch)a
  @component_violations ~w(undeclared_attr optional_without_default)a
  @words ~w(alpha bravo cedar delta ember fable garnet harbor indigo juniper
            kestrel lantern meadow nectar orchid pepper quartz raven saffron
            timber umber velvet willow yarrow zephyr)

  @doc "The corpus sizes, smallest first."
  @spec sizes() :: [atom()]
  def sizes, do: Keyword.keys(@sizes)

  @doc """
  Writes the corpus into `Bench.corpus_dir/0` and returns its fingerprint.
  Unchanged files keep their mtime, so Mix recompiles only what changed.
  """
  @spec generate() :: String.t()
  def generate do
    files = Enum.flat_map(@sizes, fn {size, spec} -> size_files(size, spec) end)
    fingerprint = fingerprint(files)
    sync(Bench.corpus_dir(), [{"FINGERPRINT", fingerprint <> "\n"} | files])
    fingerprint
  end

  @doc "Reads the fingerprint of the generated corpus, or `nil` when none exists."
  @spec read_fingerprint() :: String.t() | nil
  def read_fingerprint do
    case File.read(Path.join(Bench.corpus_dir(), "FINGERPRINT")) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end

  defp fingerprint(files) do
    files
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {path, contents}, acc ->
      :crypto.hash_update(acc, [path, 0, contents, 0])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Writes files whose contents differ and deletes files the generator no
  # longer emits.
  defp sync(dir, files) do
    wanted = MapSet.new(files, fn {path, _contents} -> Path.join(dir, path) end)

    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(path),
        not MapSet.member?(wanted, path),
        do: File.rm!(path)

    for {path, contents} <- files do
      full = Path.join(dir, path)

      if File.read(full) != {:ok, contents} do
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, contents)
      end
    end
  end

  # ── One size ──

  defp size_files(size, {live_count, component_count, hook_count, seed}) do
    :rand.seed(:exsss, {seed, 17, 31})

    ns = "Bench.#{Macro.camelize(Atom.to_string(size))}"
    base = "#{size}/lib/#{size}"

    pages =
      for i <- 0..(live_count - 1) do
        session = Enum.at(@sessions, rem(i, length(@sessions)))

        %{
          i: i,
          module: "#{ns}.Live.Page#{i}Live",
          session: session,
          path: "/#{size}/#{session}/page#{i}"
        }
      end

    components =
      for j <- 0..(component_count - 1) do
        {"#{base}/components/widgets#{j}.ex", component_module(ns, j)}
      end

    lives = Enum.flat_map(pages, &live_files(&1, ns, base, pages, component_count, hook_count))
    hooks = for k <- 0..(hook_count - 1), do: {"#{size}/assets/js/hooks/hook#{k}.js", hook_js(k)}

    [
      {"#{base}/support.ex", support(ns)},
      {"#{base}/router.ex", router(ns, pages)},
      {"#{base}/layouts.ex", layouts(ns)},
      {"#{base}/layouts/app.html.heex", layout_app()},
      {"#{base}/layouts/flash.html.heex", layout_flash()},
      {"#{size}/assets/js/app.js", app_js(hook_count)}
    ] ++ components ++ lives ++ hooks
  end

  defp chance(p), do: :rand.uniform() < p
  # Draws from `:rand` even for seeded sites, so seeding a site leaves the
  # draws of every later site unchanged.
  defp violation?(kinds, kind, index) do
    random? = chance(@violation_rate)
    random? or Enum.at(kinds, index) == kind
  end

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  # ── Elixir ──

  defp support(ns) do
    """
    defmodule #{ns}.Repo do
      @moduledoc false
      def all(_source), do: [%{id: 1, name: "first"}, %{id: 2, name: "second"}]
      def get!(_source, id), do: %{id: id, name: "item"}
    end

    defmodule #{ns}.Auth do
      @moduledoc false
      import Phoenix.Component, only: [assign: 3]

      def on_mount(:default, _params, _session, socket),
        do: {:cont, assign(socket, :current_user, %{id: 1})}

      def on_mount(:admin, _params, _session, socket),
        do: {:cont, assign(socket, :current_user, %{id: 1, admin: true})}
    end
    """
  end

  defp router(ns, pages) do
    sessions =
      Enum.map_join(@sessions, "\n", fn session ->
        hook =
          case session do
            :public -> ""
            :app -> ", on_mount: [{#{ns}.Auth, :default}]"
            :admin -> ", on_mount: [{#{ns}.Auth, :admin}]"
          end

        routes =
          for %{session: ^session} = page <- pages,
              do: "    live \"#{page.path}\", #{page.module}, :index\n"

        "  live_session :#{session}#{hook} do\n#{routes}  end\n"
      end)

    """
    defmodule #{ns}.Router do
      @moduledoc false
      use Phoenix.Router

      import Phoenix.LiveView.Router

    #{sessions}end
    """
  end

  defp layouts(ns) do
    """
    defmodule #{ns}.Layouts do
      @moduledoc false
      use Phoenix.Component

      embed_templates "layouts/*"
    end
    """
  end

  defp layout_app do
    """
    <header class="app-header">
      <h1>{assigns[:page_title] || "Bench"}</h1>
    </header>
    <main>{@inner_content}</main>
    """
  end

  defp layout_flash do
    """
    <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" role="alert">
      {msg}
    </div>
    """
  end

  defp component_module(ns, j) do
    undeclared =
      if violation?(@component_violations, :undeclared_attr, j),
        do: "\n      <p>{@subtitle}</p>",
        else: ""

    {tone_attr, tone_read} =
      if violation?(@component_violations, :optional_without_default, j),
        do: {"\n  attr :tone, :string", " {@tone}"},
        else: {"\n  attr :tone, :string, default: \"neutral\"", ""}

    """
    defmodule #{ns}.Components.Widgets#{j} do
      @moduledoc false
      use Phoenix.Component

      attr :title, :string, required: true
      attr :class, :string, default: nil
      slot :inner_block

      def panel(assigns) do
        ~H\"\"\"
        <section class={@class}>
          <h2>{@title}</h2>#{undeclared}
          {render_slot(@inner_block)}
        </section>
        \"\"\"
      end

      attr :label, :string, required: true
      attr :count, :integer, default: 0#{tone_attr}

      def badge(assigns) do
        ~H\"\"\"
        <span class="badge">{@label}: {@count}#{tone_read}</span>
        \"\"\"
      end

      attr :rows, :list, default: []

      slot :col do
        attr :label, :string
      end

      def table(assigns) do
        ~H\"\"\"
        <table>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
          </tr>
          <tr :for={row <- @rows}>
            <td :for={col <- @col}>{render_slot(col, row)}</td>
          </tr>
        </table>
        \"\"\"
      end
    end
    """
  end

  # ── LiveViews ──

  defp live_files(page, ns, base, pages, component_count, hook_count) do
    spec = %{
      page: page,
      ns: ns,
      component: :rand.uniform(component_count) - 1,
      hook: if(chance(0.4), do: :rand.uniform(hook_count) - 1),
      on_mount?: chance(0.3),
      subscribe?: chance(0.5),
      form?: chance(0.6),
      stream?: chance(0.5),
      async?: chance(0.4),
      colocated?: chance(0.5),
      events: Enum.take_random(@words, 2 + :rand.uniform(4) - 1),
      navigate_to: pick(pages)
    }

    violations = Map.new(@live_violations, &{&1, violation?(@live_violations, &1, page.i)})

    # A violation that lives in a feature turns the feature on, so each kind
    # occurs at its full rate.
    spec = %{
      spec
      | subscribe?:
          spec.subscribe? or violations.unguarded_subscribe or violations.missing_handle_info,
        stream?: spec.stream? or violations.missing_stream_id,
        form?: spec.form? or violations.form_mismatch,
        async?: spec.async? or violations.missing_handle_async
    }

    spec = Map.merge(spec, Map.new(violations, fn {kind, on?} -> {:"#{kind}?", on?} end))

    file = "#{base}/live/page#{page.i}_live"
    template = live_template(spec, pages)

    if spec.colocated?,
      do: [{file <> ".ex", live_module(spec, nil)}, {file <> ".html.heex", template}],
      else: [{file <> ".ex", live_module(spec, template)}]
  end

  defp live_module(spec, template) do
    %{page: page, ns: ns} = spec

    sections = [
      "  use Phoenix.LiveView\n\n  import #{ns}.Components.Widgets#{spec.component}\n",
      if(spec.stream? or spec.async?, do: "  alias #{ns}.Repo\n"),
      if(spec.on_mount?, do: "\n  on_mount {#{ns}.Auth, :default}\n"),
      mount(spec),
      render(template),
      handlers(spec)
    ]

    "defmodule #{page.module} do\n  @moduledoc false\n#{Enum.join(Enum.reject(sections, &is_nil/1), "")}end\n"
  end

  defp mount(spec) do
    subscribe = "Phoenix.PubSub.subscribe(#{spec.ns}.PubSub, \"page:#{spec.page.i}\")"

    subscription =
      cond do
        not spec.subscribe? -> ""
        spec.unguarded_subscribe? -> "    #{subscribe}\n\n"
        true -> "    if connected?(socket), do: #{subscribe}\n\n"
      end

    pipeline =
      Enum.join(
        [
          "      |> assign(:page_title, \"Page #{spec.page.i}\")\n",
          "      |> assign(:count, 0)\n",
          if(spec.form?,
            do:
              "      |> assign(:form, to_form(%{\"name\" => \"\", \"email\" => \"\"}, as: :entry))\n"
          ),
          if(spec.stream?, do: "      |> stream(:items, Repo.all(:items))\n")
        ]
        |> Enum.reject(&is_nil/1)
      )

    """

      def mount(_params, _session, socket) do
    #{subscription}    socket =
          socket
    #{pipeline}
        {:ok, socket}
      end
    """
  end

  defp render(nil), do: ""

  defp render(template) do
    body = template |> String.split("\n", trim: true) |> Enum.map_join("\n", &("    " <> &1))

    """

      def render(assigns) do
        ~H\"\"\"
    #{body}
        \"\"\"
      end
    """
  end

  defp handlers(spec) do
    clauses =
      [
        "def handle_event(\"increment\", _params, socket),\n  do: {:noreply, update(socket, :count, &(&1 + 1))}",
        for(
          word <- spec.events,
          do:
            "def handle_event(\"toggle_#{word}\", _params, socket),\n  do: {:noreply, assign(socket, :count, 0)}"
        ),
        if(spec.stream?, do: delete_handler()),
        if(spec.form?, do: form_handlers(spec)),
        if(spec.async?,
          do:
            "def handle_event(\"refresh\", _params, socket),\n  do: {:noreply, start_async(socket, :reload, fn -> Repo.all(:items) end)}"
        ),
        if(spec.hook != nil, do: hook_handler(spec.hook)),
        if(spec.async? and not spec.missing_handle_async?, do: async_handlers(spec)),
        if(spec.subscribe? and not spec.missing_handle_info?,
          do:
            "def handle_info({:updated, count}, socket), do: {:noreply, assign(socket, :count, count)}"
        )
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    Enum.map_join(clauses, "", fn clause ->
      "\n" <> (clause |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))) <> "\n"
    end)
  end

  defp delete_handler do
    """
    def handle_event("delete", %{"id" => id}, socket) do
      item = Repo.get!(:items, id)
      {:noreply, stream_delete(socket, :items, item)}
    end\
    """
  end

  defp form_handlers(spec) do
    field = if spec.form_mismatch?, do: "nickname", else: "name"

    [
      "def handle_event(\"validate\", %{\"entry\" => params}, socket),\n  do: {:noreply, assign(socket, :form, to_form(params, as: :entry))}",
      "def handle_event(\"save\", %{\"entry\" => %{\"#{field}\" => name}}, socket),\n  do: {:noreply, assign(socket, :page_title, name)}"
    ]
  end

  defp hook_handler(k) do
    "def handle_event(\"hook#{k}:ping\", _params, socket),\n  do: {:noreply, push_event(socket, \"hook#{k}:flash\", %{})}"
  end

  defp async_handlers(spec) do
    ok =
      if spec.stream?,
        do: "stream(socket, :items, items, reset: true)",
        else: "assign(socket, :count, length(items))"

    [
      "def handle_async(:reload, {:ok, items}, socket), do: {:noreply, #{ok}}",
      "def handle_async(:reload, {:exit, _reason}, socket), do: {:noreply, socket}"
    ]
  end

  defp live_template(spec, pages) do
    patch_target =
      if spec.foreign_patch?,
        do: pick(pages -- [spec.page]).path,
        else: spec.page.path <> "?tab=details"

    lines =
      [
        "<.panel title={@page_title}>",
        "  <p>Count: {@count}</p>",
        "  <.badge label=\"count\" count={@count} />",
        "  <button phx-click=\"increment\">+</button>",
        for(word <- spec.events, do: "  <button phx-click=\"toggle_#{word}\">#{word}</button>"),
        if(spec.async?, do: "  <button phx-click=\"refresh\">Refresh</button>"),
        if(spec.unhandled_event?, do: "  <button phx-click=\"archive\">Archive</button>"),
        if(spec.stream?, do: stream_block(spec)),
        if(spec.form?, do: form_block()),
        if(spec.hook != nil,
          do: "  <div id=\"hook-#{spec.page.i}\" phx-hook=\"Hook#{spec.hook}\"></div>"
        ),
        if(spec.undefined_hook?,
          do: "  <div id=\"legacy-#{spec.page.i}\" phx-hook=\"LegacyChart\"></div>"
        ),
        "  <.link patch=\"#{patch_target}\">Details</.link>",
        "  <.link navigate=\"#{spec.navigate_to.path}\">Next</.link>",
        "</.panel>"
      ]

    lines |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join("\n") |> Kernel.<>("\n")
  end

  defp stream_block(spec) do
    id = if spec.missing_stream_id?, do: "", else: " id={dom_id}"

    [
      "  <div id=\"items\" phx-update=\"stream\">",
      "    <div :for={{dom_id, item} <- @streams.items}#{id}>",
      "      {item.name}",
      "      <button phx-click=\"delete\" phx-value-id={item.id}>Delete</button>",
      "    </div>",
      "  </div>"
    ]
  end

  defp form_block do
    [
      "  <.form for={@form} phx-change=\"validate\" phx-submit=\"save\">",
      "    <input type=\"text\" name={@form[:name].name} value={@form[:name].value} phx-debounce=\"300\" />",
      "    <input type=\"email\" name={@form[:email].name} value={@form[:email].value} />",
      "    <button type=\"submit\">Save</button>",
      "  </.form>"
    ]
  end

  # ── JavaScript ──

  defp hook_js(k) do
    """
    export default {
      Hook#{k}: {
        mounted() {
          this.pushEvent("hook#{k}:ping", {})
          this.handleEvent("hook#{k}:flash", () => this.el.classList.add("flash"))
        }
      }
    }
    """
  end

  defp app_js(hook_count) do
    imports =
      Enum.map_join(0..(hook_count - 1), "\n", &"import Hook#{&1} from \"./hooks/hook#{&1}\"")

    spreads = Enum.map_join(0..(hook_count - 1), ", ", &"...Hook#{&1}")

    """
    import {Socket} from "phoenix"
    import {LiveSocket} from "phoenix_live_view"
    #{imports}

    new LiveSocket("/live", Socket, {hooks: {#{spreads}}})
    """
  end
end
