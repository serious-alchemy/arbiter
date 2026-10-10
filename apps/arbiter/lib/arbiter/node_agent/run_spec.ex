defmodule Arbiter.NodeAgent.RunSpec do
  @moduledoc """
  The declarative run spec a node accepts in `assign`
  (`docs/design/remote-workers.md` §7.1), and the allowlist that refuses
  anything else.

  The primary never sends a `podman` argv. It sends *what* the run needs and
  the agent builds the container with `Arbiter.Worker.Container.wrap/2`, so the
  hardening (read-only root, dropped capabilities, `no-new-privileges`, a
  network that is `none` unless bridged) is the same code as a local spawn and a
  compromised or mistaken primary cannot turn the node into an arbitrary-
  container host. `validate/1` is pure and total: every shape that is not
  spelled out here is `{:error, {:refused, reason}}`.

  ## Fields (string keys, JSON-safe)

  | key | meaning |
  |-----|---------|
  | `version` | `1` |
  | `run`, `task`, `name` | the run id, the ticket id and the container name (`arb-…`) |
  | `install` | the primary's install id (label `arbiter.install`; reaping, RW12) |
  | `image` | `%{"tag" => tag, "plan" => plan \| nil}`; a plan is built on the node. A registry node (A2) gets `"ref"`, a digest-pinned reference the primary pushed, and no plan |
  | `cwd` | the container-side working directory (the primary's own path: path transparency) |
  | `mounts` | `[%{"kind" => k, "path" => container path, …}]`; kinds below |
  | `bridges` | `[%{"name" => n, "path" => container path}]`: the per-run sockets (RW10) |
  | `env` | non-secret environment, `%{name => value}` |
  | `secrets` | `%{name => value}`: delivered by a tmpfs file, **never** as `-e NAME` (§11, RW2/U13) |
  | `limits` | `%{"memory", "memory_swap", "cpus"}`, each emitted only when its cgroup controller is delegated |
  | `network` | `"none"` (default) or `"pasta"` |
  | `services` | test-services definitions (`Arbiter.Worker.TestServices` specs), or `[]` |
  | `command` | the argv run inside the container |
  | `checkout` | optional (RW11): `%{"branch", "base", "interval_s"}`. The agent seeds the `worktree` mount as a shadow clone from the primary (`GET /nodes/runs/<run>/seed.bundle`), uploads a snapshot bundle every `interval_s` (default 300, 10..3600) and at exit. `"read_only": true` (a reviewer's clone, bd-cgdhlu) seeds the same way but uploads no bundle, only the session transcripts |
  | `extra_args` | must be absent or `[]`: there is no way to pass a flag |

  Mount kinds: `worktree`, `home`, `config_dir`, `tmp` (directories the agent
  owns under its own root, mounted at `path`), `cli` (`name`, `sha256`, `path`
  under `/opt/arbiter/cli`: a content-addressed file the node fetches and
  caches), `prompt` (`content` base64, mounted read-only at `path`) and, on
  `config_dir`, optional `files` (`settings.json`, `CLAUDE.md`, base64) and an
  optional `session` (bd-4ic681: `%{"path", "bytes", "sha256"}`, the transcript of
  the session a `--resume` command continues, at `projects/<cwd slug>/<sid>.jsonl`;
  the agent fetches it from the primary, `GET /nodes/runs/<run>/session`, unless
  the run's config dir already holds it). The
  `worktree` mount takes optional `files` too (bd-8y8ztm): the untracked agent
  config the primary injects into a worktree (`.mcp.json`, `.claude/skills/…`,
  base64, relative paths under an allowlist of roots) that a git bundle cannot
  carry; the agent writes them into the shadow clone after seeding it. The
  host side of every mount is **resolved by the agent**; the spec never names a
  host path.
  """

  defstruct [
    :run,
    :task,
    :name,
    :install,
    :image,
    :cwd,
    :command,
    :network,
    :checkout,
    mounts: [],
    bridges: [],
    env: %{},
    secrets: %{},
    limits: %{},
    services: [],
    labels: %{}
  ]

  @type t :: %__MODULE__{}

  @allowed_keys ~w(version run task name install image cwd mounts bridges env secrets limits network services command extra_args checkout)
  @mount_kinds ~w(worktree home config_dir tmp cli prompt)
  @dir_kinds ~w(worktree home config_dir tmp)
  @config_files ~w(settings.json CLAUDE.md)
  # What a worktree mount may be seeded with: the roots of the agent config
  # `Arbiter.Worker.Dispatch` writes into a worktree and git does not carry.
  @worktree_file_roots [".mcp.json", ".claude/skills"]
  @max_worktree_file_bytes 1_048_576
  @max_worktree_files_bytes 4_194_304
  @max_worktree_files 256
  @run_re ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @name_re ~r/\Aarb-[A-Za-z0-9][A-Za-z0-9_.-]{0,59}\z/
  @env_re ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @sha_re ~r/\A[0-9a-f]{64}\z/
  @tag_re ~r/\A[a-z0-9][a-z0-9._\/:-]{0,200}\z/
  @cli_name_re ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @cli_dir "/opt/arbiter/cli/"
  @max_secret_bytes 65_536
  @max_prompt_bytes 4_194_304
  @max_session_bytes 536_870_912
  @session_path_re ~r/\Aprojects\/[A-Za-z0-9-]{1,255}\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\.jsonl\z/
  # Container-side paths a spec may never mount over.
  @forbidden_dest ["/proc", "/sys", "/dev", "/run/arbiter", "/etc"]

  # What no spec may ask podman for, named so the refusal says which.
  @unsafe_flags ~w(--privileged --cap-add --device --userns --pid --network --ipc --uts
                   --security-opt --volume -v --mount --cgroupns --group-add --user -u --entrypoint)

  @doc "The roots a `worktree` mount's `files` may be written under."
  @spec worktree_file_roots() :: [String.t()]
  def worktree_file_roots, do: @worktree_file_roots

  @doc "The flags no spec can pass; asking for one is refused as `{:unsafe_flag, flag}`."
  @spec unsafe_flags() :: [String.t()]
  def unsafe_flags, do: @unsafe_flags

  @doc "Validate a decoded `assign` spec."
  @spec validate(term()) :: {:ok, t()} | {:error, {:refused, term()}}
  def validate(spec) when is_map(spec) do
    with :ok <- known_keys(spec),
         :ok <- version(spec),
         :ok <- extra_args(spec["extra_args"]),
         {:ok, run} <- match(spec, "run", @run_re),
         {:ok, name} <- match(spec, "name", @name_re),
         {:ok, task} <- optional_string(spec, "task"),
         {:ok, install} <- optional_string(spec, "install"),
         {:ok, image} <- image(spec["image"]),
         {:ok, cwd} <- path(spec["cwd"], "cwd"),
         {:ok, mounts} <- mounts(spec["mounts"] || []),
         {:ok, bridges} <- bridges(spec["bridges"] || []),
         {:ok, env} <- env_map(spec["env"] || %{}, "env"),
         {:ok, secrets} <- secrets(spec["secrets"] || %{}),
         :ok <- disjoint(env, secrets),
         {:ok, limits} <- limits(spec["limits"] || %{}),
         {:ok, network} <- network(spec["network"]),
         {:ok, services} <- services(spec["services"] || []),
         {:ok, command} <- command(spec["command"]),
         {:ok, checkout} <- checkout(spec["checkout"]),
         :ok <- needs_kinds(mounts, ["worktree"]) do
      {:ok,
       %__MODULE__{
         run: run,
         task: task,
         name: name,
         install: install,
         image: image,
         cwd: cwd,
         mounts: mounts,
         bridges: bridges,
         env: env,
         secrets: secrets,
         limits: limits,
         network: network,
         services: services,
         command: command,
         checkout: checkout
       }}
    end
  end

  def validate(_other), do: refuse(:not_a_map)

  @doc "Whether `spec` names `secrets` (so a caller can avoid logging it)."
  @spec redact(map()) :: map()
  def redact(spec) when is_map(spec) do
    spec
    |> Map.replace(
      "secrets",
      Map.new(Map.get(spec, "secrets") || %{}, fn {k, _} -> {k, "[redacted]"} end)
    )
    |> Map.replace("mounts", Enum.map(Map.get(spec, "mounts") || [], &redact_mount/1))
  end

  defp redact_mount(%{"content" => _} = mount), do: Map.put(mount, "content", "[redacted]")
  defp redact_mount(mount), do: mount

  # -- allowlist ------------------------------------------------------------------

  defp known_keys(spec) do
    case Enum.find(Map.keys(spec), &(&1 not in @allowed_keys)) do
      nil -> :ok
      key -> refuse({:unknown_field, to_string(key)})
    end
  end

  defp version(%{"version" => 1}), do: :ok
  defp version(%{"version" => other}), do: refuse({:unsupported_version, other})
  defp version(_), do: refuse({:missing, "version"})

  defp extra_args(nil), do: :ok
  defp extra_args([]), do: :ok

  defp extra_args([flag | _]) when is_binary(flag) do
    name = flag |> String.split("=", parts: 2) |> hd()

    if name in @unsafe_flags,
      do: refuse({:unsafe_flag, name}),
      else: refuse({:extra_args_not_allowed, flag})
  end

  defp extra_args(_), do: refuse({:extra_args_not_allowed, :malformed})

  defp match(spec, key, re) do
    case spec[key] do
      value when is_binary(value) ->
        if Regex.match?(re, value), do: {:ok, value}, else: refuse({:bad_value, key})

      _ ->
        refuse({:missing, key})
    end
  end

  defp optional_string(spec, key) do
    case spec[key] do
      nil -> {:ok, nil}
      v when is_binary(v) and byte_size(v) <= 200 -> label_safe(v, key)
      _ -> refuse({:bad_value, key})
    end
  end

  defp label_safe(value, key),
    do:
      if(String.contains?(value, ["\n", "\0", "\r"]),
        do: refuse({:bad_value, key}),
        else: {:ok, value}
      )

  defp image(%{"tag" => tag} = image) when is_binary(tag) do
    if String.starts_with?(tag, "-") or not Regex.match?(@tag_re, tag) do
      refuse({:bad_value, "image.tag"})
    else
      with {:ok, plan} <- plan(image["plan"]),
           {:ok, ref} <- image_ref(image) do
        {:ok, Map.merge(%{tag: tag, plan: plan}, ref)}
      end
    end
  end

  defp image(_), do: refuse({:missing, "image"})

  # A2: a registry node pulls the digest-pinned `ref` the primary pushed; the
  # tag stays for the labels. Absent for a build node.
  @digest_ref_re ~r/\A[a-z0-9][a-z0-9.:_\/-]{0,200}@sha256:[0-9a-f]{64}\z/

  defp image_ref(%{"ref" => ref}) do
    if is_binary(ref) and Regex.match?(@digest_ref_re, ref),
      do: {:ok, %{ref: ref}},
      else: refuse({:bad_value, "image.ref"})
  end

  defp image_ref(_), do: {:ok, %{}}

  defp plan(nil), do: {:ok, nil}

  defp plan(
         %{"tag" => tag, "name" => name, "hash" => hash, "containerfile" => text, "base" => base} =
           plan
       )
       when is_binary(tag) and is_binary(name) and is_binary(hash) and is_binary(text) and
              is_map(base) do
    with {:ok, args} <- build_args(plan["build_args"] || []),
         {:ok, base} <- layer(base) do
      {:ok,
       %{
         tag: tag,
         name: name,
         hash: hash,
         containerfile: text,
         build_args: args,
         base: base
       }}
    end
  end

  defp plan(_), do: refuse({:bad_value, "image.plan"})

  defp layer(%{"tag" => tag, "name" => name, "hash" => hash, "containerfile" => text})
       when is_binary(tag) and is_binary(name) and is_binary(hash) and is_binary(text),
       do: {:ok, %{tag: tag, name: name, hash: hash, containerfile: text}}

  defp layer(_), do: refuse({:bad_value, "image.plan.base"})

  defp build_args(args) when is_list(args) do
    if Enum.all?(args, &match?([k, v] when is_binary(k) and is_binary(v), &1)),
      do: {:ok, Enum.map(args, fn [k, v] -> {k, v} end)},
      else: refuse({:bad_value, "image.plan.build_args"})
  end

  defp build_args(_), do: refuse({:bad_value, "image.plan.build_args"})

  # -- paths ------------------------------------------------------------------------

  defp path(value, key) when is_binary(value) do
    cond do
      not String.starts_with?(value, "/") -> refuse({:bad_path, key})
      String.contains?(value, [":", ",", "\0", "\n"]) -> refuse({:bad_path, key})
      ".." in Path.split(value) -> refuse({:bad_path, key})
      forbidden?(value) -> refuse({:forbidden_path, value})
      true -> {:ok, Path.expand(value)}
    end
  end

  defp path(_, key), do: refuse({:missing, key})

  defp forbidden?(path),
    do: Enum.any?(@forbidden_dest, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  defp mounts(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn mount, {:ok, acc} ->
      case mount(mount) do
        {:ok, m} -> {:cont, {:ok, [m | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> unique_kinds(Enum.reverse(acc))
      error -> error
    end
  end

  defp mounts(_), do: refuse({:bad_value, "mounts"})

  defp mount(%{"kind" => kind} = mount) when kind in @mount_kinds do
    with {:ok, path} <- path(mount["path"], "mounts.#{kind}.path") do
      mount_for(kind, path, mount)
    end
  end

  defp mount(%{"kind" => kind}), do: refuse({:unknown_mount_kind, to_string(kind)})
  defp mount(_), do: refuse({:bad_value, "mounts"})

  # A config dir may be seeded with the install's generated settings and memory
  # (the two files `ContainerSpawn` seeds locally), by name from an allowlist, and may
  # name the session transcript a `--resume` run continues (bd-4ic681), which the agent
  # fetches from the primary into it before the container starts.
  defp mount_for("config_dir", path, mount) do
    with {:ok, files} <- config_files(Map.get(mount, "files")),
         {:ok, session} <- config_session(Map.get(mount, "session")) do
      {:ok,
       %{kind: "config_dir", path: path}
       |> put_present(:files, files)
       |> put_present(:session, session)}
    end
  end

  defp mount_for("worktree", path, %{"files" => files}) when is_map(files) do
    with {:ok, files} <- worktree_files(files),
         do: {:ok, %{kind: "worktree", path: path, files: files}}
  end

  defp mount_for(kind, path, _mount) when kind in @dir_kinds, do: {:ok, %{kind: kind, path: path}}

  defp mount_for("cli", path, %{"name" => name, "sha256" => sha})
       when is_binary(name) and is_binary(sha) do
    cond do
      not Regex.match?(@cli_name_re, name) -> refuse({:bad_value, "mounts.cli.name"})
      not Regex.match?(@sha_re, sha) -> refuse({:bad_value, "mounts.cli.sha256"})
      not String.starts_with?(path, @cli_dir) -> refuse({:forbidden_path, path})
      true -> {:ok, %{kind: "cli", path: path, name: name, sha256: sha}}
    end
  end

  defp mount_for("cli", _path, _mount), do: refuse({:bad_value, "mounts.cli"})

  defp mount_for("prompt", path, %{"content" => content}) when is_binary(content) do
    case Base.decode64(content) do
      {:ok, bytes} when byte_size(bytes) <= @max_prompt_bytes ->
        {:ok, %{kind: "prompt", path: path, content: bytes}}

      _ ->
        refuse({:bad_value, "mounts.prompt.content"})
    end
  end

  defp mount_for("prompt", _path, _mount), do: refuse({:bad_value, "mounts.prompt"})

  defp config_files(nil), do: {:ok, nil}

  defp config_files(files) when is_map(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn
      {name, content}, {:ok, acc} when name in @config_files and is_binary(content) ->
        case Base.decode64(content) do
          {:ok, bytes} when byte_size(bytes) <= 1_048_576 ->
            {:cont, {:ok, Map.put(acc, name, bytes)}}

          _ ->
            {:halt, refuse({:bad_value, "mounts.config_dir.files"})}
        end

      {name, _}, _ ->
        {:halt, refuse({:unknown_config_file, to_string(name)})}
    end)
  end

  defp config_files(_), do: refuse({:bad_value, "mounts.config_dir.files"})

  # Exactly one session JSONL at the slug of a cwd (`Usage.ClaudeSessionFile.project_slug/1`
  # leaves only letters, digits and `-`), never a path outside `projects/`.
  defp config_session(nil), do: {:ok, nil}

  defp config_session(%{"path" => path, "bytes" => bytes, "sha256" => sha})
       when is_binary(path) and is_integer(bytes) and bytes >= 0 and
              bytes <= @max_session_bytes and is_binary(sha) do
    if Regex.match?(@session_path_re, path) and Regex.match?(@sha_re, sha),
      do: {:ok, %{path: path, bytes: bytes, sha256: sha}},
      else: refuse({:bad_value, "mounts.config_dir.session"})
  end

  defp config_session(_), do: refuse({:bad_value, "mounts.config_dir.session"})

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp worktree_files(files) do
    decoded =
      Enum.reduce_while(files, {:ok, %{}}, fn
        {name, content}, {:ok, acc} when is_binary(name) and is_binary(content) ->
          with :ok <- worktree_file_name(name),
               {:ok, bytes} when byte_size(bytes) <= @max_worktree_file_bytes <-
                 Base.decode64(content) do
            {:cont, {:ok, Map.put(acc, name, bytes)}}
          else
            {:error, _} = error -> {:halt, error}
            _ -> {:halt, refuse({:bad_value, "mounts.worktree.files"})}
          end

        {name, _}, _ ->
          {:halt, refuse({:bad_worktree_file, to_string(name)})}
      end)

    with {:ok, map} <- decoded do
      total = map |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

      if map_size(map) <= @max_worktree_files and total <= @max_worktree_files_bytes,
        do: {:ok, map},
        else: refuse({:bad_value, "mounts.worktree.files"})
    end
  end

  # Relative, no `..`, no NUL, and under one of the allowlisted roots (exactly the
  # root, or a path below it): never `.git`, never a tracked source path.
  defp worktree_file_name(name) do
    segments = Path.split(name)

    ok? =
      name != "" and Path.type(name) == :relative and ".." not in segments and "." not in segments and
        not String.contains?(name, ["\0", "\n"]) and
        Enum.any?(@worktree_file_roots, &(name == &1 or String.starts_with?(name, &1 <> "/")))

    if ok?, do: :ok, else: refuse({:bad_worktree_file, name})
  end

  # One directory mount per kind; a second `worktree` is ambiguous, not a feature.
  defp unique_kinds(mounts) do
    dirs = for %{kind: k} <- mounts, k in @dir_kinds, do: k

    if dirs == Enum.uniq(dirs),
      do: {:ok, mounts},
      else: refuse({:duplicate_mount, "directory kind"})
  end

  defp needs_kinds(mounts, kinds) do
    present = Enum.map(mounts, & &1.kind)

    case Enum.find(kinds, &(&1 not in present)) do
      nil -> :ok
      kind -> refuse({:missing_mount, kind})
    end
  end

  defp bridges(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"name" => name, "path" => p}, {:ok, acc} when is_binary(name) ->
        with true <- Regex.match?(@cli_name_re, name),
             {:ok, path} <- path(p, "bridges.#{name}.path") do
          {:cont, {:ok, acc ++ [%{name: name, path: path}]}}
        else
          {:error, _} = error -> {:halt, error}
          false -> {:halt, refuse({:bad_value, "bridges.name"})}
        end

      _, _ ->
        {:halt, refuse({:bad_value, "bridges"})}
    end)
  end

  defp bridges(_), do: refuse({:bad_value, "bridges"})

  # -- env and secrets ----------------------------------------------------------------

  defp env_map(map, key) when is_map(map) do
    bad =
      Enum.find(map, fn {k, v} ->
        not (is_binary(k) and Regex.match?(@env_re, k) and is_binary(v) and
               not String.contains?(v, "\0"))
      end)

    if bad, do: refuse({:bad_env, key, elem(bad, 0)}), else: {:ok, map}
  end

  defp env_map(_, key), do: refuse({:bad_value, key})

  defp secrets(map) do
    with {:ok, map} <- env_map(map, "secrets") do
      total = map |> Enum.map(fn {k, v} -> byte_size(k) + byte_size(v) end) |> Enum.sum()
      if total <= @max_secret_bytes, do: {:ok, map}, else: refuse({:too_large, "secrets"})
    end
  end

  defp disjoint(env, secrets) do
    case Enum.find(Map.keys(secrets), &Map.has_key?(env, &1)) do
      nil -> :ok
      name -> refuse({:secret_also_env, name})
    end
  end

  # -- the rest ---------------------------------------------------------------------------

  defp limits(map) when is_map(map) do
    case Enum.find(Map.keys(map), &(&1 not in ~w(memory memory_swap cpus))) do
      nil -> {:ok, Map.new(map, fn {k, v} -> {limit_key(k), to_string(v)} end)}
      key -> refuse({:unknown_limit, to_string(key)})
    end
  end

  defp limits(_), do: refuse({:bad_value, "limits"})

  defp limit_key("memory"), do: :memory
  defp limit_key("memory_swap"), do: :memory_swap
  defp limit_key("cpus"), do: :cpus

  @ref_re ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/
  @checkout_keys ~w(branch base interval_s read_only)

  # RW11. The branch and base become ref names the agent writes in its own repos
  # and bundle refs, so they are held to a conservative subset of
  # `git check-ref-format`.
  defp checkout(nil), do: {:ok, nil}

  defp checkout(%{} = map) do
    with :ok <- known_checkout_keys(map),
         {:ok, branch} <- ref(map["branch"], "checkout.branch", required: true),
         {:ok, base} <- ref(map["base"], "checkout.base", required: false),
         {:ok, seconds} <- interval(map["interval_s"]),
         {:ok, read_only?} <- read_only(map["read_only"]) do
      {:ok, %{branch: branch, base: base, interval_ms: seconds * 1000, read_only?: read_only?}}
    end
  end

  defp checkout(_other), do: refuse({:bad_value, "checkout"})

  defp known_checkout_keys(map) do
    case Enum.find(Map.keys(map), &(&1 not in @checkout_keys)) do
      nil -> :ok
      key -> refuse({:unknown_key, "checkout." <> to_string(key)})
    end
  end

  defp ref(nil, key, required: true), do: refuse({:missing, key})
  defp ref(nil, _key, required: false), do: {:ok, nil}

  defp ref(value, key, _opts) when is_binary(value) do
    bad? =
      not Regex.match?(@ref_re, value) or String.contains?(value, ["..", "//", "@{"]) or
        String.ends_with?(value, [".lock", "/", "."]) or
        String.contains?(value, ["/.", "./"])

    if bad?, do: refuse({:bad_value, key}), else: {:ok, value}
  end

  defp ref(_value, key, _opts), do: refuse({:bad_value, key})

  defp read_only(nil), do: {:ok, false}
  defp read_only(flag) when is_boolean(flag), do: {:ok, flag}
  defp read_only(_), do: refuse({:bad_value, "checkout.read_only"})

  defp interval(nil), do: {:ok, 300}
  defp interval(s) when is_integer(s) and s in 10..3600, do: {:ok, s}
  defp interval(_), do: refuse({:bad_value, "checkout.interval_s"})

  defp network(nil), do: {:ok, :none}
  defp network("none"), do: {:ok, :none}
  defp network("pasta"), do: {:ok, :pasta}
  defp network(other), do: refuse({:bad_network, other})

  # Presets only: the node never takes a service definition (an image, a
  # command, tmpfs paths) from the wire. `{:postgres, opts}` / `{:s3, opts}` are
  # the terms `Arbiter.Worker.TestServices.resolve/1` expands.
  defp services(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn service, {:ok, acc} ->
      case service(service) do
        {:ok, term} -> {:cont, {:ok, acc ++ [term]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp services(_), do: refuse({:bad_value, "services"})

  defp service(%{"preset" => "postgres"} = s) do
    version = s["version"] || 16
    database = s["database"] || "app_test"

    if is_integer(version) and version in 9..30 and is_binary(database) and
         Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/, database),
       do: {:ok, {:postgres, version: version, database: database}},
       else: refuse({:bad_value, "services.postgres"})
  end

  defp service(%{"preset" => "s3"} = s) do
    case s["image"] do
      nil ->
        {:ok, {:s3, []}}

      image when is_binary(image) ->
        if Regex.match?(@tag_re, image),
          do: {:ok, {:s3, image: image}},
          else: refuse({:bad_value, "services.s3.image"})

      _ ->
        refuse({:bad_value, "services.s3.image"})
    end
  end

  defp service(other), do: refuse({:unsupported_service, inspect(other, limit: 3)})

  defp command([exe | _] = argv) when is_binary(exe) do
    if Enum.all?(argv, &(is_binary(&1) and not String.contains?(&1, "\0"))),
      do: {:ok, argv},
      else: refuse({:bad_value, "command"})
  end

  defp command(_), do: refuse({:missing, "command"})

  defp refuse(reason), do: {:error, {:refused, reason}}
end
