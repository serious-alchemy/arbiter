defmodule Arbiter.Worker.CliFetcher.Integrity do
  @moduledoc """
  Integrity checks for a downloaded artefact, streamed from disk so a 160 MB
  tarball is never held in memory.

  Two published forms are accepted: an npm `dist.integrity` (Subresource
  Integrity, `sha512-<base64>`; sha256 and sha384 too) and a GitHub release
  `.sha256` sidecar (`<hex>  <name>`). The legacy `dist.shasum` (SHA-1) is never
  accepted: a package with no SRI value is refused.
  """

  @chunk 1_048_576
  @algos %{"sha512" => :sha512, "sha384" => :sha384, "sha256" => :sha256}

  @type mismatch :: {:integrity_mismatch, %{expected: String.t(), actual: String.t()}}

  @doc "Verify `path` against an SRI string."
  @spec verify_sri(Path.t(), term()) ::
          :ok | {:error, :no_integrity | :bad_integrity | mismatch()}
  def verify_sri(_path, nil), do: {:error, :no_integrity}
  def verify_sri(_path, ""), do: {:error, :no_integrity}

  def verify_sri(path, sri) when is_binary(sri) do
    # An SRI value may list several hashes; the strongest one we support must match.
    candidates =
      for token <- String.split(sri),
          [algo, b64] <- [String.split(token, "-", parts: 2)],
          Map.has_key?(@algos, algo),
          {:ok, digest} <- [Base.decode64(b64)],
          do: {algo, digest}

    case Enum.sort_by(candidates, fn {algo, _} -> algo end, :desc) do
      [] ->
        {:error, :bad_integrity}

      [{algo, expected} | _] ->
        actual = hash_file(path, Map.fetch!(@algos, algo))

        if actual == expected,
          do: :ok,
          else:
            {:error,
             mismatch("#{algo}-#{Base.encode64(expected)}", "#{algo}-#{Base.encode64(actual)}")}
    end
  end

  def verify_sri(_path, _), do: {:error, :bad_integrity}

  @doc "Verify `path` against a lowercase-hex SHA-256."
  @spec verify_sha256(Path.t(), String.t()) :: :ok | {:error, :bad_integrity | mismatch()}
  def verify_sha256(path, hex) when is_binary(hex) do
    expected = String.downcase(hex)

    if Regex.match?(~r/\A[0-9a-f]{64}\z/, expected) do
      actual = sha256_file(path)
      if actual == expected, do: :ok, else: {:error, mismatch(expected, actual)}
    else
      {:error, :bad_integrity}
    end
  end

  def verify_sha256(_path, _), do: {:error, :bad_integrity}

  @doc "The hex digest from a `.sha256` sidecar (`<hex>` or `<hex>  <name>`), or `:error`."
  @spec parse_sidecar(term()) :: {:ok, String.t()} | :error
  def parse_sidecar(text) when is_binary(text) do
    case text |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [hex | _] ->
        if Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, hex),
          do: {:ok, String.downcase(hex)},
          else: :error

      _ ->
        :error
    end
  end

  def parse_sidecar(_), do: :error

  @doc "Lowercase-hex SHA-256 of a file, streamed."
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path), do: path |> hash_file(:sha256) |> Base.encode16(case: :lower)

  defp hash_file(path, algo) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce(:crypto.hash_init(algo), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  defp mismatch(expected, actual),
    do: {:integrity_mismatch, %{expected: expected, actual: actual}}
end
