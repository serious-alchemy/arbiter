defmodule Arbiter.Changes.ScrubAttributes do
  @moduledoc """
  Write-side UTF-8 guard for plain string attributes: invalid byte sequences
  in the listed `:fields` become U+FFFD before the row is stored, so one bad
  excerpt can never make the row unserializable (`Jason.EncodeError`).
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, opts, _context) do
    Enum.reduce(Keyword.fetch!(opts, :fields), changeset, fn field, cs ->
      case Changeset.fetch_change(cs, field) do
        {:ok, value} when is_binary(value) ->
          if String.valid?(value),
            do: cs,
            else: Changeset.force_change_attribute(cs, field, Arbiter.Text.scrub(value))

        _ ->
          cs
      end
    end)
  end
end
