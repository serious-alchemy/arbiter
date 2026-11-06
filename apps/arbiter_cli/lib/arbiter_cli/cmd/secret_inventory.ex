defmodule ArbiterCli.Cmd.SecretInventory do
  @moduledoc """
  Which of arbiter's secrets sit **inline** in the service's environment and
  which are **references** to an external secret manager (`NAME_REF=aws-sm:…`,
  `aws-ssm:…`, `file:…`; the server resolves them, see
  `Arbiter.SecretRefs.External`).

  Used by `arb install-service` (what it just wrote) and `arb doctor` (what the
  host carries now), and by the deploy snapshot, which records `fingerprint/1`
  instead of copying the env file.

  Nothing here ever returns, prints or logs a secret value: states carry the
  reference scheme at most, and a fingerprint is a key name plus a short SHA-256
  prefix — enough to see a redeploy left a value unchanged, not to recover it.
  """

  @secrets ~w(
    ARBITER_CLOAK_KEY
    ARBITER_CLOAK_KEY_OLD
    SECRET_KEY_BASE
    GITHUB_TOKEN
    ANTHROPIC_API_KEY
    ANTHROPIC_API_KEY_2
    GEMINI_API_KEY
    GOOGLE_GENAI_API_KEY
  )

  # Secrets the server cannot boot without: an inline copy of one of these is the
  # at-rest exposure a secret scanner flags first.
  @boot_secrets ~w(ARBITER_CLOAK_KEY SECRET_KEY_BASE)

  @schemes ~w(aws-sm aws-ssm file)
  @fingerprint_len 8

  @type state :: :inline | :ref | :shadowed | :unset
  @type entry :: %{name: String.t(), state: state(), scheme: String.t() | nil}

  @doc "The secret names inspected."
  @spec names() :: [String.t()]
  def names, do: @secrets

  @doc """
  Classify each known secret against `env` (a `%{name => value}` map):

    * `:ref` — only `NAME_REF` is set (a well-formed pointer);
    * `:inline` — only `NAME` carries a value;
    * `:shadowed` — both are set: the pointer wins, but the inline value is
      still on disk and should be removed;
    * `:unset` — neither.
  """
  @spec classify(%{optional(String.t()) => String.t()}) :: [entry()]
  def classify(env) when is_map(env) do
    Enum.map(@secrets, fn name ->
      ref = present(env[name <> "_REF"])
      inline? = present(env[name]) != nil

      state =
        cond do
          ref && inline? -> :shadowed
          ref -> :ref
          inline? -> :inline
          true -> :unset
        end

      %{name: name, state: state, scheme: ref && scheme(ref)}
    end)
  end

  @doc "The reference scheme of a pointer (`\"aws-sm\"` …), or `\"invalid\"` when unrecognised."
  @spec scheme(String.t()) :: String.t()
  def scheme(ref) do
    Enum.find(@schemes, "invalid", &String.starts_with?(ref, &1 <> ":"))
  end

  @doc "The inline entries among `entries` that are boot secrets."
  @spec inline_boot_secrets([entry()]) :: [String.t()]
  def inline_boot_secrets(entries) do
    for %{name: n, state: s} <- entries, n in @boot_secrets, s in [:inline, :shadowed], do: n
  end

  @doc "One-line human summary, values never included."
  @spec summary([entry()]) :: String.t()
  def summary(entries) do
    inline = for %{name: n, state: s} <- entries, s in [:inline, :shadowed], do: n

    refs =
      for %{name: n, state: s, scheme: sch} <- entries,
          s in [:ref, :shadowed],
          do: "#{n} (#{sch})"

    [
      "inline: " <> if(inline == [], do: "none", else: Enum.join(inline, ", ")),
      "references: " <> if(refs == [], do: "none", else: Enum.join(refs, ", "))
    ]
    |> Enum.join("; ")
  end

  @doc "Environment to inspect: the service's `EnvironmentFile` entries over nothing else."
  @spec env_from_file(Path.t()) :: %{optional(String.t()) => String.t()}
  def env_from_file(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_line/1)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Key names plus a hash prefix for every entry of `env` — what a deploy snapshot
  records instead of the values. Sorted by key.
  """
  @spec fingerprint(%{optional(String.t()) => String.t()}) :: [
          %{key: String.t(), sha256: String.t()}
        ]
  def fingerprint(env) when is_map(env) do
    env
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} ->
      digest = :crypto.hash(:sha256, to_string(value)) |> Base.encode16(case: :lower)
      %{key: key, sha256: binary_part(digest, 0, @fingerprint_len)}
    end)
  end

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp present(_), do: nil

  defp parse_line(line) do
    line = line |> String.trim() |> String.replace_prefix("export ", "")

    with false <- String.starts_with?(line, "#"),
         [key, value] <- String.split(line, "=", parts: 2),
         true <- Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key) do
      [{key, unquote_value(String.trim(value))}]
    else
      _ -> []
    end
  end

  defp unquote_value("\"" <> rest = v),
    do: if(String.ends_with?(rest, "\""), do: String.slice(rest, 0..-2//1), else: v)

  defp unquote_value("'" <> rest = v),
    do: if(String.ends_with?(rest, "'"), do: String.slice(rest, 0..-2//1), else: v)

  defp unquote_value(v), do: v
end
