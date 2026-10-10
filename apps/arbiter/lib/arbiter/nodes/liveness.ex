defmodule Arbiter.Nodes.Liveness do
  @moduledoc """
  The node liveness thresholds and the pure rule that turns "seconds of
  silence" into a state (`docs/design/remote-workers.md` §10.1).

    * `hb_interval_s` — the node sends `hb` every 10 s (fixed).
    * `suspect_after_s` — silence after which the primary marks the node
      **suspect**: 30 s, or less when the fence is set below 40 s, so suspect
      always lands before the fence.
    * `fence_after_s` — silence after which the *agent* stops its containers
      (`nodes.fence_after_s`, default 60, bounded 30–90 s).
    * `lost_after_s` — silence after which the *primary* declares the node
      **lost** (`nodes.lost_after_s`, default `fence_after_s + 30`).

  * `restart_grace_s` — how long an agent with **no socket** keeps its runs
      after its last ack before it fences them (bd-4p1vui, §10.4.8): 180 s, twice
      the measured deploy, so a primary restart (which closes the socket) leaves
      them for a new Worker to adopt. Fixed.

  **Invariant: `fence_after_s < lost_after_s`.** By the time the primary
  re-dispatches a run elsewhere the old container is already stopped. It is
  enforced here, in `validate/2`, and the `nodes.*` settings refuse a value that
  would break it (`Arbiter.Settings`), so it cannot be configured away. It is the
  open-socket bound; with no socket the bound is `restart_grace_s`.
  """

  @enforce_keys [:hb_interval_s, :suspect_after_s, :fence_after_s, :lost_after_s]
  defstruct [:hb_interval_s, :suspect_after_s, :fence_after_s, :lost_after_s, :restart_grace_s]

  @type t :: %__MODULE__{
          hb_interval_s: pos_integer(),
          suspect_after_s: pos_integer(),
          fence_after_s: pos_integer(),
          lost_after_s: pos_integer(),
          restart_grace_s: pos_integer()
        }

  @type state :: :online | :suspect | :lost

  @hb_interval_s 10
  @default_suspect_after_s 30
  @default_fence_after_s 60
  @lost_slack_s 30
  @min_fence_after_s 30
  @max_fence_after_s 90
  @max_lost_after_s 3600
  @restart_grace_s 180

  @doc "The heartbeat interval in seconds (fixed)."
  @spec hb_interval_s() :: pos_integer()
  def hb_interval_s, do: @hb_interval_s

  @doc "How long an agent with no socket keeps its runs (bd-4p1vui, §10.4.8)."
  @spec restart_grace_s() :: pos_integer()
  def restart_grace_s, do: @restart_grace_s

  @doc "The fence used when `nodes.fence_after_s` is not set."
  @spec default_fence_after_s() :: pos_integer()
  def default_fence_after_s, do: @default_fence_after_s

  @doc "The smallest and largest `nodes.fence_after_s`."
  @spec fence_range() :: Range.t()
  def fence_range, do: @min_fence_after_s..@max_fence_after_s

  @doc "The largest `nodes.lost_after_s`."
  @spec max_lost_after_s() :: pos_integer()
  def max_lost_after_s, do: @max_lost_after_s

  @doc "The lost threshold that goes with `fence_after_s` when none is set."
  @spec default_lost_after_s(pos_integer()) :: pos_integer()
  def default_lost_after_s(fence_after_s), do: fence_after_s + @lost_slack_s

  @doc "The thresholds in force: the `nodes.*` settings over the defaults."
  @spec current() :: t()
  def current do
    fence = Arbiter.Settings.nodes_fence_after_s()
    lost = Arbiter.Settings.nodes_lost_after_s_override()

    case validate(fence || @default_fence_after_s, lost) do
      {:ok, t} -> t
      # A stored pair that no longer validates (a hand-edited row) must not
      # take liveness down: fall back to the defaults, which always hold.
      {:error, _} -> default()
    end
  end

  @doc "The defaults: 10 / 30 / 60 / 90 seconds."
  @spec default() :: t()
  def default do
    {:ok, t} = validate(@default_fence_after_s, nil)
    t
  end

  @doc """
  Check a `fence_after_s` / `lost_after_s` pair (`nil` lost = fence + 30) and
  build the thresholds. Errors: `:fence_out_of_range` (outside 30–90),
  `:fence_not_before_lost` (the invariant), `:lost_out_of_range` (over an hour).
  """
  @spec validate(term(), term()) ::
          {:ok, t()}
          | {:error, :fence_out_of_range | :fence_not_before_lost | :lost_out_of_range}
  def validate(fence, lost) do
    lost = if is_nil(lost) and is_integer(fence), do: default_lost_after_s(fence), else: lost

    cond do
      not (is_integer(fence) and fence in fence_range()) -> {:error, :fence_out_of_range}
      not (is_integer(lost) and lost <= @max_lost_after_s) -> {:error, :lost_out_of_range}
      fence >= lost -> {:error, :fence_not_before_lost}
      true -> {:ok, build(fence, lost)}
    end
  end

  @doc "Re-check a built struct (used by callers that take thresholds as an option)."
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{fence_after_s: fence, lost_after_s: lost}), do: validate(fence, lost)

  defp build(fence, lost) do
    %__MODULE__{
      hb_interval_s: @hb_interval_s,
      suspect_after_s: min(@default_suspect_after_s, fence - @hb_interval_s),
      fence_after_s: fence,
      lost_after_s: lost,
      restart_grace_s: @restart_grace_s
    }
  end

  @doc "The state for `silence_ms` milliseconds without a heartbeat."
  @spec classify(t(), non_neg_integer()) :: state()
  def classify(%__MODULE__{} = t, silence_ms) do
    cond do
      silence_ms >= t.lost_after_s * 1000 -> :lost
      silence_ms >= t.suspect_after_s * 1000 -> :suspect
      true -> :online
    end
  end

  @doc "Whether the agent has, by now, fenced itself (it stops its containers)."
  @spec fenced?(t(), non_neg_integer()) :: boolean()
  def fenced?(%__MODULE__{fence_after_s: fence}, silence_ms), do: silence_ms >= fence * 1000
end
