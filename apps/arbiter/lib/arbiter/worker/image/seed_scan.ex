defmodule Arbiter.Worker.Image.SeedScan do
  @moduledoc """
  SI12 (`docs/design/remote-workers.md` §21.9): what a `prebuilt` image's own
  `/opt/arbiter/seed` (`seed: image`) may not hold. The primary cannot see inside
  an image it only resolved, so `script/0` runs in it (`Prebuilt`, no network, a
  read-only root) and prints one record per suspect, which `check/1` judges:

    * a credential **file name**: `hex.config`, `.netrc`, `.git-credentials`, an
      SSH private key (`id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`; a `.pub`
      is public), or a `*.pem` that holds a private key (a CA bundle such as
      `certifi`'s is public and is not a hit);
    * a `deps/*/.git/config` remote URL that carries userinfo
      (`https://user:token@host/...`), which is where a git dependency fetched
      with a tokenised URL keeps the token.

  The records are `F\\t<path>` and `G\\t<path>\\t<url>`. A hit names the path and
  never prints the URL's userinfo.
  """

  @seed_dir "/opt/arbiter/seed"
  @userinfo ~r{\A[A-Za-z][A-Za-z0-9+.-]*://[^/@\s]+@}
  # `ssh://git@host/...` names a login, not a secret.
  @ssh_login ~r{\Assh://[^:/@\s]+@}

  @script """
  cd #{@seed_dir} 2>/dev/null || exit 0
  find . -type f \\( -name hex.config -o -name .netrc -o -name .git-credentials \\
    -o -name id_rsa -o -name id_dsa -o -name id_ecdsa -o -name id_ed25519 \\) |
    while read -r f; do printf 'F\\t%s\\n' "$f"; done
  find . -type f -name '*.pem' |
    while read -r f; do grep -q 'PRIVATE KEY' "$f" 2>/dev/null && printf 'F\\t%s\\n' "$f"; done
  for c in deps/*/.git/config; do
    [ -f "$c" ] || continue
    sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*//p' "$c" |
      while read -r u; do printf 'G\\t%s\\t%s\\n' "$c" "$u"; done
  done
  """

  @doc "The shell script the inspection runs inside the image."
  @spec script() :: String.t()
  def script, do: @script

  @doc """
  `:ok`, or `{:error, [reason]}` with one reason per hit: `{:credential_file,
  path}` or `{:userinfo_url, path}`.
  """
  @spec check(String.t()) :: :ok | {:error, [{:credential_file | :userinfo_url, String.t()}]}
  def check(output) when is_binary(output) do
    hits =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&record/1)
      |> Enum.uniq()

    if hits == [], do: :ok, else: {:error, hits}
  end

  defp record("F\t" <> path), do: [{:credential_file, path}]

  defp record("G\t" <> rest) do
    case String.split(rest, "\t", parts: 2) do
      [path, url] -> if userinfo?(String.trim(url)), do: [{:userinfo_url, path}], else: []
      _ -> []
    end
  end

  defp record(_), do: []

  defp userinfo?(url), do: Regex.match?(@userinfo, url) and not Regex.match?(@ssh_login, url)
end
