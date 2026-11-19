defmodule Soundcheck.Analysis.LiveHosts do
  @moduledoc false
  # Which routed LiveViews can run another LiveView's code.
  #
  # LiveView validates a server `push_patch` against the root view the
  # router mounted, not against the module that calls it. A routed LiveView
  # runs another LiveView's code when it delegates its callbacks
  # (`socket.assigns.page.handle_event(event, params, socket)`) or nests it
  # (`live_render(@socket, Child)`): a nested LiveView forwards its patch
  # to the root process.
  #
  # A routed LiveView is a host of every module its macro-expanded function
  # bodies name, as the receiver of a remote call or as a bare atom. Only
  # direct references count. The hosts found are a lower bound: a host that
  # picks the module from a registry or from configuration names nothing.
  # They are also an over-approximation: a routed LiveView that only calls a
  # helper on the module counts as its host. Checks therefore use hosts to
  # stay silent or to report an unverifiable finding, and report a resolved
  # one only when it holds whichever LiveView is the root.

  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Graph
  alias Soundcheck.Once

  @enforce_keys [:routed, :by_module, :unreadable]
  defstruct [:routed, :by_module, :unreadable]

  @type t :: %__MODULE__{
          routed: MapSet.t(module()),
          by_module: %{module() => [module()]},
          unreadable: MapSet.t(module())
        }

  @doc """
  Infers the hosts of every module that a routed LiveView of `graph` names.
  `unreadable` holds the routed LiveViews that load without debug info, whose
  references are unknown.
  """
  @spec infer(Graph.t()) :: t()
  def infer(%Graph{} = graph) do
    routed = graph |> MountHooks.routes() |> Enum.map(& &1.live_view) |> Enum.uniq()

    read = Enum.map(routed, &{&1, references(&1)})
    pairs = for {host, {:ok, modules}} <- read, module <- modules, do: {module, host}

    # A routed LiveView that does not load runs nothing, so only one that
    # loads without debug info counts as a possible host.

    %__MODULE__{
      routed: MapSet.new(routed),
      by_module:
        pairs
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {module, hosts} -> {module, Enum.sort(hosts)} end),
      unreadable: for({host, {:error, :no_debug_info}} <- read, into: MapSet.new(), do: host)
    }
  end

  @doc "Whether a live route renders `module`."
  @spec routed?(t(), module()) :: boolean()
  def routed?(%__MODULE__{routed: routed}, module), do: MapSet.member?(routed, module)

  @doc "The routed LiveViews that name `module`, sorted."
  @spec hosts(t(), module()) :: [module()]
  def hosts(%__MODULE__{by_module: by_module}, module), do: Map.get(by_module, module, [])

  @doc """
  The LiveViews that can be the root view while `module`'s code runs:
  `module` itself when a live route renders it, then its hosts.
  """
  @spec roots(t(), module()) :: [module()]
  def roots(%__MODULE__{} = hosts, module) do
    own = if routed?(hosts, module), do: [module], else: []
    own ++ hosts(hosts, module)
  end

  @doc "Whether `module` is a routed LiveView that loads without debug info."
  @spec unreadable?(t(), module()) :: boolean()
  def unreadable?(%__MODULE__{unreadable: unreadable}, module),
    do: MapSet.member?(unreadable, module)

  @doc """
  The modules that `module`'s expanded function bodies name, without
  `module` itself, or why its debug info cannot be read.
  """
  @spec references(module()) :: {:ok, MapSet.t(module())} | {:error, DebugInfo.error()}
  def references(module) do
    Once.run({__MODULE__, :references, module}, fn ->
      case DebugInfo.definitions(module) do
        {:ok, %DebugInfo.Info{definitions: definitions}} ->
          {:ok, definitions |> named_modules() |> MapSet.delete(module)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # Expanded code holds an alias as the module's atom.
  defp named_modules(definitions) do
    for {_name_arity, _kind, _meta, clauses} <- definitions,
        {_meta, _args, _guards, body} <- clauses,
        atom when is_atom(atom) <- Macro.prewalker(body),
        module?(atom),
        into: MapSet.new(),
        do: atom
  end

  defp module?(atom), do: match?("Elixir." <> _name, Atom.to_string(atom))
end
