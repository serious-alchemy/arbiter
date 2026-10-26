defmodule Arbiter.Worker.CliSetFixture do
  @moduledoc false
  # A pinned, verified CLI cache (`Arbiter.Worker.CliFetcher.Cache`) filled with
  # stand-in files, so a test resolves a `Arbiter.Worker.CliSet` the way the
  # product does: from the cache SI1a fills, never from a host install.
  #
  # `put/2` writes the cache under `root` and returns the options that make
  # `CliSet.resolve/1` read it (`:cli_cache_root`, `:cli_pins`, `:cli_arb_version`,
  # `:cli_platform`, and `:cli_sets_root` for the materialized set). `set!/2`
  # resolves it.

  alias Arbiter.Worker.CliFetcher.Cache
  alias Arbiter.Worker.CliSet

  @platform "linux-x64"

  @doc """
  Fill `<root>/cli-cache` and return the `CliSet` options. `:claude`, `:codex`
  and `:arb` are the versions to cache (`nil` skips the CLI); `:content`
  (`%{name => binary}`) overrides the main file's bytes.
  """
  @spec put(Path.t(), keyword()) :: keyword()
  def put(root, opts \\ []) do
    cache = Path.join(root, "cli-cache")
    claude = Keyword.get(opts, :claude, "2.1.310")
    codex = Keyword.get(opts, :codex, "0.130.0")
    arb = Keyword.get(opts, :arb, "1.2.3")
    content = Keyword.get(opts, :content, %{})
    cache_opts = [root: cache, platform: @platform]

    if claude do
      store(
        "claude",
        claude,
        [{"claude", Map.get(content, "claude", "claude-binary-" <> claude), 0o755}],
        "claude",
        cache_opts
      )
    end

    if codex do
      store(
        "codex",
        codex,
        [
          {"bin/codex", Map.get(content, "codex", "codex-binary-" <> codex), 0o755},
          {"bin/codex-code-mode-host", "code-mode-host-" <> codex, 0o755},
          {"codex-path/rg", "rg-binary", 0o755},
          {"codex-resources/bwrap", "bwrap-binary", 0o755}
        ],
        "bin/codex",
        cache_opts
      )
    end

    if arb do
      store(
        "arb",
        arb,
        [{"arb", Map.get(content, "arb", escript("28", arb)), 0o755}],
        "arb",
        cache_opts
      )
    end

    pins =
      Map.new(for({name, v} <- [{"claude", claude}, {"codex", codex}], v, do: {name, v}))

    [
      cli_cache_root: cache,
      cli_sets_root: Path.join(root, "cli-sets"),
      cli_pins: pins,
      cli_arb_version: arb || "0.0.0-unpinned",
      cli_platform: @platform
    ]
  end

  @doc "The option keys `put/2` returns, for `Keyword.take/2`."
  @spec keys() :: [atom()]
  def keys, do: CliSet.option_keys() -- [:cli_set]

  @doc """
  Where `file` of `cli` lands on the host once the set `opts` describe is
  materialized (what a bind mount or a COPY reads).
  """
  @spec host_path(keyword(), String.t(), String.t()) :: Path.t()
  def host_path(opts, cli, file) do
    {:ok, set} = opts |> CliSet.resolve() |> then(fn {:ok, s} -> CliSet.materialize(s) end)
    Path.join([set.dir, cli, file])
  end

  @doc "`put/2`, then resolve the set."
  @spec set!(Path.t(), keyword()) :: CliSet.t()
  def set!(root, opts \\ []) do
    {:ok, set} = root |> put(opts) |> CliSet.resolve()
    set
  end

  @doc "An arb escript body stamped with the OTP release it was 'built' on."
  def escript(otp, version),
    do: "#!/usr/bin/env escript\n%% arb-otp=#{otp}\n%%! -escript main nil_escript\n# #{version}\n"

  defp store(name, version, files, main, cache_opts) do
    staged = Path.join(cache_opts[:root], "staging-#{name}-#{System.unique_integer([:positive])}")

    for {rel, bytes, mode} <- files do
      path = Path.join(staged, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      File.chmod!(path, mode)
    end

    {:ok, _entry} =
      Cache.put(
        name,
        version,
        staged,
        for({rel, _, mode} <- files, do: {rel, mode}),
        %{
          source: "https://upstream.test/#{name}-#{version}",
          integrity: "sha512-fixture",
          main: main
        },
        cache_opts
      )

    File.rm_rf!(staged)
  end
end
