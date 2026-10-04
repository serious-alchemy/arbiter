defmodule Arbiter.Extensions do
  @moduledoc """
  The install-global registry of seam implementations (`docs/pro-extension-seams.md` §4.4).

  Every dispatcher that used to hold a closed `@adapters` map
  (`Arbiter.Agents`, `Trackers`, `Mergers`, `Agents.Routing`,
  `Sessions.Provider`, `MCP.AgentConfig`, `Quota`,
  `Quota.Gate.Snapshot`) reads its map from here
  instead. The registry is the union of `Arbiter.Extensions.Core` and every
  module in `config :arbiter, :extensions`; see `Arbiter.Extension`.

  ## Registration is global, selection is per workspace

  Nothing here knows about workspaces. A dispatcher looks the workspace's
  configured key up in `registry/1` *when it is called*, so two workspaces in
  one install resolve different implementations of the same seam, and an
  extension that is uninstalled simply stops resolving.

  ## Boot

  `load!/0` runs from `Arbiter.Application.start/2`, before any supervised
  consumer starts. It validates each contribution, raises on any problem
  (an install with a broken extension should not come up half-registered), and
  publishes the merged maps in `:persistent_term`, so a lookup on the dispatch
  path is a single term read. A lookup before `load!/0` has run (a `mix run
  --no-start` script) loads lazily.
  """

  alias Arbiter.Extensions.Core

  @seams %{
    agent: Arbiter.Agents.Agent,
    tracker: Arbiter.Trackers.Tracker,
    merger: Arbiter.Mergers.Merger,
    routing_policy: Arbiter.Agents.Routing.Policy,
    quota_gate: Arbiter.Quota.Gate,
    session_provider: Arbiter.Sessions.Provider,
    mcp_agent_config: Arbiter.MCP.AgentConfig,
    quota_snapshot: Arbiter.Quota.Gate.Snapshot.Source
  }

  @pt_key {__MODULE__, :state}

  @typep state :: %{
           extensions: [module()],
           registry: %{Arbiter.Extension.seam() => %{atom() => module()}},
           order: %{Arbiter.Extension.seam() => [atom()]},
           mcp_tools: [map()]
         }

  @doc "The seam names, in a stable order."
  @spec seams() :: [Arbiter.Extension.seam()]
  def seams, do: @seams |> Map.keys() |> Enum.sort()

  @doc "The behaviour a module contributed to `seam` must implement."
  @spec behaviour(Arbiter.Extension.seam()) :: module()
  def behaviour(seam), do: Map.fetch!(@seams, seam)

  @doc """
  Build the registry from `Arbiter.Extensions.Core` plus the extensions in
  `config :arbiter, :extensions`, and publish it. Raises `ArgumentError` on an
  invalid extension, leaving any previously published registry untouched.
  """
  @spec load!() :: :ok
  def load!, do: load!(Application.get_env(:arbiter, :extensions, []))

  @doc """
  As `load!/0`, with an explicit extension list instead of the app env.
  """
  @spec load!([module()]) :: :ok
  def load!(extensions) when is_list(extensions) do
    :persistent_term.put(@pt_key, build!([Core | extensions]))
    :ok
  end

  @doc "The loaded extension modules, core first."
  @spec loaded() :: [module()]
  def loaded, do: state().extensions

  @doc "The `key (atom) => module` map for a seam: core's entries plus every extension's."
  @spec registry(Arbiter.Extension.seam()) :: %{atom() => module()}
  def registry(seam) when is_map_key(@seams, seam), do: Map.fetch!(state().registry, seam)

  @doc """
  The registered keys of a seam, as the strings a workspace config uses, in
  registration order (core first, then extensions in the order configured).
  """
  @spec keys(Arbiter.Extension.seam()) :: [String.t()]
  def keys(seam) when is_map_key(@seams, seam),
    do: state().order |> Map.fetch!(seam) |> Enum.map(&Atom.to_string/1)

  @doc """
  The module registered under `key` (a string or its atom) on `seam`.

  A string that names no registered key resolves to `:error` without creating
  an atom.
  """
  @spec fetch(Arbiter.Extension.seam(), String.t() | atom() | nil) :: {:ok, module()} | :error
  def fetch(seam, key) when is_atom(key) and not is_nil(key),
    do: Map.fetch(registry(seam), key)

  def fetch(seam, key) when is_binary(key) do
    Enum.find_value(registry(seam), :error, fn {k, mod} ->
      if Atom.to_string(k) == key, do: {:ok, mod}
    end)
  end

  def fetch(_seam, _key), do: :error

  @doc "The MCP tools contributed by extensions (the optional `mcp_tools/0` callback)."
  @spec mcp_tools() :: [map()]
  def mcp_tools, do: state().mcp_tools

  # ---- internals -----------------------------------------------------------

  @spec state() :: state()
  defp state do
    case :persistent_term.get(@pt_key, nil) do
      nil ->
        load!()
        :persistent_term.get(@pt_key)

      state ->
        state
    end
  end

  defp build!(extensions) do
    registry =
      extensions
      |> Enum.flat_map(fn ext -> Enum.map(contributions!(ext), &{ext, &1}) end)
      |> Enum.reduce(empty_registry(), &register!/2)

    %{
      extensions: extensions,
      registry: Map.new(registry, fn {seam, {map, _order}} -> {seam, map} end),
      order: Map.new(registry, fn {seam, {_map, order}} -> {seam, Enum.reverse(order)} end),
      mcp_tools: mcp_tools!(extensions)
    }
  end

  defp empty_registry, do: Map.new(@seams, fn {seam, _} -> {seam, {%{}, []}} end)

  defp contributions!(ext) do
    unless Code.ensure_loaded?(ext) and function_exported?(ext, :contributions, 0) do
      raise ArgumentError,
            "#{inspect(ext)} is not an Arbiter.Extension (module not loaded or " <>
              "contributions/0 not exported)"
    end

    ext.contributions()
  end

  defp tools(ext) do
    if function_exported?(ext, :mcp_tools, 0), do: ext.mcp_tools(), else: []
  end

  @tool_tiers [:worker, :coordinator]

  # Validates every contributed tool and rejects a name already taken by a core
  # tool (or deprecated alias) or by an earlier extension: additive-only.
  defp mcp_tools!(extensions) do
    taken =
      MapSet.new(Arbiter.MCP.Catalog.all(), & &1.name)
      |> MapSet.union(MapSet.new(Map.keys(Arbiter.MCP.Catalog.legacy_aliases())))

    extensions
    |> Enum.flat_map(fn ext -> Enum.map(tools(ext), &{ext, &1}) end)
    |> Enum.reduce({[], taken}, fn {ext, tool}, {acc, names} ->
      check_tool!(ext, tool)

      if MapSet.member?(names, tool.name) do
        raise ArgumentError,
              "#{inspect(ext)} contributes MCP tool #{inspect(tool.name)}, which is " <>
                "already registered; an extension can add tools but never shadow one"
      end

      {[tool | acc], MapSet.put(names, tool.name)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp check_tool!(ext, %{name: name, description: d, input_schema: s, tiers: tiers, handler: h})
       when is_binary(name) and name != "" and is_binary(d) and is_map(s) and is_list(tiers) and
              is_function(h, 2) do
    if tiers == [] or not Enum.all?(tiers, &(&1 in @tool_tiers)) do
      raise ArgumentError,
            "#{inspect(ext)} MCP tool #{inspect(name)} has tiers #{inspect(tiers)}; " <>
              "expected a non-empty subset of #{inspect(@tool_tiers)}"
    end
  end

  defp check_tool!(ext, bad) do
    raise ArgumentError,
          "#{inspect(ext)}.mcp_tools/0 returned #{inspect(bad)}; expected a map with " <>
            "name, description, input_schema, tiers and a 2-arity handler"
  end

  defp register!({ext, {seam, key, mod}}, registry) when is_binary(key) do
    behaviour = behaviour!(ext, seam)
    check_callbacks!(ext, seam, key, mod, behaviour)

    atom = key_atom(key)

    {map, order} = Map.fetch!(registry, seam)

    if Map.has_key?(map, atom) do
      raise ArgumentError,
            "#{inspect(ext)} contributes #{inspect(seam)} key #{inspect(key)}, which is " <>
              "already registered to #{inspect(map[atom])}; an extension " <>
              "can add keys but never shadow one"
    end

    Map.put(registry, seam, {Map.put(map, atom, mod), [atom | order]})
  end

  defp register!({ext, bad}, _registry) do
    raise ArgumentError,
          "#{inspect(ext)}.contributions/0 returned #{inspect(bad)}; " <>
            "expected {seam, key :: String.t(), module}"
  end

  # Extension keys come from the operator's own release config, not from
  # request input, and the set is fixed at boot.
  # sobelow_skip ["DOS.StringToAtom"]
  defp key_atom(key), do: String.to_atom(key)

  defp behaviour!(ext, seam) do
    case Map.fetch(@seams, seam) do
      {:ok, behaviour} ->
        behaviour

      :error ->
        raise ArgumentError,
              "#{inspect(ext)} contributes to unknown seam #{inspect(seam)} " <>
                "(known: #{inspect(seams())})"
    end
  end

  defp check_callbacks!(ext, seam, key, mod, behaviour) do
    unless is_atom(mod) and Code.ensure_loaded?(mod) do
      raise ArgumentError,
            "#{inspect(ext)} contributes #{inspect(seam)} #{inspect(key)} as " <>
              "#{inspect(mod)}, which is not a loaded module"
    end

    {:module, _} = Code.ensure_loaded(behaviour)

    required =
      behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)

    missing = Enum.reject(required, fn {fun, arity} -> function_exported?(mod, fun, arity) end)

    if missing != [] do
      listed = Enum.map_join(missing, ", ", fn {fun, arity} -> "#{fun}/#{arity}" end)

      raise ArgumentError,
            "#{inspect(mod)} (#{inspect(seam)} #{inspect(key)} from #{inspect(ext)}) does not " <>
              "implement #{inspect(behaviour)}: missing #{listed}"
    end
  end
end
