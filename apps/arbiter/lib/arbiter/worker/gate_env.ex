defmodule Arbiter.Worker.GateEnv do
  @moduledoc """
  The environment of the pre-push gate's commands (`Arbiter.Worker.PrepushCheck`),
  as far as egress goes (bd-9xcogk).

  A worker's egress proxy is per run: a loopback listener (`127.0.0.1:3128`) bridged
  to a unix socket owned by the run's egress process, advertised to the agent as
  `HTTP(S)_PROXY`/`ALL_PROXY`/`NO_PROXY` (and `GIT_SSH_COMMAND` with a
  `ProxyCommand` through it). The gate runs after the agent, in a container that has
  no such bridge (a node run's rebuilt container) or whose proxy may be gone (a
  local sandboxed run); a command that inherited those variables did not fall back
  to anything, it failed on `Failed to connect to 127.0.0.1 port 3128` and every
  step went red.

  So the gate never carries a per-run proxy: container runs drop the variables
  (`drop_proxy/1`) and run offline, host runs unset the ones the server's own
  environment points at a loopback address (`host_unsets/0`). A proxy that points
  anywhere else is the operator's own egress and is left alone.
  """

  @proxy_names ~w(HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
                  http_proxy https_proxy all_proxy no_proxy)

  @doc "Whether `name` is one of the proxy variables."
  @spec proxy_name?(String.t()) :: boolean()
  def proxy_name?(name), do: name in @proxy_names

  @doc """
  `pairs` without the proxy variables, and without a `GIT_SSH_COMMAND` that tunnels
  through the run's proxy.
  """
  @spec drop_proxy([{String.t(), String.t() | false}]) :: [{String.t(), String.t() | false}]
  def drop_proxy(pairs) when is_list(pairs) do
    Enum.reject(pairs, fn {name, value} ->
      proxy_name?(name) or (name == "GIT_SSH_COMMAND" and proxy_command?(value))
    end)
  end

  @doc """
  `{name, false}` (unset) pairs for each proxy variable of the server's own
  environment that points at a loopback address.
  """
  @spec host_unsets() :: [{String.t(), false}]
  def host_unsets, do: host_unsets(System.get_env())

  @doc false
  @spec host_unsets(%{optional(String.t()) => String.t()}) :: [{String.t(), false}]
  def host_unsets(env) when is_map(env) do
    for {name, value} <- env, proxy_name?(name), loopback?(value), do: {name, false}
  end

  defp proxy_command?(value) when is_binary(value), do: value =~ "ProxyCommand"
  defp proxy_command?(_), do: false

  defp loopback?(value) when is_binary(value),
    do:
      value =~
        ~r{^\s*([a-z0-9+.-]+://)?(\w+(:\w*)?@)?(127\.\d+\.\d+\.\d+|localhost|\[?::1\]?)(:\d+)?(/|\s|$)}i

  defp loopback?(_), do: false
end
