defmodule Arbiter.Tasks.Issue.Changes.ScrubText do
  @moduledoc """
  Write-side UTF-8 guard: invalid byte sequences in the free-text fields (and
  the `append_notes` argument) are replaced with U+FFFD before they are stored,
  so one bad excerpt can never make a ticket unserializable.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @fields [:title, :description, :acceptance, :notes, :qa_notes, :deployment_notes]

  @impl true
  def change(changeset, _opts, _context) do
    # The paper-trail version snapshots params / casted inputs, so scrub those too.
    changeset = %{
      changeset
      | params: scrub_params(changeset.params),
        casted_attributes: scrub_params(changeset.casted_attributes),
        casted_arguments: scrub_params(changeset.casted_arguments)
    }

    changeset =
      Enum.reduce(@fields, changeset, fn field, cs ->
        case Changeset.fetch_change(cs, field) do
          {:ok, value} when is_binary(value) ->
            if String.valid?(value),
              do: cs,
              else: Changeset.force_change_attribute(cs, field, Arbiter.Text.scrub(value))

          _ ->
            cs
        end
      end)

    case Changeset.get_argument(changeset, :append_notes) do
      text when is_binary(text) ->
        if String.valid?(text),
          do: changeset,
          else: Changeset.set_argument(changeset, :append_notes, Arbiter.Text.scrub(text))

      _ ->
        changeset
    end
  end

  defp scrub_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_binary(v) -> {k, Arbiter.Text.scrub(v)}
      pair -> pair
    end)
  end
end
