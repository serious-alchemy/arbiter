defmodule Arbiter.Worker.Image.Registry do
  @moduledoc """
  The `nodes.registry` settings as the image publisher uses them (K8, bd-9vrbx7,
  `docs/design/remote-workers.md` §11).

  `fetch/1` is `:unset` unless `nodes.registry` is configured, and every
  publishing path starts there: with no registry nothing in this namespace does
  anything, which is the "nothing changes" half of the K8 acceptance.

  ## Credential handling

  The password is stored Cloak-encrypted (`Arbiter.Settings`) and decrypted only
  here. From here it travels to podman **only as a 0600 auth file** inside a
  0700 directory that `with_authfile/3` removes when the callback returns
  (or raises): never on argv (`ps` shows argv host-wide), never in an
  environment variable, never in a log line. The struct derives `Inspect`
  without it, and `redact/2` scrubs it (and its base64 `user:password` form)
  from anything a tool printed before that text is stored or logged.
  """

  alias Arbiter.Settings

  @derive {Inspect, except: [:password]}
  defstruct [:registry, :host, :username, :password, insecure?: false]

  @type t :: %__MODULE__{
          registry: String.t(),
          host: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          insecure?: boolean()
        }

  @digest_ref ~r/@sha256:[0-9a-f]{64}\z/

  @doc """
  The configured registry, or `:unset`. `opts[:config]` (a map with `:registry`,
  and optionally `:username`, `:password`, `:insecure?`) replaces the settings
  read, for tests and callers that already hold the values.
  """
  @spec fetch(keyword()) :: {:ok, t()} | :unset
  def fetch(opts \\ []) do
    raw =
      case Keyword.get(opts, :config) do
        %{} = config ->
          config

        _ ->
          %{
            registry: Settings.nodes_registry(),
            username: Settings.nodes_registry_username(),
            password: Settings.nodes_registry_password(),
            insecure?: Settings.nodes_registry_insecure?()
          }
      end

    case raw do
      %{registry: registry} when is_binary(registry) and registry != "" ->
        {:ok,
         %__MODULE__{
           registry: registry,
           host: registry |> String.split("/", parts: 2) |> hd(),
           username: blank_to_nil(Map.get(raw, :username)),
           password: blank_to_nil(Map.get(raw, :password)),
           insecure?: Map.get(raw, :insecure?) == true
         }}

      _ ->
        :unset
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc "`<registry>/<name>`: the repository an image is pushed to."
  @spec repository(t(), String.t()) :: String.t()
  def repository(%__MODULE__{registry: registry}, name), do: registry <> "/" <> name

  @doc "podman's TLS flag for this registry (`--tls-verify=false` when insecure)."
  @spec tls_flags(t()) :: [String.t()]
  def tls_flags(%__MODULE__{insecure?: true}), do: ["--tls-verify=false"]
  def tls_flags(%__MODULE__{}), do: []

  @doc "Whether `ref` names an image by `@sha256:<64 hex>`."
  @spec digest_pinned?(term()) :: boolean()
  def digest_pinned?(ref) when is_binary(ref), do: Regex.match?(@digest_ref, ref)
  def digest_pinned?(_), do: false

  @doc """
  Run `fun` with the path of a podman auth file holding this registry's login,
  or with `nil` when there is no login (anonymous push). The file lives in a
  fresh 0700 directory under `scratch_root` and is removed afterwards, whether
  `fun` returns or raises.
  """
  @spec with_authfile(t(), Path.t(), (Path.t() | nil -> result)) :: result when result: term()
  def with_authfile(%__MODULE__{username: user, password: pw}, _scratch_root, fun)
      when is_nil(user) or is_nil(pw),
      do: fun.(nil)

  def with_authfile(%__MODULE__{} = cfg, scratch_root, fun) do
    dir =
      Path.join(
        scratch_root,
        "registry-auth-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir_p!(scratch_root)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "auth.json")

    try do
      File.write!(path, auth_json(cfg), [:exclusive])
      File.chmod!(path, 0o600)
      fun.(path)
    after
      File.rm_rf(dir)
    end
  end

  defp auth_json(%__MODULE__{host: host, username: user, password: pw}),
    do: Jason.encode!(%{"auths" => %{host => %{"auth" => Base.encode64(user <> ":" <> pw)}}})

  @doc "Scrub the password, and its base64 `user:password` form, from tool output."
  @spec redact(String.t(), t()) :: String.t()
  def redact(text, %__MODULE__{password: nil}), do: text

  def redact(text, %__MODULE__{username: user, password: pw}) when is_binary(text) do
    secrets = [pw] ++ if(user, do: [Base.encode64(user <> ":" <> pw)], else: [])
    Enum.reduce(secrets, text, &String.replace(&2, &1, "[REDACTED]"))
  end
end
