defmodule Arbiter.Extensions.RegisteredAtom do
  @moduledoc """
  An atom-valued persisted attribute whose legal values are the keys registered
  on an `Arbiter.Extensions` seam, instead of a compile-time `one_of` list
  (`docs/pro-extension-seams.md` §7 item 3).

      attribute :issue_type, Arbiter.Extensions.RegisteredAtom do
        constraints seam: :issue_type
      end

  An extension that contributes a key on the seam can therefore add a value
  without a core resource change or migration. Storage is unchanged from
  `:atom` (the atom's name, as text), so existing rows load as before.

  Input is validated against the registry when it is cast. Rows read back from
  storage are *not*: a value whose extension was later uninstalled still loads
  (as an atom), and the code that consumes it degrades the way
  `Arbiter.Trackers.adapter_for_workspace_type/2` does instead of the read failing.
  """

  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :string

  @impl true
  def constraints,
    do: [seam: [type: :atom, required: true, doc: "The `Arbiter.Extensions` seam."]]

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  # Ash casts each attribute's `default` while the resource compiles, before
  # `Arbiter.Extensions.Core` (and the adapters it names) exist to be loaded.
  # Nothing is persisted at that point, so the registry check is deferred to
  # runtime.
  def cast_input(value, constraints) when is_atom(value) or is_binary(value) do
    if Code.can_await_module_compilation?() do
      {:ok, to_atom(value)}
    else
      cast_registered(value, constraints)
    end
  end

  def cast_input(_value, _constraints), do: {:error, "is invalid"}

  defp cast_registered(value, constraints) do
    seam = Keyword.fetch!(constraints, :seam)

    case Arbiter.Extensions.fetch(seam, value) do
      {:ok, _mod} -> {:ok, to_atom(value)}
      :error -> {:error, message: invalid_message(seam), value: value}
    end
  end

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints) when is_atom(value), do: {:ok, value}
  def cast_stored(value, _constraints) when is_binary(value), do: {:ok, to_atom(value)}
  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def dump_to_native(_value, _constraints), do: :error

  @impl true
  def equal?(a, b), do: a == b

  defp invalid_message(seam),
    do:
      "is not a registered #{seam} (registered: #{Enum.join(Arbiter.Extensions.keys(seam), ", ")})"

  # Input reaches here only after `Arbiter.Extensions.fetch/2` matched a
  # registered key; a stored value from an uninstalled extension is the only
  # other source, and it was written by this app.
  # sobelow_skip ["DOS.StringToAtom"]
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)
  defp to_atom(value), do: value
end
