defmodule Arbiter.Worker.Image do
  @moduledoc """
  The worker image lifecycle (bd-9r5jdt, P4 of
  `docs/design/podman-worker-containers.md` §2): what an image is, where its
  definition comes from, what its tag is, and how stale ones are listed and
  pruned. `Arbiter.Worker.Image.Builder` runs the builds (single-flight) and
  `Arbiter.Worker.Image.Refresher` does the weekly base refresh.

  ## Two layers

  One shared **base** (`localhost/arbiter-dev/base:<hash>`: OS, git, build
  tools, `procps`, `socat`, an empty `/opt/arbiter/cli` on `PATH` for the
  provider CLIs, and off `PATH` at `/opt/arbiter/otp` the Erlang/OTP release
  the `arb` escript was built on, so arb runs whatever Erlang a repo pins:
  `base_containerfile/1`, bd-59m96o) and a thin **toolchain** layer per
  distinct `(Erlang, Elixir, Node)` tuple (`localhost/arbiter-dev/<name>:<hash>`,
  `FROM ${ARBITER_BASE}`).
  Provider CLIs are deliberately not baked into a toolchain layer: `claude`
  ships often, so P7 mounts a versioned read-only CLI directory at
  `/opt/arbiter/cli` rather than rebuilding every layer.

  ## Where the Containerfile comes from (supply chain, design §2.2 and §8)

  Only the **default branch's committed tree**:

    * the ref is `refs/remotes/origin/<default>` when it exists, else
      `refs/heads/<default>`; never `HEAD`, never a checked-out worktree, never
      a branch name a worker chose. `plan/3` takes the default branch as an
      argument and refuses anything that is not a plain branch name;
    * the file is read with `git cat-file blob <ref>:.arbiter/Containerfile`, so
      what a worker did to its own branch or working tree cannot reach it. A
      worker that edits the file changes nothing until a human merges it;
    * the build context is an **empty directory**, so a toolchain Containerfile
      cannot `COPY` repo content (`Builder`).

  Without `.arbiter/Containerfile` the image is generated from the default
  branch's `.tool-versions` (`erlang`, `elixir`, `nodejs`), falling back to
  `config :arbiter, :worker_image_default_toolchain`.

  A pin the image cannot honour is an error, not the default: an unsupported
  `elixir`/`erlang` value, or a Containerfile whose Elixir `FROM` disagrees with
  `.tool-versions` (`Arbiter.Worker.Toolchain.check_containerfile/2`, bd-3fnqi8;
  `docs/worker-toolchain.md`).

  ## Digest pinning

  Every `FROM` that names an external image is rewritten to `ref@sha256:…`
  before it is hashed or built. The digest comes from a resolver (default:
  `Arbiter.Worker.Image.Pins`, a pin store that the weekly refresh moves). A
  `FROM` that cannot be resolved refuses the build; so does one that goes
  through a build arg other than `ARBITER_BASE`, and a `COPY --from=` naming an
  external image that is not digest-pinned.

  ## Tags are content hashes

  `localhost/arbiter-dev/<name>:<hash12>` where the hash covers the pinned
  Containerfile, the build args (which carry the base's own content-hash tag)
  and the repo's pin file. A changed `.tool-versions`, Containerfile or base
  digest changes the tag; a changed `mix.lock` does not (deps live outside the
  image, design §3.3). Two repos with the same toolchain share one tag.

  All podman calls go through the `:runner` option
  (`(cmd, args, opts -> {output, status})`) or
  `config :arbiter, :worker_image_runner`, so tests run without podman. Git
  always runs for real (against a scratch repo in tests).
  """

  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.Worker.ArbCli
  alias Arbiter.Worker.Image.Builder
  alias Arbiter.Worker.Image.Pins
  alias Arbiter.Worker.Image.Prebuilt
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.Toolchain

  require Logger

  @registry "localhost/arbiter-dev"
  @label "arbiter.dev-image"
  # The release of the Erlang/OTP the base carries for arb (bd-59m96o); images
  # built on the base inherit it.
  @arb_otp_label "arbiter.arb-otp"
  # KH14: images built FROM the base inherit it; `Image.Prebuilt` requires it.
  @contract_label "arbiter.runtime-contract"
  @contract_version "1"
  @branch_re ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/
  @version_re ~r/\A\d+(\.\d+){0,3}\z/
  @sha_re ~r/@sha256:[0-9a-f]{64}\z/
  @from_re ~r/\A(?<prefix>\s*FROM\s+)(?<flags>(?:--\S+\s+)*)(?<ref>\S+)(?:\s+AS\s+(?<alias>\S+))?(?<trail>\s*)\z/i
  @copy_from_re ~r/\A\s*COPY\s+(?:--\S+\s+)*--from=(\S+)/i
  @default_keep 2
  @git_timeout_ms 30_000
  @podman_timeout_ms 60_000

  @default_toolchain %{erlang: "29.1.1", elixir: "1.20.4"}

  @doc """
  The shared base's Containerfile, for arb's Erlang/OTP release `arb_otp`.

  The base's Debian release must be at least as new as the one the toolchain
  source images (`library/elixir:*-slim`, built on `erlang:*-slim`) track: their
  `beam.smp` needs that release's glibc (bookworm's 2.36 fails with
  `GLIBC_2.38 not found`; found by `image_podman_test.exs`). `libssl3t64` is
  trixie's name for libssl3.

  bd-59m96o: `arb` is an escript compiled by the host's Erlang/OTP, which an
  older release cannot load (an OTP 29 arb on a repo pinned to OTP 27:
  `corrupt atom table`) and an image with no Erlang cannot run at all. So the
  base carries the official Erlang image's install of arb's release at
  `Arbiter.Worker.ArbCli.runtime_dir/0`, off `PATH` (a repo's toolchain stays
  the one it pins), minus what a VM never loads (sources, headers, docs). The
  container's `arb` launcher runs the escript on it. That image tracks a
  Debian release too (trixie as of `erlang:29-slim`), so the same glibc rule
  holds for it.
  """
  @spec base_containerfile(String.t()) :: String.t()
  def base_containerfile(arb_otp) do
    """
    # Generated by Arbiter (bd-9r5jdt): the shared base of every worker image.
    # The Erlang/OTP the arb CLI runs on, whatever a repo pins (bd-59m96o).
    FROM docker.io/library/erlang:#{arb_otp}-slim AS arb_otp
    RUN find /usr/local/lib/erlang -type d \\( -name src -o -name include -o -name doc -o -name examples -o -name c_src \\) -prune -exec rm -rf {} +
    FROM docker.io/library/debian:trixie-slim
    RUN apt-get update \\
     && apt-get install -y --no-install-recommends \\
          bc build-essential ca-certificates curl git libncurses6 libsctp1 libssl3t64 \\
          openssh-client procps socat sqlite3 tini \\
     && rm -rf /var/lib/apt/lists/*
    RUN groupadd --gid 10001 arbiter \\
     && useradd --uid 10001 --gid 10001 --no-log-init --create-home \\
          --home-dir /home/arbiter --shell /bin/sh arbiter
    RUN mkdir -p /opt/arbiter/cli
    COPY --from=arb_otp /usr/local/lib/erlang #{ArbCli.runtime_dir()}
    LABEL #{@arb_otp_label}="#{arb_otp}"
    LABEL #{@contract_label}="#{@contract_version}"
    #{PodScripts.image_install()}
    ENV PATH=/opt/arbiter/cli:$PATH
    """
  end

  @type toolchain :: %{
          required(:erlang) => String.t(),
          required(:elixir) => String.t(),
          optional(:node) => String.t() | nil
        }

  @type layer :: %{
          required(:name) => String.t(),
          required(:hash) => String.t(),
          required(:tag) => String.t(),
          required(:containerfile) => String.t(),
          required(:pins) => [{String.t(), String.t()}],
          optional(:arb_otp) => String.t()
        }

  @type plan :: %{
          required(:name) => String.t(),
          required(:hash) => String.t(),
          required(:tag) => String.t(),
          required(:containerfile) => String.t(),
          required(:build_args) => [{String.t(), String.t()}],
          required(:source) => :repo | :generated | :prebuilt,
          required(:ref) => String.t(),
          required(:toolchain) => toolchain() | nil,
          required(:pins) => [{String.t(), String.t()}],
          required(:base) => layer() | nil,
          optional(:prebuilt) => map()
        }

  @doc "The label every Arbiter dev image carries (and `list/1` filters on)."
  @spec label() :: String.t()
  def label, do: @label

  @doc """
  The label recording the release of the Erlang/OTP the base carries for arb
  (bd-59m96o). Images built on the base inherit it.
  """
  @spec arb_otp_label() :: String.t()
  def arb_otp_label, do: @arb_otp_label

  @doc """
  The label (and its value) that says an image satisfies the pod runtime contract:
  the shared base sets it and a `prebuilt` image must carry it (KH14).
  """
  @spec contract_label() :: {String.t(), String.t()}
  def contract_label, do: {@contract_label, @contract_version}

  @doc "The local registry namespace of every Arbiter dev image."
  @spec registry() :: String.t()
  def registry, do: @registry

  # -- planning ----------------------------------------------------------------

  @doc """
  The build plan for `repo_path`'s `default_branch`: the digest-pinned
  Containerfile, its content-hash tag and the shared base's. Builds nothing.

  Options: `:resolver` (`ref -> {:ok, "sha256:…"} | {:error, term}`, default the
  pin store), `:defaults` (a toolchain map overriding the configured default),
  `:source` (KH11, `Arbiter.Worker.Image.RepoConfig`: `:auto` (default) takes the
  committed `.arbiter/Containerfile` when there is one, `:containerfile` insists on it,
  `:generated` ignores it; `:prebuilt` is `Arbiter.Worker.Image.Prebuilt.plan/3`, which
  takes `:image` and `:registry` too),
  `:repo_name` (names the image of a repo-supplied Containerfile), `:arb_otp`
  (the release of the Erlang/OTP the base carries for arb; default
  `Arbiter.Worker.ArbCli.runtime_otp/1`, the host arb's, which takes `:arb_path`).
  """
  @spec plan(String.t(), String.t(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(repo_path, default_branch, opts \\ []) when is_binary(repo_path) do
    if Keyword.get(opts, :source, :auto) == :prebuilt,
      do: Prebuilt.plan(repo_path, default_branch, opts),
      else: plan_built(repo_path, default_branch, opts)
  end

  defp plan_built(repo_path, default_branch, opts) do
    resolver = Keyword.get_lazy(opts, :resolver, fn -> Pins.resolver(opts) end)
    arb_otp = Keyword.get_lazy(opts, :arb_otp, fn -> ArbCli.runtime_otp(opts) end)

    with {:ok, ref} <- default_ref(repo_path, default_branch),
         {:ok, tool_versions} <- read_file(repo_path, ref, ".tool-versions"),
         {:ok, repo_cf} <- read_file(repo_path, ref, ".arbiter/Containerfile"),
         {:ok, repo_cf} <- choose_source(Keyword.get(opts, :source, :auto), repo_cf),
         # bd-3fnqi8: a pin the image cannot honour is an error, not the default.
         :ok <- Toolchain.check_containerfile(tool_versions, repo_cf),
         toolchain = toolchain(tool_versions, opts),
         {:ok, base} <- base_layer(resolver, arb_otp),
         {source, text} = toolchain_source(repo_cf, toolchain),
         {:ok, pinned, pins} <- pin(text, resolver) do
      build_args = [{"ARBITER_BASE", base.tag}]
      name = image_name(source, toolchain, Keyword.get(opts, :repo_name))

      hash =
        hash([pinned, inspect(build_args), tool_versions || ""])

      {:ok,
       %{
         name: name,
         hash: hash,
         tag: tag(name, hash),
         containerfile: pinned,
         build_args: build_args,
         source: source,
         ref: ref,
         toolchain: toolchain,
         pins: Enum.uniq(base.pins ++ pins),
         base: base
       }}
    end
  end

  @doc """
  Plan `repo_path`'s image from `default_branch` and build whatever is missing
  (`Arbiter.Worker.Image.Builder`, single-flight). The lazy entry point:
  dispatch calls it, `arb image build` calls it, and a request for a tag that
  already exists returns at once.

  Takes `plan/3`'s options plus the builder's, and `:server` (default
  `Arbiter.Worker.Image.Builder`).
  """
  @spec ensure(String.t(), String.t(), keyword()) ::
          {:ok, %{tag: String.t(), built: [String.t()]}} | {:error, term()}
  def ensure(repo_path, default_branch, opts \\ []) do
    with {:ok, plan} <- plan(repo_path, default_branch, opts) do
      Builder.ensure(Keyword.get(opts, :server, Builder), plan, opts)
    end
  end

  @doc "`localhost/arbiter-dev/<name>:<hash>`."
  @spec tag(String.t(), String.t()) :: String.t()
  def tag(name, hash), do: "#{@registry}/#{name}:#{hash}"

  defp hash(parts) do
    parts
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @doc """
  The shared base as a layer: its digest-pinned Containerfile, content-hash tag
  and pins, for arb's Erlang/OTP release `arb_otp`. `plan/3` builds on it and
  release CI (`mix arbiter.containerfile worker-base`) publishes the same text,
  so the hash a repo's CI `FROM`s is the one a primary would have built.
  """
  @spec base_layer((String.t() -> {:ok, String.t()} | {:error, term()}), String.t()) ::
          {:ok, layer()} | {:error, term()}
  def base_layer(resolver, arb_otp) do
    with {:ok, pinned, pins} <- pin(base_containerfile(arb_otp), resolver) do
      hash = hash([pinned])

      {:ok,
       %{
         name: "base",
         hash: hash,
         tag: tag("base", hash),
         containerfile: pinned,
         pins: pins,
         arb_otp: arb_otp
       }}
    end
  end

  # Which Containerfile (if any) the plan builds from, per `image.source`.
  defp choose_source(:auto, repo_cf), do: {:ok, repo_cf}
  defp choose_source(:generated, _repo_cf), do: {:ok, nil}
  defp choose_source(:containerfile, text) when is_binary(text), do: {:ok, text}

  defp choose_source(:containerfile, nil),
    do:
      {:error,
       {:source_unavailable, :containerfile, "no .arbiter/Containerfile on the default branch"}}

  defp toolchain_source(nil, toolchain), do: {:generated, generated_containerfile(toolchain)}
  # `FROM ${ARBITER_BASE}` needs the arg declared before the first FROM.
  defp toolchain_source(text, _toolchain) do
    if Regex.match?(~r/^\s*ARG\s+ARBITER_BASE\b/m, text),
      do: {:repo, text},
      else: {:repo, "ARG ARBITER_BASE\n" <> text}
  end

  defp image_name(:repo, _toolchain, repo_name), do: "repo-" <> slug(repo_name || "custom")

  defp image_name(:generated, toolchain, _repo_name) do
    "beam-#{toolchain.elixir}-#{toolchain.erlang}" <>
      if(toolchain.node, do: "-node#{toolchain.node}", else: "")
  end

  @doc """
  The image-name slug of a repo name: lower case, runs of anything but `a-z0-9`
  folded to `-`, `custom` when nothing is left.
  """
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "custom"
      slug -> slug
    end
  end

  # -- toolchain ---------------------------------------------------------------

  @doc "The configured fallback toolchain (`:worker_image_default_toolchain`)."
  @spec default_toolchain() :: toolchain()
  def default_toolchain do
    Application.get_env(:arbiter, :worker_image_default_toolchain, @default_toolchain)
  end

  # Versions are interpolated into a Containerfile, so only plain dotted
  # numbers are accepted; anything else (a `ref:` pin, a typo) falls back.
  defp toolchain(tool_versions, opts) do
    defaults = Keyword.get_lazy(opts, :defaults, &default_toolchain/0)
    parsed = parse_tool_versions(tool_versions)

    elixir = parsed[:elixir] || defaults[:elixir]
    erlang = parsed[:erlang] || parsed[:otp] || defaults[:erlang]
    %{erlang: erlang, elixir: elixir, node: parsed[:node] || defaults[:node]}
  end

  defp parse_tool_versions(nil), do: %{}

  defp parse_tool_versions(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case line |> String.split("#") |> hd() |> String.split() do
        ["erlang", v | _] -> put_version(acc, :erlang, v)
        ["elixir", v | _] -> acc |> put_version(:elixir, v) |> put_otp(v)
        [n, v | _] when n in ["nodejs", "node"] -> put_version(acc, :node, v)
        _ -> acc
      end
    end)
  end

  # `elixir 1.17.3-otp-27` also says which OTP major the project wants.
  defp put_otp(acc, version) do
    case Regex.run(~r/-otp-(\d+)\z/, version) do
      [_, major] -> Map.put_new(acc, :otp, major)
      _ -> acc
    end
  end

  defp put_version(acc, key, version) do
    version = String.replace(version, ~r/-otp-\d+\z/, "")
    if Regex.match?(@version_re, version), do: Map.put(acc, key, version), else: acc
  end

  defp generated_containerfile(%{erlang: erlang, elixir: elixir, node: node}) do
    otp = erlang |> String.split(".") |> hd()

    """
    # Generated by Arbiter (bd-9r5jdt) from the default branch's .tool-versions.
    ARG ARBITER_BASE
    FROM docker.io/library/elixir:#{elixir}-otp-#{otp}-slim AS beam
    #{if node, do: "FROM docker.io/library/node:#{node}-bookworm-slim AS node\n", else: ""}\
    FROM ${ARBITER_BASE}
    COPY --from=beam /usr/local/ /usr/local/
    #{if node, do: node_layer(), else: ""}\
    """
  end

  defp node_layer do
    """
    COPY --from=node /usr/local/bin/node /usr/local/bin/node
    COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
    RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \\
     && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
    """
  end

  # -- digest pinning ----------------------------------------------------------

  @doc """
  Rewrite every external `FROM` in `text` to `ref@sha256:…`.

  Returns the pinned text and the `{ref, digest}` pairs that were resolved.
  Errors: `{:unpinned_base, ref, reason}` for a ref the resolver could not pin
  or one reached through a build arg other than `ARBITER_BASE` (or an external
  `COPY --from=` that is not digest-pinned), `:no_from` for a file with no
  `FROM`.
  """
  @spec pin(String.t(), (String.t() -> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t(), [{String.t(), String.t()}]} | {:error, term()}
  def pin(text, resolver) when is_binary(text) do
    lines = String.split(text, "\n")

    result =
      Enum.reduce_while(lines, {[], MapSet.new(), [], 0}, fn line, {out, stages, pins, froms} ->
        case pin_line(line, stages, resolver) do
          {:ok, new_line, stages, new_pins, from?} ->
            {:cont,
             {[new_line | out], stages, pins ++ new_pins, froms + if(from?, do: 1, else: 0)}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:error, _} = error -> error
      {_out, _stages, _pins, 0} -> {:error, :no_from}
      {out, _stages, pins, _froms} -> {:ok, out |> Enum.reverse() |> Enum.join("\n"), pins}
    end
  end

  defp pin_line(line, stages, resolver) do
    cond do
      from = Regex.named_captures(@from_re, line) ->
        pin_from(from, stages, resolver)

      match = Regex.run(@copy_from_re, line) ->
        check_copy_from(Enum.at(match, 1), stages, line)

      true ->
        {:ok, line, stages, [], false}
    end
  end

  defp pin_from(from, stages, resolver) do
    alias_name = if from["alias"] == "", do: nil, else: from["alias"]
    stages = if alias_name, do: MapSet.put(stages, alias_name), else: stages

    case pin_ref(from["ref"], stages, resolver) do
      {:ok, pinned, pins} ->
        as = if alias_name, do: " AS #{alias_name}", else: ""

        {:ok, from["prefix"] <> from["flags"] <> pinned <> as <> from["trail"], stages, pins,
         true}

      {:error, _} = error ->
        error
    end
  end

  defp pin_ref(ref, stages, resolver) do
    cond do
      ref in ["${ARBITER_BASE}", "$ARBITER_BASE"] -> {:ok, ref, []}
      String.contains?(ref, "$") -> {:error, {:unpinned_base, ref, :build_arg}}
      String.downcase(ref) == "scratch" -> {:ok, ref, []}
      MapSet.member?(stages, ref) -> {:ok, ref, []}
      Regex.match?(@sha_re, ref) -> {:ok, ref, []}
      true -> resolve_ref(ref, resolver)
    end
  end

  defp resolve_ref(ref, resolver) do
    case resolver.(ref) do
      {:ok, "sha256:" <> hex = digest} when byte_size(hex) == 64 ->
        {:ok, "#{ref}@#{digest}", [{ref, digest}]}

      {:ok, other} ->
        {:error, {:unpinned_base, ref, {:bad_digest, other}}}

      {:error, reason} ->
        {:error, {:unpinned_base, ref, reason}}
    end
  end

  # `COPY --from=<stage|index|pinned image>`: anything else would pull an
  # unpinned image into the build.
  defp check_copy_from(source, stages, line) do
    cond do
      MapSet.member?(stages, source) -> {:ok, line, stages, [], false}
      Regex.match?(~r/\A\d+\z/, source) -> {:ok, line, stages, [], false}
      Regex.match?(@sha_re, source) -> {:ok, line, stages, [], false}
      true -> {:error, {:unpinned_base, source, :copy_from}}
    end
  end

  # -- reading the default branch ----------------------------------------------

  @doc """
  The ref a default branch is read from: `refs/remotes/origin/<branch>` if it
  exists, else `refs/heads/<branch>`.
  """
  @spec default_ref(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def default_ref(repo_path, branch) do
    if is_binary(branch) and Regex.match?(@branch_re, branch) and
         not String.contains?(branch, "..") do
      ["refs/remotes/origin/" <> branch, "refs/heads/" <> branch]
      |> Enum.find(&ref_exists?(repo_path, &1))
      |> case do
        nil -> {:error, {:no_default_branch, branch}}
        ref -> {:ok, ref}
      end
    else
      {:error, {:bad_branch, branch}}
    end
  end

  defp ref_exists?(repo_path, ref) do
    match?({_, 0}, git(repo_path, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]))
  end

  defp read_file(repo_path, ref, path) do
    case git(repo_path, ["cat-file", "blob", "#{ref}:#{path}"]) do
      {body, 0} -> {:ok, body}
      _ -> {:ok, nil}
    end
  end

  # sobelow_skip ["CI.System"]
  @doc false
  @spec git(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def git(repo_path, args) do
    case System.find_executable("git") do
      nil ->
        {"git: not found", 127}

      git ->
        bounded(@git_timeout_ms, fn ->
          ReleaseEnv.cmd(git, ["-C", repo_path | args], stderr_to_stdout: true)
        end)
    end
  end

  # -- podman ------------------------------------------------------------------

  @doc """
  Run `cmd` (`"podman"`, `"skopeo"`) through the `:runner` option, the
  `:worker_image_runner` application config, or for real. Returns
  `{output, status}`; a missing binary is `{"…: not found", 127}` and a timeout
  `{"… timed out …", 124}`.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(cmd, args, opts \\ []) do
    runner = Keyword.get(opts, :runner) || Application.get_env(:arbiter, :worker_image_runner)
    timeout = Keyword.get(opts, :timeout, @podman_timeout_ms)

    if runner do
      runner.(cmd, args, Keyword.take(opts, [:timeout, :cd]))
    else
      real_run(cmd, args, timeout)
    end
  end

  # sobelow_skip ["CI.System"]
  defp real_run(cmd, args, timeout) do
    case System.find_executable(cmd) do
      nil ->
        {"#{cmd}: not found", 127}

      path ->
        bounded(timeout, fn -> ReleaseEnv.cmd(path, args, stderr_to_stdout: true) end, label: cmd)
    end
  end

  defp bounded(timeout, fun, opts \\ []) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"#{Keyword.get(opts, :label, "git")} timed out after #{timeout} ms", 124}
    end
  end

  @doc "Whether `tag` is present in local storage."
  @spec exists?(String.t(), keyword()) :: boolean()
  def exists?(tag, opts \\ []), do: match?({_, 0}, run("podman", ["image", "exists", tag], opts))

  # -- list / prune ------------------------------------------------------------

  @type image :: %{
          tag: String.t(),
          name: String.t(),
          hash: String.t(),
          kind: :base | :toolchain,
          id: String.t(),
          created: integer(),
          size: integer()
        }

  @doc "Arbiter's local dev images, newest first."
  @spec list(keyword()) :: {:ok, [image()]} | {:error, String.t()}
  def list(opts \\ []) do
    args = ["images", "--filter", "label=#{@label}", "--format", "json"]

    case run("podman", args, opts) do
      {out, 0} -> parse_images(out)
      {out, status} -> {:error, "podman images exited #{status}: #{String.slice(out, 0, 300)}"}
    end
  end

  defp parse_images(out) do
    case Jason.decode(out) do
      {:ok, entries} when is_list(entries) ->
        images =
          entries
          |> Enum.flat_map(&image_entries/1)
          |> Enum.sort_by(& &1.created, :desc)

        {:ok, images}

      _ ->
        {:error, "podman images returned unparsable output"}
    end
  end

  defp image_entries(%{"Names" => names} = entry) when is_list(names) do
    for tag <- names, parsed = parse_tag(tag) do
      Map.merge(parsed, %{
        tag: tag,
        id: entry["Id"],
        created: entry["Created"] || 0,
        size: entry["Size"] || 0
      })
    end
  end

  defp image_entries(_), do: []

  defp parse_tag(@registry <> "/" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [name, hash] when name != "" and hash != "" ->
        %{name: name, hash: hash, kind: if(name == "base", do: :base, else: :toolchain)}

      _ ->
        nil
    end
  end

  defp parse_tag(_), do: nil

  @doc """
  Remove stale dev images: per image name, everything but the newest `:keep`
  tags (default #{@default_keep}: the current one and the one before the last
  base refresh), and never a tag in `:keep_tags`. Toolchain layers go before
  bases. `podman rmi` is never forced, so an image a container uses, or a base
  a toolchain layer still builds on, is reported under `:failed` and kept.
  """
  @spec prune(keyword()) ::
          {:ok, %{removed: [String.t()], failed: [{String.t(), String.t()}]}}
          | {:error, String.t()}
  def prune(opts \\ []) do
    keep = Keyword.get(opts, :keep, @default_keep)
    keep_tags = Keyword.get(opts, :keep_tags, [])

    with {:ok, images} <- list(opts) do
      stale =
        images
        |> Enum.group_by(& &1.name)
        |> Enum.flat_map(fn {_name, group} ->
          group |> Enum.sort_by(& &1.created, :desc) |> Enum.drop(keep)
        end)
        |> Enum.reject(&(&1.tag in keep_tags))
        |> Enum.sort_by(&if(&1.kind == :toolchain, do: 0, else: 1))

      {removed, failed} =
        Enum.reduce(stale, {[], []}, fn image, {removed, failed} ->
          case run("podman", ["rmi", image.tag], opts) do
            {_, 0} ->
              Logger.info("Worker.Image: pruned #{image.tag}")
              {[image.tag | removed], failed}

            {out, _} ->
              {removed, [{image.tag, String.slice(String.trim(out), 0, 200)} | failed]}
          end
        end)

      {:ok, %{removed: Enum.reverse(removed), failed: Enum.reverse(failed)}}
    end
  end
end
