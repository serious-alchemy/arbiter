defmodule Arbiter.NodeAgent.K8s.WatchStream do
  @moduledoc """
  The incremental decoder for a Kubernetes watch response (K3): newline-delimited
  JSON `{"type": ..., "object": ...}` events arriving in arbitrary chunks. Pure;
  `Arbiter.NodeAgent.K8s.Client.watch_pods/5` feeds it from the HTTP body stream.

  `feed/2` returns the events whose line is now complete and keeps the rest.
  A trailing partial line (the connection dropped mid-event) is never decoded: it
  stays in `pending/1` and the caller discards the decoder with the connection.

  Events: `{:added | :modified | :deleted | :bookmark, object}`, `{:error,
  status_object}` for an `ERROR` event (a `Status`, e.g. `code: 410`), and
  `{:bad_event, line}` for a line that is not a recognisable event.
  """

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}
  @type event ::
          {:added | :modified | :deleted | :bookmark | :error, map()} | {:bad_event, binary()}

  @types %{
    "ADDED" => :added,
    "MODIFIED" => :modified,
    "DELETED" => :deleted,
    "BOOKMARK" => :bookmark,
    "ERROR" => :error
  }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The undecoded tail: bytes after the last newline."
  @spec pending(t()) :: binary()
  def pending(%__MODULE__{buffer: buffer}), do: buffer

  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{buffer: buffer} = stream, chunk) do
    parts = String.split(buffer <> chunk, "\n")
    {complete, [rest]} = Enum.split(parts, -1)

    events = complete |> Enum.reject(&(&1 == "")) |> Enum.map(&decode/1)
    {events, %{stream | buffer: rest}}
  end

  defp decode(line) do
    with {:ok, %{"type" => type, "object" => object}} when is_map(object) <- Jason.decode(line),
         {:ok, tag} <- Map.fetch(@types, type) do
      {tag, object}
    else
      _ -> {:bad_event, line}
    end
  end
end
