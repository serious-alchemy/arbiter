defmodule Arbiter.Worker.GitCredential.Material do
  @moduledoc """
  A resolved, repo-scoped git credential (`Arbiter.Worker.GitCredential`): the
  secret values for one spawn. Holds secrets, so it never rides in a run record
  or a log line; `Arbiter.Worker.GitCredential.redact_values/1` lists what the
  output scrubber must mask.

    * `:deploy_key` — `key` is the private key text.
    * `:token` / `:github_app` — `token` is the push credential; `remote` is the
      `owner/repo` it is pinned to, `host` the forge host it is offered to and
      `username` the HTTP basic user. `tracker_token` is the narrower token for
      `tracker_write` (when one was asked for).
  """

  @remote_re ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+\z/
  @host_re ~r/\A[A-Za-z0-9.-]+\z/
  @user_re ~r/\A[A-Za-z0-9_.:-]+\z/

  defstruct kind: nil,
            key: nil,
            token: nil,
            tracker_token: nil,
            host: "github.com",
            username: "x-access-token",
            remote: nil

  @type t :: %__MODULE__{
          kind: :deploy_key | :token | :github_app | nil,
          key: String.t() | nil,
          token: String.t() | nil,
          tracker_token: String.t() | nil,
          host: String.t(),
          username: String.t(),
          remote: String.t() | nil
        }

  @doc """
  The spawn env that delivers the credential. A deploy key gets only
  `GIT_SSH_COMMAND` naming `key_path` (and no agent: `IdentityAgent=none`); a
  token gets `ARB_GIT_TOKEN` plus git config (via `GIT_CONFIG_COUNT`) that
  resets every inherited credential helper, installs one that answers only for
  `remote`'s own path, and rewrites ssh remotes of `host` to https so the helper
  applies. Raises `ArgumentError` for a `remote`, `host` or `username` that
  could inject into the helper script.
  """
  @spec env(t(), String.t() | nil) :: [{String.t(), String.t()}]
  def env(%__MODULE__{kind: :deploy_key}, key_path) when is_binary(key_path),
    do: [{"GIT_SSH_COMMAND", Arbiter.Worker.GitCredential.ssh_command(key_path)}]

  def env(%__MODULE__{token: token} = m, _key_path) when is_binary(token) do
    ensure!(m.remote, @remote_re, "remote")
    ensure!(m.host, @host_re, "host")
    ensure!(m.username, @user_re, "username")

    url = "https://#{m.host}"

    config = [
      {"credential.helper", ""},
      {"credential.#{url}.helper", ""},
      {"credential.#{url}.helper", helper(m)},
      {"credential.useHttpPath", "true"},
      {"url.#{url}/.insteadOf", "git@#{m.host}:"},
      {"url.#{url}/.insteadOf", "ssh://git@#{m.host}/"}
    ]

    # `GIT_CONFIG_PARAMETERS` (what `git -c` sets) rather than `GIT_CONFIG_COUNT`:
    # the first two entries have an empty value, which resets the helper list,
    # and an empty env var value does not survive being passed to a child.
    parameters = Enum.map_join(config, " ", fn {key, value} -> sq("#{key}=#{value}") end)

    [
      {"ARB_GIT_TOKEN", token},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_PARAMETERS", parameters}
    ]
  end

  def env(%__MODULE__{}, _key_path), do: []

  # Answers `get` for the pinned path only (compared case-insensitively, as the
  # forges do). The token itself is read from the env, never written into config.
  @helper ~S"""
  !f() { test "$1" = get || exit 0; p=; while IFS== read -r k v; do [ "$k" = path ] && p=$v; done; p=$(printf %s "${p%.git}" | tr "A-Z" "a-z"); [ "$p" = "REMOTE" ] || exit 0; echo username=USER; echo "password=$ARB_GIT_TOKEN"; }; f
  """

  defp helper(%__MODULE__{remote: remote, username: username}) do
    @helper
    |> String.trim()
    |> String.replace("REMOTE", String.downcase(remote))
    |> String.replace("USER", username)
  end

  defp sq(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp ensure!(value, re, what) do
    if is_binary(value) and value =~ re,
      do: :ok,
      else: raise(ArgumentError, "git credential #{what} #{inspect(value)} is not valid")
  end
end
