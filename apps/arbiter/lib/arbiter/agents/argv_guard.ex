defmodule Arbiter.Agents.ArgvGuard do
  @moduledoc """
  Pre-exec guard for the per-argument size limit (bd-2idusd).

  Linux caps each execve() argv element at `MAX_ARG_STRLEN` (131 072 bytes).
  An element over it makes exec() fail with E2BIG before the child runs, which
  surfaces as a bare exit 7 with no output. Adapters route oversize prompts
  through stdin; this guard is the backstop that turns any element that still
  slips through into a descriptive error.
  """

  @max_arg_strlen 131_072

  @doc "Linux's per-argument byte limit."
  @spec max_arg_strlen() :: pos_integer()
  def max_arg_strlen, do: @max_arg_strlen

  @doc "`:ok`, or the first element over the limit as `{:argv_element_too_large, index, bytes, limit}`."
  @spec check([term()]) ::
          :ok
          | {:error, {:argv_element_too_large, non_neg_integer(), pos_integer(), pos_integer()}}
  def check(argv) when is_list(argv) do
    argv
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn
      {el, idx} when is_binary(el) and byte_size(el) > @max_arg_strlen ->
        {:error, {:argv_element_too_large, idx, byte_size(el), @max_arg_strlen}}

      _ ->
        nil
    end)
  end

  @doc "Human-readable form of a `check/1` error."
  @spec message({:argv_element_too_large, non_neg_integer(), pos_integer(), pos_integer()}) ::
          String.t()
  def message({:argv_element_too_large, idx, bytes, limit}) do
    "refusing to exec: argv element #{idx} is #{bytes} bytes, over Linux's MAX_ARG_STRLEN " <>
      "limit of #{limit} bytes (exec would fail with E2BIG, exit 7); the adapter must " <>
      "deliver this content over stdin or a file"
  end
end
