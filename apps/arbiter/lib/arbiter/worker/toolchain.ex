defmodule Arbiter.Worker.Toolchain do
  @moduledoc """
  The Elixir/Erlang a worker runs on is the one its repo pins, never the one that
  happens to be on the host (bd-3fnqi8, GitHub #962).

  A repo declares its toolchain in `.tool-versions` (`erlang`, `elixir`). Where a
  run executes decides how the pin is honoured:

    * **Container runs** (podman locally, a remote node, a cluster pod): the image
      is built from the default branch's `.tool-versions`, or from the repo's
      `.arbiter/Containerfile` (`Arbiter.Worker.Image`). `check_containerfile/2`
      is the guard that keeps the two from disagreeing, and an unusable pin is an
      error there instead of a silent fall back to the configured default.
    * **Host runs** (bwrap, or no sandbox): `env/3` puts the pinned
      `elixir`/`erlang` install dirs first on the child's `PATH`. The installs
      live in the mise (or asdf) data dir keyed by version, so they are shared by
      every run; a version that is not there yet is installed with `mise install`
      (`provision`), once, single-flight. Then `elixir --version` is run on the
      resulting `PATH` and must report the pinned Elixir and OTP major.

  ## Fail closed

  A pinned version that cannot be provided is `{:error, {:toolchain_unavailable,
  message}}`, and the caller refuses the run with it. There is no fallback to
  `/usr/local/bin/elixir` or a mise shim: not installed and not installable, an
  install that reports another runtime, a pin that is not a plain version
  (`system`, `latest`, `ref:<branch|sha>`, `path:…`), all fail. An erlang
  `ref:OTP-X.Y.Z` pin is the git tag of release X.Y.Z and is normalised to the
  plain version `X.Y.Z`. A worktree with no
  `elixir`/`erlang` pin is the only case that leaves `PATH` alone.

  The pin is read from the worktree's own `.tool-versions`, so a branch that
  bumps the runtime is gated on the runtime it bumps to.

  ## One Mix home per toolchain

  Hex is compiled BEAM, and adjacent OTP majors cannot share it: OTP 29 refuses
  an OTP-27 Hex (`please re-compile this module with an Erlang/OTP 29
  compiler`), and OTP 27 cannot load an OTP-29 one. Mix keeps its archives in
  `$MIX_HOME/archives`, which on a host is `~/.mix/archives` for every run, so
  whichever run last ran `mix local.hex` decided which repos could use Hex
  (GitHub #1299). A pinned run therefore also gets its own `MIX_HOME`,
  `<base>/otp-<major>` (`<base>/elixir-<version>` when the pin names no OTP
  major), and Hex and Rebar are installed there once per toolchain
  (`mix local.hex --force`, `mix local.rebar --force` on the pinned `PATH`),
  single-flight: concurrent first runs on one pin queue on a lock, and the
  later ones find it seeded. `HEX_HOME` is left alone: the package cache does
  not depend on the runtime. A seed that fails (offline host) is logged and not
  recorded, the run still starts, and the next run on that toolchain tries
  again. An unpinned worktree keeps the host's `MIX_HOME`.

  The seed is the only writer: workers are denied `mix local.hex`,
  `mix local.rebar` and `mix archive.install|uninstall`
  (`Arbiter.Agents.Claude.Security`, `:no_outside_writes`).

  ## Options (all for tests, except where noted)

    * `:roots` — install roots to search, each laid out `<root>/<tool>/<version>/bin`
      (default: mise's `installs` dir, then asdf's; `config :arbiter,
      :worker_toolchain_roots` overrides).
    * `:provision?` — default `config :arbiter, :worker_toolchain_provision` (`true`).
    * `:provision` — `([\"erlang@29.1.1\", …] -> :ok | {:error, term})`, default `mise install`.
    * `:runner` — `(path -> {output, status})` running `elixir --version`.
    * `:mix_base` — the dir holding one Mix home per toolchain (default `config
      :arbiter, :worker_toolchain_mix_base`, else `~/.mix/toolchains`).
    * `:seed` — `(mix_home, path -> :ok | {:error, term})` installing Hex and
      Rebar into a Mix home; default runs `mix local.hex`/`local.rebar`.
      `config :arbiter, :worker_toolchain_mix_seed, false` turns seeding off.
  """

  require Logger

  alias Arbiter.Worker.ReleaseEnv

  @elixir_re ~r/\A(\d+\.\d+(?:\.\d+)?)(?:-otp-(\d+))?\z/
  @erlang_re ~r/\A\d+(\.\d+){0,3}\z/
  @install_timeout_ms :timer.minutes(30)
  @verify_timeout_ms 60_000
  @seed_timeout_ms :timer.minutes(5)
  @seeded_marker ".arbiter-seeded"

  @type pins :: %{
          elixir: String.t() | nil,
          elixir_dir: String.t() | nil,
          erlang: String.t() | nil,
          otp: String.t() | nil
        }
  @type unavailable :: {:toolchain_unavailable, String.t()}

  @doc """
  The elixir/erlang pins of a `.tool-versions` text: `{:ok, pins}`, `{:ok, :none}`
  when it pins neither, or `{:error, {:unsupported_pin, tool, value}}` for a
  value that is not a plain version. Only the first version on a line counts.
  """
  @spec parse(String.t() | nil) :: {:ok, pins() | :none} | {:error, term()}
  def parse(nil), do: {:ok, :none}

  def parse(text) when is_binary(text) do
    raw =
      for line <- String.split(text, "\n"),
          [tool, version | _] <- [line |> String.split("#") |> hd() |> String.split()],
          tool in ["elixir", "erlang"],
          reduce: %{} do
        acc -> Map.put_new(acc, tool, version)
      end

    with {:ok, elixir} <- elixir_pin(raw["elixir"]),
         {:ok, erlang} <- erlang_pin(raw["erlang"]) do
      build_pins(elixir, erlang)
    end
  end

  defp elixir_pin(nil), do: {:ok, nil}

  defp elixir_pin(value) do
    case Regex.run(@elixir_re, value) do
      [_, version] -> {:ok, {version, value, nil}}
      [_, version, otp] -> {:ok, {version, value, otp}}
      nil -> {:error, {:unsupported_pin, "elixir", value}}
    end
  end

  defp erlang_pin(nil), do: {:ok, nil}

  # `ref:OTP-X.Y.Z` is the asdf-erlang / mise way to build the git tag of
  # release X.Y.Z, so it normalises to the plain version. Any other `ref:`
  # (branch, SHA) is a moving target and stays unsupported.
  defp erlang_pin(value) do
    plain =
      case Regex.run(~r/\Aref:OTP-(.+)\z/, value) do
        [_, version] -> version
        nil -> value
      end

    if Regex.match?(@erlang_re, plain),
      do: {:ok, plain},
      else: {:error, {:unsupported_pin, "erlang", value}}
  end

  defp build_pins(nil, nil), do: {:ok, :none}

  defp build_pins(elixir, erlang) do
    {version, dir, suffix_otp} = elixir || {nil, nil, nil}
    erlang_otp = erlang && erlang |> String.split(".") |> hd()

    {:ok, %{elixir: version, elixir_dir: dir, erlang: erlang, otp: erlang_otp || suffix_otp}}
  end

  @doc """
  `env` (a list of `{name, value}` pairs) with `PATH` prefixed by the pinned
  toolchain's bin dirs, for a host run in `worktree`; `env` unchanged when the
  worktree pins nothing. The base `PATH` is `env`'s own, else the server's. A
  pinned worktree also gets `MIX_HOME` set to its toolchain's own Mix home,
  seeded with Hex and Rebar (see the moduledoc).
  """
  @spec env(String.t(), [{String.t(), String.t() | false}], keyword()) ::
          {:ok, [{String.t(), String.t() | false}]} | {:error, unavailable()}
  def env(worktree, env, opts \\ []) when is_binary(worktree) and is_list(env) do
    case read_pins(worktree) do
      {:ok, :none} ->
        {:ok, env}

      {:ok, pins} ->
        with {:ok, dirs} <- locate(pins, opts),
             path = Enum.join(dirs ++ [base_path(env)], ":"),
             :ok <- verify(pins, path, opts) do
          mix_home = mix_home(pins, path, opts)

          {:ok,
           env
           |> List.keystore("PATH", 0, {"PATH", path})
           |> List.keystore("MIX_HOME", 0, {"MIX_HOME", mix_home})}
        end

      {:error, {:unsupported_pin, tool, value}} ->
        unavailable("#{tool} is pinned to #{inspect(value)}, which is not a plain version", nil)
    end
  end

  defp read_pins(worktree) do
    case File.read(Path.join(worktree, ".tool-versions")) do
      {:ok, text} -> parse(text)
      {:error, _} -> {:ok, :none}
    end
  end

  defp base_path(env) do
    case List.keyfind(env, "PATH", 0) do
      {_, path} when is_binary(path) -> path
      _ -> System.get_env("PATH") || ""
    end
  end

  # -- locating and provisioning -----------------------------------------------

  defp locate(pins, opts) do
    roots = roots(opts)

    case find(pins, roots) do
      {:ok, dirs} ->
        {:ok, dirs}

      {:missing, missing} ->
        if Keyword.get_lazy(opts, :provision?, &provision?/0),
          do: provision_and_locate(pins, roots, missing, opts),
          else:
            unavailable(
              "#{describe(missing)} not installed under #{Enum.join(roots, ", ")}",
              pins
            )
    end
  end

  defp provision_and_locate(pins, roots, missing, opts) do
    provision = Keyword.get(opts, :provision, &mise_install/1)

    case provision.(tools(pins)) do
      :ok ->
        case find(pins, roots) do
          {:ok, dirs} ->
            {:ok, dirs}

          {:missing, still} ->
            unavailable("#{describe(still)} still not installed after install", pins)
        end

      {:error, reason} ->
        unavailable(
          "#{describe(missing)} not installed and could not be installed: #{reason_text(reason)}",
          pins
        )
    end
  end

  defp find(pins, roots) do
    wanted = wanted(pins)

    found =
      Enum.map(wanted, fn {tool, version} -> {tool, version, find_bin(roots, tool, version)} end)

    case Enum.filter(found, fn {_, _, bin} -> is_nil(bin) end) do
      [] -> {:ok, Enum.map(found, fn {_, _, bin} -> bin end)}
      missing -> {:missing, Enum.map(missing, fn {tool, version, _} -> "#{tool} #{version}" end)}
    end
  end

  # Elixir first on PATH, then Erlang.
  defp wanted(pins) do
    Enum.reject([{"elixir", pins.elixir_dir}, {"erlang", pins.erlang}], fn {_, v} -> is_nil(v) end)
  end

  defp tools(pins),
    do: for({tool, version} <- Enum.reverse(wanted(pins)), do: "#{tool}@#{version}")

  defp find_bin(roots, tool, version) do
    exe = if tool == "elixir", do: "elixir", else: "erl"

    Enum.find_value(roots, fn root ->
      bin = Path.join([root, tool, version, "bin"])
      if File.regular?(Path.join(bin, exe)), do: bin
    end)
  end

  defp roots(opts) do
    case Keyword.get(opts, :roots) || Application.get_env(:arbiter, :worker_toolchain_roots) do
      roots when is_list(roots) and roots != [] -> roots
      _ -> default_roots()
    end
  end

  defp default_roots do
    home = System.get_env("HOME") || System.user_home() || "/"

    mise =
      System.get_env("MISE_DATA_DIR") ||
        Path.join(System.get_env("XDG_DATA_HOME") || Path.join(home, ".local/share"), "mise")

    asdf = System.get_env("ASDF_DATA_DIR") || Path.join(home, ".asdf")
    [Path.join(mise, "installs"), Path.join(asdf, "installs")]
  end

  defp provision?, do: Application.get_env(:arbiter, :worker_toolchain_provision, true)

  # `mise install tool@version…` by explicit name, so no config file needs trusting.
  # Single-flight across runs on this node: the lock is the tool list, the second
  # caller finds the install when it gets the lock.
  defp mise_install(tools) do
    case System.find_executable("mise") do
      nil ->
        {:error, "mise is not installed on this host"}

      mise ->
        :global.trans(
          {{__MODULE__, tools}, self()},
          fn -> run_mise(mise, tools) end,
          [node()],
          :infinity
        )
    end
  end

  defp run_mise(mise, tools) do
    task =
      Task.async(fn ->
        ReleaseEnv.cmd(mise, ["install", "--yes" | tools], stderr_to_stdout: true)
      end)

    case Task.yield(task, @install_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, "mise install #{Enum.join(tools, " ")} exited #{status}: #{tail(output)}"}

      nil ->
        {:error, "mise install #{Enum.join(tools, " ")} timed out"}

      {:exit, reason} ->
        {:error, inspect(reason)}
    end
  end

  # -- the toolchain's own Mix home ------------------------------------------------

  # Keyed by OTP major: Hex (and every archive) is compiled BEAM, valid for the
  # major it was built on. A pin that names no OTP major runs on whatever OTP
  # the host has, so it is keyed by the Elixir it pins instead.
  defp mix_home(pins, path, opts) do
    key = if pins.otp, do: "otp-#{pins.otp}", else: "elixir-#{pins.elixir_dir}"
    mix_home = Path.join(mix_base(opts), key)
    ensure_seeded(mix_home, path, opts)
    mix_home
  end

  defp mix_base(opts) do
    case Keyword.get(opts, :mix_base) || Application.get_env(:arbiter, :worker_toolchain_mix_base) do
      base when is_binary(base) and base != "" -> base
      _ -> Path.join([System.get_env("HOME") || System.user_home() || "/", ".mix", "toolchains"])
    end
  end

  defp seed?(opts),
    do:
      Keyword.has_key?(opts, :seed) or
        Application.get_env(:arbiter, :worker_toolchain_mix_seed, true)

  defp ensure_seeded(mix_home, path, opts) do
    marker = Path.join(mix_home, @seeded_marker)

    if seed?(opts) and not File.exists?(marker) do
      seed = Keyword.get(opts, :seed, &mix_seed/2)

      # Single-flight across runs on this node, like `provision`: the lock is the
      # Mix home, and a caller that waited finds the marker when it gets the lock.
      :global.trans(
        {{__MODULE__, :seed, mix_home}, self()},
        fn -> seed_once(mix_home, marker, path, seed) end,
        [node()],
        :infinity
      )
    end

    :ok
  end

  defp seed_once(mix_home, marker, path, seed) do
    with false <- File.exists?(marker),
         :ok <- File.mkdir_p(mix_home),
         :ok <- seed.(mix_home, path),
         :ok <- File.write(marker, "") do
      :ok
    else
      true ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Toolchain: could not seed Hex/Rebar into #{mix_home}: #{reason_text(reason)}; " <>
            "runs on this toolchain start without them and the next one retries"
        )

        :error
    end
  end

  defp mix_seed(mix_home, path) do
    task =
      Task.async(fn ->
        ReleaseEnv.cmd(
          "sh",
          ["-c", "mix local.hex --force && mix local.rebar --force"],
          env: [{"PATH", path}, {"MIX_HOME", mix_home}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @seed_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_, 0}} -> :ok
      {:ok, {output, status}} -> {:error, "mix local.hex/rebar exited #{status}: #{tail(output)}"}
      nil -> {:error, "mix local.hex/rebar timed out"}
      {:exit, reason} -> {:error, inspect(reason)}
    end
  end

  # -- verification --------------------------------------------------------------

  defp verify(%{elixir: nil}, _path, _opts), do: :ok

  defp verify(pins, path, opts) do
    runner = Keyword.get(opts, :runner, &run_elixir_version/1)

    case runner.(path) do
      {output, 0} when is_binary(output) ->
        check_reported(pins, output)

      {output, status} ->
        unavailable("`elixir --version` exited #{status}: #{tail(to_string(output))}", pins)
    end
  end

  defp check_reported(pins, output) do
    elixir = output |> then(&Regex.run(~r/^Elixir (\d+\.\d+\.\d+)/m, &1)) |> pick()
    otp = output |> then(&Regex.run(~r/^Erlang\/OTP (\d+)/m, &1)) |> pick()

    cond do
      not elixir_matches?(pins.elixir, elixir) ->
        unavailable(
          "`elixir --version` reported Elixir #{elixir || "?"}, not the pinned #{pins.elixir}",
          pins
        )

      pins.otp && pins.otp != otp ->
        unavailable(
          "`elixir --version` reported OTP #{otp || "?"}, not the pinned OTP #{pins.otp}",
          pins
        )

      true ->
        :ok
    end
  end

  defp pick([_, value]), do: value
  defp pick(_), do: nil

  defp elixir_matches?(_pinned, nil), do: false
  defp elixir_matches?(pinned, actual), do: String.starts_with?(actual <> ".", pinned <> ".")

  # `elixir --version` starts a VM, so a verified (path, pin) pair is remembered.
  defp run_elixir_version(path) do
    key = {__MODULE__, :version, path}

    case :persistent_term.get(key, nil) do
      nil ->
        result = exec_elixir_version(path)
        if match?({_, 0}, result), do: :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp exec_elixir_version(path) do
    task =
      Task.async(fn ->
        ReleaseEnv.cmd("sh", ["-c", "elixir --version"],
          env: [{"PATH", path}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @verify_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"timed out", 124}
    end
  end

  # -- Containerfile / pin agreement ---------------------------------------------

  @from_re ~r/^\s*FROM\s+(?:--\S+\s+)*(?:[\w.-]+\/)*(?:hexpm\/)?elixir:(\d+\.\d+(?:\.\d+)?)-(?:erlang-|otp-)(\d+)/im

  @doc """
  `:ok`, or an error when `.tool-versions` pins something a run in the image can
  not honour: an unsupported pin, or a repo Containerfile whose `FROM
  …elixir:<v>-erlang-<o>` image is a different Elixir or OTP major than the pin.
  A Containerfile whose `FROM` cannot be read (a build arg, another base) is not
  judged.
  """
  @spec check_containerfile(String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def check_containerfile(tool_versions, containerfile) do
    case parse(tool_versions) do
      {:ok, :none} -> :ok
      {:ok, pins} -> compare_from(pins, containerfile)
      {:error, _} = error -> error
    end
  end

  defp compare_from(_pins, nil), do: :ok

  defp compare_from(pins, containerfile) do
    case Regex.scan(@from_re, containerfile) do
      [] ->
        :ok

      froms ->
        froms
        |> Enum.flat_map(fn [_, elixir, otp] -> mismatches(pins, elixir, otp) end)
        |> case do
          [] ->
            :ok

          problems ->
            {:error,
             {:containerfile_pin_mismatch,
              ".arbiter/Containerfile builds #{Enum.join(problems, "; ")}, but .tool-versions pins " <>
                "#{pin_text(pins)}. Update one to match the other; a worker must run on the pinned runtime."}}
        end
    end
  end

  defp mismatches(pins, elixir, otp) do
    elixir_bad =
      if pins.elixir && not elixir_matches?(pins.elixir, elixir),
        do: ["Elixir #{elixir} (pinned #{pins.elixir})"],
        else: []

    otp_bad =
      if pins.otp && pins.otp != otp, do: ["OTP #{otp} (pinned OTP #{pins.otp})"], else: []

    elixir_bad ++ otp_bad
  end

  defp pin_text(pins) do
    [pins.elixir && "elixir #{pins.elixir}", pins.otp && "OTP #{pins.otp}"]
    |> Enum.filter(& &1)
    |> Enum.join(" / ")
  end

  # -- messages ------------------------------------------------------------------

  defp unavailable(reason, pins) do
    pinned = if pins, do: " (.tool-versions pins #{describe_pins(pins)})", else: ""

    {:error,
     {:toolchain_unavailable,
      "worker toolchain unavailable: #{reason}#{pinned}. Refusing to run on the host's own " <>
        "elixir/erlang (for example /usr/local/bin); install the pinned version on this host " <>
        "(`mise install`) or run the workspace on the podman sandbox."}}
  end

  defp describe_pins(pins) do
    [pins.elixir_dir && "elixir #{pins.elixir_dir}", pins.erlang && "erlang #{pins.erlang}"]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp describe(missing), do: Enum.join(missing, ", ")

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp tail(output) do
    output |> to_string() |> String.trim() |> String.slice(-400, 400)
  end
end
