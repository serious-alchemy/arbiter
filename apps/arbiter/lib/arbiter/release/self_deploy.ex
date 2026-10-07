defmodule Arbiter.Release.SelfDeploy do
  @moduledoc """
  Launch `arb server deploy` for an operator who asked for an update — the
  dashboard's "Update to vX.Y.Z" button and `POST /api/release/deploy`.

  ## Why a separate systemd unit

  The deploy restarts `arbiter.service`, i.e. kills this BEAM mid-deploy. So it
  cannot run as a child of the server, nor even in its cgroup. It is started with

      systemd-run --user --unit=arbiter-deploy-<tag> --collect … arb server deploy --version <tag> --json

  which makes a transient service of the *user manager*, outside
  `arbiter.service`, that survives the restart and runs the same deploy an
  operator would run by hand (backup, swap, health check, rollback, CLI update).
  Its progress and outcome are the CLI's own status file
  (`Arbiter.Release.DeployStatus`), which the dashboard reads once the server is
  back.

  ## Guards

    * Only a plain `vX.Y.Z` tag is deployable: the tag is an argv element of a
      process run as the operator, so it is validated rather than escaped, and a
      branch, ref or option can never reach it.
    * One deploy at a time: refused while any `arbiter-deploy-*` unit is active
      or the status file says a live deploy is running. A record whose process
      died does not block.
    * Secrets never travel in argv or logs. The unit gets the service's
      environment through `EnvironmentFile=-<data-home>/arbiter.env` (where
      `GITHUB_TOKEN` already lives), and anything printed back is scrubbed of
      the token's value.

  Authorisation is the caller's job and is operator-only: the REST route is
  `:operator` in `ArbiterWeb.ApiPolicy`, the browser route sits behind the
  dashboard login. This module trusts that.
  """

  require Logger

  alias Arbiter.Release.DeployStatus
  alias Arbiter.Worker.ReleaseEnv

  @tag_re ~r/\Av\d+\.\d+\.\d+\z/
  @unit_prefix "arbiter-deploy-"

  @type error ::
          :invalid_tag
          | :already_running
          | :systemd_unavailable
          | {:cli_missing, String.t()}
          | {:launch_failed, String.t()}

  @doc "Start the deploy of `tag`. Returns the unit it runs in."
  @spec start(term()) :: {:ok, %{unit: String.t(), tag: String.t()}} | {:error, error()}
  def start(tag) when is_binary(tag) do
    with :ok <- validate_tag(tag),
         :ok <- ensure_cli(),
         :ok <- ensure_not_running() do
      launch(tag)
    end
  end

  def start(_), do: {:error, :invalid_tag}

  @doc "The deploy-unit name for `tag`."
  @spec unit_name(String.t()) :: String.t()
  def unit_name(tag), do: @unit_prefix <> tag

  @doc "Whether a deploy is in progress (an active deploy unit or a live status record)."
  @spec running?() :: boolean()
  def running?, do: ensure_not_running() != :ok

  # ---- guards ------------------------------------------------------------------

  defp validate_tag(tag) do
    if Regex.match?(@tag_re, tag), do: :ok, else: {:error, :invalid_tag}
  end

  defp ensure_cli do
    path = cli_path()
    if File.regular?(path), do: :ok, else: {:error, {:cli_missing, path}}
  end

  defp ensure_not_running do
    cond do
      DeployStatus.running?(DeployStatus.read()) ->
        {:error, :already_running}

      true ->
        case active_units() do
          {:ok, []} -> :ok
          {:ok, _units} -> {:error, :already_running}
          :error -> {:error, :systemd_unavailable}
        end
    end
  end

  defp active_units do
    args = ["--user", "list-units", @unit_prefix <> "*", "--state=active,activating,deactivating"]
    args = args ++ ["--no-legend", "--plain", "--no-pager"]

    case run("systemctl", args) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.reject(&(&1 == ""))}
      _ -> :error
    end
  end

  # ---- launch ------------------------------------------------------------------

  defp launch(tag) do
    unit = unit_name(tag)
    home = Arbiter.Nodes.Agent.data_home()

    args =
      [
        "--user",
        "--unit=#{unit}",
        "--collect",
        "--description=Arbiter self-update to #{tag}",
        "--property=EnvironmentFile=-" <> Path.join(home, "arbiter.env"),
        "--setenv=ARB_DATA_HOME=#{home}",
        cli_path(),
        "server",
        "deploy",
        "--version",
        tag,
        "--json"
      ]

    case run("systemd-run", args) do
      {_out, 0} ->
        Logger.info(
          "Arbiter.Release.SelfDeploy: started #{unit} (arb server deploy --version #{tag})"
        )

        {:ok, %{unit: unit, tag: tag}}

      {out, _code} ->
        classify_failure(out)
    end
  end

  # Two near-simultaneous requests race for the same unit name; the loser reads
  # as "already running", not as a launch failure.
  defp classify_failure(out) do
    if out =~ ~r/already (loaded|exists)|already.*fragment/i do
      {:error, :already_running}
    else
      message = out |> to_string() |> String.trim() |> scrub() |> String.slice(0, 400)
      Logger.warning("Arbiter.Release.SelfDeploy: systemd-run failed: #{message}")
      {:error, {:launch_failed, message}}
    end
  end

  # ---- helpers -----------------------------------------------------------------

  defp cli_path do
    case config(:arb_path) do
      path when is_binary(path) ->
        path

      _ ->
        case System.get_env("ARB_INSTALL_BIN") do
          path when is_binary(path) and path != "" -> Path.expand(path)
          _ -> Path.join(System.user_home!(), ".local/bin/arb")
        end
    end
  end

  # `:cmd` is the test seam (`config :arbiter, :self_deploy, cmd: fun`); the real
  # runner is `ReleaseEnv.cmd/3`, which strips the release's ROOTDIR/BINDIR/RELEASE_*
  # so nothing of this BEAM leaks into what systemd-run spawns.
  defp run(cmd, args) do
    case config(:cmd) do
      fun when is_function(fun, 3) -> fun.(cmd, args, stderr_to_stdout: true)
      _ -> ReleaseEnv.cmd(cmd, args, stderr_to_stdout: true)
    end
  rescue
    e in ErlangError -> {"could not run #{cmd}: #{inspect(e.original)}", 127}
  end

  defp scrub(text) do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and byte_size(token) >= 8 ->
        String.replace(text, token, "[redacted]")

      _ ->
        text
    end
  end

  defp config(key), do: :arbiter |> Application.get_env(:self_deploy, []) |> Keyword.get(key)
end
