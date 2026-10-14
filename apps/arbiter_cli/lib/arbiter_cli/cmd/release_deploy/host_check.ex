defmodule ArbiterCli.Cmd.ReleaseDeploy.HostCheck do
  @moduledoc """
  Pre-download guard for `arb server deploy`: is *this* machine somewhere the
  server can be deployed?

  The deploy installs under the local data home and restarts whatever serves the
  API port, but the CLI may be pointed at a different machine (a workstation
  with an SSH tunnel on `127.0.0.1:4848`). Two refusals, both before anything is
  downloaded or written:

    * **Platform** — only a `-linux` x86_64/aarch64 release is published, so any
      other host OS/arch cannot run it.
    * **Remote target** — there is no existing install at the data home *and* the
      CLI targets a remote server (a non-loopback `ARB_HOST`, or a loopback port
      held by a process that is not an arbiter server, such as an SSH tunnel).

  `--this-host` waives the remote-target check for a deliberate first install
  on a fresh Linux host. It never waives the platform check.

  Seams (tests): `:bd2_host_platform` (`{os, arch}`) and `:bd2_port_owner`
  (`fn port -> :arbiter | :foreign | :none end`).
  """

  alias ArbiterCli.{Client, Cmd.Restart}
  alias ArbiterCli.Cmd.ReleaseDeploy.ReleaseFiles

  @default_port 4848

  @doc "`:ok`, or `{:error, message, hint}` when the deploy must be refused."
  @spec check(keyword()) :: :ok | {:error, String.t(), String.t()}
  def check(opts) do
    with :ok <- check_platform() do
      if opts[:this_host], do: :ok, else: check_target()
    end
  end

  defp check_platform do
    {os, arch} = platform()

    if os == :linux and arch in ["x86_64", "aarch64"] do
      :ok
    else
      {:error, "this host (#{os}/#{arch}) cannot run the published server release",
       "Only a Linux release is published. Run `arb server deploy` on the machine that " <>
         "hosts the server (e.g. over ssh), not on a workstation that merely talks to it."}
    end
  end

  defp check_target do
    if ReleaseFiles.current_target(ReleaseFiles.current_link()) do
      :ok
    else
      case remote_reason() do
        nil ->
          :ok

        reason ->
          {:error, "no Arbiter install at #{ReleaseFiles.data_home()} and #{reason}",
           "This looks like a machine that only talks to a remote server. Run the deploy on " <>
             "the server host. To deliberately install a server on this host, pass `--this-host`."}
      end
    end
  end

  defp remote_reason do
    cond do
      not Client.loopback_host?() ->
        "the CLI targets a remote server (ARB_HOST=#{Client.base_url()})"

      port_owner(port()) == :foreign ->
        "port #{port()} is held by a process that is not an Arbiter server (an SSH tunnel?)"

      true ->
        nil
    end
  end

  defp port do
    case URI.parse(Client.base_url()) do
      %URI{port: p} when is_integer(p) -> p
      _ -> @default_port
    end
  end

  defp platform do
    case Process.get(:bd2_host_platform) do
      {_, _} = p ->
        p

      _ ->
        os = if match?({:unix, :linux}, :os.type()), do: :linux, else: elem(:os.type(), 1)

        arch =
          :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

        {os, arch}
    end
  end

  defp port_owner(port) do
    case Process.get(:bd2_port_owner) do
      fun when is_function(fun, 1) -> fun.(port)
      _ -> Restart.port_owner(port)
    end
  end
end
