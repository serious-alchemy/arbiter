defmodule Arbiter.Worker.StateRedaction do
  @moduledoc """
  Masks the secrets an `Arbiter.Worker` holds wherever its state is printed (bd-akp9ae).

  A Worker's state carries every value its sessions were told to redact (a git token
  minted for a spawn, the provider token, the workspace's secret env values): each
  session's `redact_values`, the run's `archive_redact`, and the spawn the Worker keeps
  for a re-open (`meta[:claude_spawn]`), whose env and node request hold the values
  themselves. The output stream masks them already (`Arbiter.Redaction`). This masks
  them in what prints the state: a crash report and `:sys.get_status/1`
  (`Arbiter.Worker.format_status/1`), and `inspect/2` of the state, which a crash
  report also uses for the arguments of the frame that raised.
  """

  alias Arbiter.Redaction

  @doc """
  The values a Worker state's sessions were told to redact. Never raises: an
  `inspect/2` that raised would print the state unmasked instead.
  """
  @spec secrets(term()) :: [String.t()]
  def secrets(%{claude_sessions: sessions, archive_redact: archive})
      when is_map(sessions) and is_list(archive) do
    from_sessions =
      Enum.flat_map(sessions, fn
        {_handle, %{redact_values: values}} when is_list(values) -> values
        _ -> []
      end)

    Enum.uniq(archive ++ from_sessions)
  end

  def secrets(_state), do: []

  @doc "A Worker state with its own secrets (`secrets/1`) masked."
  @spec mask(struct()) :: struct()
  def mask(state), do: mask(state, secrets(state))

  @doc "`term` with each of `secrets` masked in every binary in it."
  @spec mask(term(), [String.t()]) :: term()
  def mask(term, []), do: term
  def mask(text, secrets) when is_binary(text), do: Redaction.redact(text, secrets)
  def mask([head | tail], secrets), do: [mask(head, secrets) | mask(tail, secrets)]

  def mask(tuple, secrets) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> mask(secrets) |> List.to_tuple()

  def mask(%{} = map, secrets),
    do: map |> Map.to_list() |> Map.new(fn {key, value} -> {key, mask(value, secrets)} end)

  def mask(other, _secrets), do: other
end
