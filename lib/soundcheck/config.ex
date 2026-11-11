defmodule Soundcheck.Config do
  @moduledoc false
  # Reads soundcheck's settings from a project's `.credo.exs`, so
  # `mix soundcheck` runs checks with the same parameters as `mix credo`.
  #
  # Like Credo, it evaluates the file. From the selected config (`"default"`
  # unless named otherwise) it takes:
  #
  #   * soundcheck checks listed under `checks:`, either as a list or under
  #     `:enabled` and `:extra`: `{Check, params}` enables a check with those
  #     params, `{Check, false}` disables it;
  #   * the `Soundcheck` plugin's params, such as `js_paths`.

  defstruct checks: %{}, plugin: []

  @type t :: %__MODULE__{checks: %{module() => keyword() | false}, plugin: keyword()}

  @doc "Reads `path`; a missing file is an empty config."
  @spec read(Path.t(), String.t()) :: t()
  def read(path \\ ".credo.exs", name \\ "default") do
    if File.regular?(path) do
      {data, _binding} = Code.eval_file(path)
      from_data(data, name)
    else
      %__MODULE__{}
    end
  end

  @doc "Extracts soundcheck's settings from evaluated `.credo.exs` data."
  @spec from_data(map(), String.t()) :: t()
  def from_data(%{configs: configs}, name) when is_list(configs) do
    case Enum.find(configs, &(Map.get(&1, :name) == name)) do
      nil ->
        %__MODULE__{}

      config ->
        %__MODULE__{
          checks: checks(Map.get(config, :checks)),
          plugin: plugin(Map.get(config, :plugins, []))
        }
    end
  end

  def from_data(_data, _name), do: %__MODULE__{}

  @doc """
  Selects the checks to run: the defaults, plus checks the config enables,
  minus checks it disables.
  """
  @spec selected(t(), [module()]) :: [module()]
  def selected(%__MODULE__{checks: checks}, defaults) do
    enabled = for {check, params} <- checks, params != false, do: check
    disabled = for {check, false} <- checks, do: check
    Enum.uniq(defaults ++ enabled) -- disabled
  end

  @doc "The params the config sets for `check`, or `[]`."
  @spec params(t(), module()) :: keyword()
  def params(%__MODULE__{checks: checks}, check) do
    case Map.get(checks, check) do
      params when is_list(params) -> params
      _unset_or_disabled -> []
    end
  end

  defp checks(list) when is_list(list), do: soundcheck_entries(list)

  defp checks(%{} = map),
    do:
      soundcheck_entries(Map.get(map, :enabled, []) ++ Map.get(map, :extra, []))
      |> disable(Map.get(map, :disabled, []))

  defp checks(_none), do: %{}

  defp soundcheck_entries(entries) do
    for {check, params} <- entries, soundcheck_check?(check), into: %{}, do: {check, params}
  end

  defp disable(checks, disabled) do
    Enum.reduce(disabled, checks, fn
      {check, _params}, acc ->
        if soundcheck_check?(check), do: Map.put(acc, check, false), else: acc

      _other, acc ->
        acc
    end)
  end

  defp soundcheck_check?(check) when is_atom(check),
    do: match?(["Soundcheck", "Check" | _], Module.split(check))

  defp soundcheck_check?(_check), do: false

  defp plugin(plugins) do
    Enum.find_value(plugins, [], fn
      {Soundcheck, params} when is_list(params) -> params
      _other -> nil
    end)
  end
end
