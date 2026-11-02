defmodule Arbiter.NodeAgent.PullAuth do
  @moduledoc """
  The registry **read** credential a machine node is handed for one pull of a
  run's published image (SI4, `docs/design/remote-workers.md` §21.4): the
  `pull_auth` of an `assign` spec, `{registry, username, password}`.

  The primary builds it (`Arbiter.Worker.Image.PullCredential`) only for a node
  the reach rule admits and never from the push credential; the agent validates it
  into this struct (`Arbiter.NodeAgent.RunSpec`) and writes it, as a containers auth
  file, only onto the run's tmpfs (`Arbiter.NodeAgent.ImagePull`), deleted when the
  pull ends.

  ## Never printed

  `Inspect` shows the registry only, so a crash report, an exit reason or a log line
  that carries a spec (a `GenServer.call` that failed with the spec in its message,
  a supervisor's child spec) never prints the login. The wire form is `Jason`'s:
  the one place the password is meant to appear is the `assign` frame itself.
  """

  @derive {Inspect, only: [:registry]}
  @enforce_keys [:registry, :username, :password]
  defstruct [:registry, :username, :password]

  @type t :: %__MODULE__{registry: String.t(), username: String.t(), password: String.t()}

  @doc """
  The containers auth file podman reads with `--authfile`: one `auths` entry for
  the registry host, `auth` being base64 `user:password`.
  """
  @spec authfile_json(t()) :: String.t()
  def authfile_json(%__MODULE__{registry: registry} = auth),
    do: Jason.encode!(%{"auths" => %{registry => %{"auth" => basic(auth)}}})

  @doc "Scrub the password and its base64 `user:password` form from text (podman's output)."
  @spec redact(String.t(), t() | nil) :: String.t()
  def redact(text, %__MODULE__{password: password} = auth) when is_binary(text) do
    text
    |> String.replace(basic(auth), "[REDACTED]")
    |> String.replace(password, "[REDACTED]")
  end

  def redact(text, nil) when is_binary(text), do: text

  defp basic(%__MODULE__{username: user, password: password}),
    do: Base.encode64(user <> ":" <> password)

  defimpl Jason.Encoder do
    def encode(%{registry: registry, username: username, password: password}, opts) do
      Jason.Encode.map(
        %{"registry" => registry, "username" => username, "password" => password},
        opts
      )
    end
  end
end
