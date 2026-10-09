defmodule Arbiter.Parity.FieldExposure do
  @moduledoc """
  The field-exposure manifest, `priv/parity/field_exposure.exs` (parity audit
  P-30).

  The operation manifest (`Arbiter.Parity.Manifest`) says which MCP tool, `arb`
  verb and REST route reach an operation; this one says which *fields* of the
  four operations with large argument sets each of them takes:

    * `"issue/create"` / `"issue/update"` — `Issue :create` / `:update`
    * `"account/create"` / `"account/update"` — `ProviderAccount :create` /
      `:update`, with `quota_config` expanded into its keys
    * `"dispatch"` — the options `Arbiter.Worker.Dispatch.Params` accepts

  `governed/1` enumerates what the code takes, straight from the Ash action and
  the registries. Every such field must have an entry in the manifest, naming
  for each surface (`:mcp`, `:cli`, `:rest`) the name it goes by there, or why
  it is absent:

      "field" => :same                                  # exposed everywhere under its own name
      "field" => %{mcp: :same, cli: "flag", rest: :same}
      "field" => %{cli: {:none, "why"}, ...}            # one surface deliberately lacks it
      "field" => {:internal, "why"}                     # on no surface

  A surface name is `:same`, the string it goes by there (a CLI switch without
  its dashes, `"positional"` for an argument), or `{:none, reason}`. The guard
  tests (`field_exposure_test.exs` in each app) fail on an unclassified field, a
  stale entry, and any entry the surface contradicts.
  """

  @path "priv/parity/field_exposure.exs"
  @surfaces [:mcp, :cli, :rest]
  @operations ~w(issue/create issue/update account/create account/update dispatch)

  alias Arbiter.Accounts.Fields
  alias Arbiter.Tasks.{Issue, IssueFields}
  alias Arbiter.Worker.Dispatch.Params

  @type name :: :same | String.t() | {:none, String.t()}
  @type entry :: :same | {:internal, String.t()} | %{optional(atom()) => name()}

  @doc "The operations the manifest covers."
  @spec operations() :: [String.t()]
  def operations, do: @operations

  @doc "Read the manifest (a plain literal, parsed without being evaluated)."
  @spec load!() :: %{String.t() => %{String.t() => entry()}}
  def load! do
    path = Application.app_dir(:arbiter, @path)
    path |> File.read!() |> Code.string_to_quoted!(file: path) |> literal!()
  end

  @doc "Every field the code behind `op` takes, sorted."
  @spec governed(String.t()) :: [String.t()]
  def governed("issue/create"), do: issue_fields(:create)
  def governed("issue/update"), do: issue_fields(:update)
  def governed("account/create"), do: account_fields(:create)
  def governed("account/update"), do: account_fields(:update)

  def governed("dispatch"),
    do:
      Enum.sort(
        Enum.uniq(Params.accepted_keys(:dispatch, :rest) ++ Params.accepted_keys(:dispatch, :mcp))
      )

  @doc "The name `field` goes by on `surface`, or `nil` when it is absent there."
  @spec surface_name(entry(), String.t(), atom()) :: String.t() | nil
  def surface_name({:internal, _}, _field, _surface), do: nil
  def surface_name(:same, field, _surface), do: field

  def surface_name(%{} = entry, field, surface) do
    case Map.get(entry, surface) do
      :same -> field
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  @doc """
  What `op`'s surface `surface` actually takes, as a list of names, or `nil`
  when the code under that surface is not visible from this app (`:cli`).
  """
  @spec exposed(String.t(), atom()) :: [String.t()] | nil
  def exposed("issue/create", :mcp), do: mcp_props("ticket_create")
  def exposed("issue/update", :mcp), do: mcp_props("ticket_update")
  def exposed("issue/create", :rest), do: IssueFields.create_fields()
  def exposed("issue/update", :rest), do: IssueFields.update_fields()
  def exposed("account/create", :mcp), do: []
  def exposed("account/update", :mcp), do: account_mcp()
  def exposed("account/create", :rest), do: account_rest(:create)
  def exposed("account/update", :rest), do: account_rest(:update)
  def exposed("dispatch", :mcp), do: Params.accepted_keys(:dispatch, :mcp)
  def exposed("dispatch", :rest), do: Params.accepted_keys(:dispatch, :rest)
  def exposed(_op, :cli), do: nil

  @doc "Structural problems with a loaded manifest, as readable strings."
  @spec problems(term()) :: [String.t()]
  def problems(manifest) when is_map(manifest) do
    unknown_ops =
      for op <- Map.keys(manifest), op not in @operations, do: "unknown operation #{inspect(op)}"

    unknown_ops ++
      for {op, fields} <- manifest,
          is_map(fields),
          {field, entry} <- fields,
          p <- entry_problems(entry) do
        "#{op} / #{field}: #{p}"
      end
  end

  def problems(_), do: ["manifest must be a map of operation => fields"]

  @doc "Failure message for fields the code takes that the manifest does not classify."
  @spec unclassified_message(String.t(), [String.t()]) :: String.t()
  def unclassified_message(op, fields) do
    """
    #{op} takes field(s) the field-exposure manifest does not classify: #{Enum.join(fields, ", ")}.
    Add each to apps/arbiter/#{@path} under "#{op}": either expose it on every surface
    (`:same`, or a per-surface name / {:none, reason}), or mark it {:internal, reason} when it is
    deliberately on no surface (e.g. ReviewPatrol state). Then wire the surfaces the entry names.
    """
  end

  @doc "Failure message for manifest entries naming a field the code no longer takes."
  @spec stale_message(String.t(), [String.t()]) :: String.t()
  def stale_message(op, fields) do
    "#{@path} classifies #{op} field(s) the code no longer takes: #{Enum.join(fields, ", ")}. Remove them."
  end

  # ---- enumeration ----------------------------------------------------------

  # Everything the Ash action takes (accepted attributes and arguments) plus the
  # REST allow-list, which also names edits that are not action inputs
  # (`append_notes`, `add_permissions`, ...).
  defp issue_fields(action) do
    a = Ash.Resource.Info.action(Issue, action)

    names = Enum.map(a.accept ++ Enum.map(a.arguments, & &1.name), &Atom.to_string/1)
    Enum.sort(Enum.uniq(names ++ IssueFields.allowed(action)))
  end

  defp account_fields(phase) do
    a = Ash.Resource.Info.action(Arbiter.Accounts.ProviderAccount, phase)
    names = Enum.map(a.accept, &Atom.to_string/1) ++ Fields.names(phase)

    names
    |> Enum.reject(&(&1 == "quota_config"))
    |> Enum.concat(Fields.quota_keys())
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp account_rest(phase),
    do:
      Enum.sort(Enum.reject(Fields.names(phase), &(&1 == "quota_config")) ++ Fields.quota_keys())

  defp account_mcp do
    props = mcp_props("account_set")
    nested = Fields.quota_keys()
    Enum.sort(Enum.reject(props, &(&1 in ["ref", "quota_config"])) ++ nested)
  end

  defp mcp_props(tool) do
    Arbiter.MCP.Catalog.all()
    |> Enum.find(&(&1.name == tool))
    |> get_in([:input_schema, "properties"])
    |> Map.keys()
    |> Enum.sort()
  end

  # ---- manifest reading -----------------------------------------------------

  defp entry_problems(:same), do: []
  defp entry_problems({:internal, why}), do: reason_problems(why)

  defp entry_problems(%{} = entry) do
    missing = for s <- @surfaces, not Map.has_key?(entry, s), do: "no #{s} cell"
    extra = for s <- Map.keys(entry), s not in @surfaces, do: "unknown surface #{inspect(s)}"
    cells = for {_s, name} <- entry, p <- name_problems(name), do: p
    missing ++ extra ++ cells
  end

  defp entry_problems(other), do: ["bad entry #{inspect(other)}"]

  defp name_problems(:same), do: []
  defp name_problems(name) when is_binary(name) and name != "", do: []
  defp name_problems({:none, why}), do: reason_problems(why)
  defp name_problems(other), do: ["bad surface name #{inspect(other)}"]

  defp reason_problems(why) when is_binary(why) and why != "", do: []
  defp reason_problems(_), do: ["a ruling needs a non-empty reason"]

  defp literal!({:%{}, _, pairs}), do: Map.new(pairs, fn {k, v} -> {literal!(k), literal!(v)} end)
  defp literal!({:{}, _, elems}), do: elems |> Enum.map(&literal!/1) |> List.to_tuple()
  defp literal!({a, b}), do: {literal!(a), literal!(b)}
  defp literal!(list) when is_list(list), do: Enum.map(list, &literal!/1)
  defp literal!(lit) when is_binary(lit) or is_atom(lit) or is_number(lit), do: lit

  defp literal!(other),
    do: raise(ArgumentError, "#{@path} must be a plain literal, found #{Macro.to_string(other)}")
end
