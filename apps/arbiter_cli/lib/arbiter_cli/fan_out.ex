defmodule ArbiterCli.FanOut do
  @moduledoc """
  Client-side guard against `arb` fan-out. Every `arb` invocation boots a full
  BEAM (~42 MB), so a shell loop that backgrounds hundreds of them can exhaust
  RAM. On startup `arb` counts the *other* `arb` escript VMs running for the
  same user by reading `/proc` (no subprocess) and:

    * warns on stderr above `ARB_FANOUT_WARN` (default 16), pointing at
      `arb batch` and the bulk verbs;
    * refuses (exit 1) above `ARB_FANOUT_MAX` (default 64) unless
      `--force`, `--allow-fanout` or `ARB_ALLOW_FANOUT=1` is given.

  The check fails open: where `/proc` is unreadable (non-Linux, a hardened
  container) the count is 0.
  """

  alias ArbiterCli.Output

  @default_warn 16
  @default_max 64

  @doc "Run the guard for this invocation. Warns, or dies when over the ceiling."
  @spec enforce!(boolean()) :: :ok
  def enforce!(allow_flag? \\ false) do
    force? = allow_flag? or System.get_env("ARB_ALLOW_FANOUT") in ["1", "true"]
    count = Process.get(:bd2_fanout_count) || count_peers()

    case check(count, [force: force?] ++ thresholds(System.get_env())) do
      :ok -> :ok
      {:warn, msg} -> IO.puts(:stderr, "arb: warning: " <> msg)
      {:refuse, msg} -> Output.die(msg)
    end

    :ok
  end

  @doc "Classify `count` other `arb` VMs against `opts` (`:warn`, `:max`, `:force`)."
  @spec check(non_neg_integer(), keyword()) :: :ok | {:warn, String.t()} | {:refuse, String.t()}
  def check(count, opts) do
    warn = Keyword.get(opts, :warn, @default_warn)
    max = Keyword.get(opts, :max, @default_max)

    cond do
      count > max and not Keyword.get(opts, :force, false) ->
        {:refuse,
         "#{count} other `arb` processes are already running (limit #{max}); each is a full VM. " <>
           "Use `arb batch` (many commands, one VM) or a bulk verb instead, " <>
           "or set ARB_ALLOW_FANOUT=1 / pass --force (or --allow-fanout) to override."}

      count > warn ->
        {:warn, hint(count)}

      true ->
        :ok
    end
  end

  defp hint(count) do
    "#{count} other `arb` processes are running; each is a full VM (~42 MB). " <>
      "Prefer `arb batch` (many commands, one VM) or the bulk verbs over looping `arb`."
  end

  @doc "Thresholds from an env map; bad values fall back to the defaults."
  @spec thresholds(map()) :: [warn: pos_integer(), max: pos_integer()]
  def thresholds(env) do
    [
      warn: int(env["ARB_FANOUT_WARN"], @default_warn),
      max: int(env["ARB_FANOUT_MAX"], @default_max)
    ]
  end

  defp int(nil, default), do: default

  defp int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  @doc """
  Count other `arb` escript VMs owned by the current user. `opts[:proc_root]`
  (default `/proc`) is overridable for tests.
  """
  @spec count_peers(keyword()) :: non_neg_integer()
  def count_peers(opts \\ []) do
    root = Keyword.get(opts, :proc_root, "/proc")

    with {:ok, entries} <- File.ls(root),
         {:ok, %{uid: uid}} <- own_stat(root) do
      me = System.pid()

      Enum.count(entries, fn pid ->
        pid != me and numeric?(pid) and owned_by?(root, pid, uid) and arb_vm?(root, pid)
      end)
    else
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp own_stat(root) do
    case File.stat(Path.join(root, "self")) do
      {:ok, _} = ok -> ok
      _ -> File.stat(root)
    end
  end

  defp numeric?(s), do: s != "" and String.match?(s, ~r/^\d+$/)

  defp owned_by?(root, pid, uid) do
    match?({:ok, %{uid: ^uid}}, File.stat(Path.join(root, pid)))
  end

  defp arb_vm?(root, pid) do
    case File.read(Path.join([root, pid, "cmdline"])) do
      {:ok, raw} -> arb_cmdline?(String.split(raw, <<0>>, trim: true))
      _ -> false
    end
  end

  @doc false
  # An escript VM runs `... -run escript start -extra <script> args`; ours is
  # `arb`, or `arb.escript` in a worker container, where `arb` is the launcher
  # that runs it (bd-59m96o).
  @spec arb_cmdline?([String.t()]) :: boolean()
  def arb_cmdline?(argv) do
    case Enum.drop_while(argv, &(&1 != "-extra")) do
      ["-extra", script | _] ->
        "escript" in argv and Path.basename(script) in ["arb", "arb.escript"]

      _ ->
        false
    end
  end
end
