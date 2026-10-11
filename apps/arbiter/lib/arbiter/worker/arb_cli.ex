defmodule Arbiter.Worker.ArbCli do
  @moduledoc """
  The `arb` CLI inside a worker container (bd-59m96o).

  `arb` is an escript compiled by the host's Erlang/OTP, and a BEAM file loads
  only on the OTP release it was compiled on or a newer one: the OTP 28 and 29
  builds fail on a repo image that pins OTP 27.1.2 (emricare tonic) with
  `corrupt atom table`, and an image with no Erlang cannot run it at all.

  ## The build stamp

  `mix escript.build` writes the release the escript was compiled on into its
  comment line (`ArbiterCli.MixProject.escript/0`):

      #! /usr/bin/env escript
      %% arb-otp=29
      %%! -escript main nil_escript

  `built_otp/1` reads it. An escript built before the stamp existed has an
  empty comment line and reads as unknown.

  ## In the container

  The escript is mounted at `/opt/arbiter/cli/arb.escript` and `arb` on the
  image's `PATH` is `launcher/1`, a POSIX `sh` script that runs it on the
  first Erlang that can load it:

    1. the runtime Arbiter's worker base image carries for arb,
       `/opt/arbiter/otp` (`Arbiter.Worker.Image`), when its release is at
       least the stamp's;
    2. else the image's own `escript`, when its `erl` is at least the stamp's
       release (a probe that boots a VM, so only on this path);
    3. else nothing: exit 69 with a message naming both releases and the
       image's missing (or stale) runtime. The repo's own Erlang is never
       asked to load what it cannot.

  An escript with no stamp keeps the old behaviour: the runtime when there is
  one, else the image's `escript`, unprobed.
  """

  alias Arbiter.Config.Paths

  @stamp_re ~r/\A%%.*\barb-otp=(\d+)\b/
  @header_bytes 1024
  @runtime "/opt/arbiter/otp"
  @escript_dest "/opt/arbiter/cli/arb.escript"
  @launcher_dest "/opt/arbiter/cli/arb"

  # The launcher's body; `script` and `runtime` are assigned above it.
  @launcher_body ~S"""
  # Settings that would point the runtime's `erl` at another Erlang install.
  unset ERL_ROOTDIR ESCRIPT_EMULATOR

  # The release the escript was compiled on: its `%% arb-otp=NN` comment line.
  need=$(sed -n '2{s/^%%.*arb-otp=\([0-9][0-9]*\).*$/\1/p;q;}' "$script" 2>/dev/null)

  # The release an Erlang/OTP install carries (its `releases/NN`), if any.
  release_of() {
    found=
    for dir in "$1"/releases/[0-9]*; do
      [ -d "$dir" ] && found=${dir##*/}
    done
    echo "$found"
  }

  rt=$(release_of "$runtime")
  if [ -x "$runtime/bin/escript" ] && { [ -z "$need" ] || [ "${rt:-0}" -ge "$need" ]; }; then
    exec "$runtime/bin/escript" "$script" "$@"
  fi

  # No runtime that can load it: the image's own Erlang, when that one can.
  if [ -z "$need" ]; then
    exec escript "$script" "$@"
  fi
  own=$(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' 2>/dev/null)
  case $own in
    '' | *[!0-9]*) own= ;;
  esac
  if [ -n "$own" ] && [ "$own" -ge "$need" ]; then
    exec escript "$script" "$@"
  fi

  if [ -x "$runtime/bin/escript" ]; then
    why="its runtime for arb ($runtime) is ${rt:+OTP }${rt:-of an unknown release}: the image predates this arb, rebuild it (arb image build)"
  else
    why="it has no runtime for arb at $runtime: it is not built on Arbiter's current worker base image (FROM \${ARBITER_BASE})"
  fi
  echo "arb: cannot start: this arb was built on Erlang/OTP $need and an older release cannot load it; the image's own Erlang is ${own:+OTP }${own:-missing} and $why." >&2
  echo "arb: the arbiter MCP tools work without the CLI." >&2
  exit 69
  """

  @doc "Where Arbiter's worker base image keeps the Erlang/OTP runtime arb runs on."
  @spec runtime_dir() :: String.t()
  def runtime_dir, do: @runtime

  @doc """
  The OTP release of the runtime Arbiter's worker base image gives arb: the
  one the host's escript was built on (`built_otp/1` of `host_escript/1`, which
  takes `opts`), else, for an escript that predates the stamp or a host with
  none, the server's own.
  """
  @spec runtime_otp(keyword()) :: String.t()
  def runtime_otp(opts \\ []) do
    with path when is_binary(path) <- host_escript(opts),
         {:ok, otp} <- built_otp(path) do
      otp
    else
      _ -> System.otp_release()
    end
  end

  @doc """
  The host's `arb` escript, or `nil`: `:arb_path` when given (`nil` included),
  else `arb` on `PATH` (`:find_executable`, default `System.find_executable/1`),
  else where self-deploy installs it (`ARB_INSTALL_BIN`, default
  `~/.local/bin/arb`; `:installed_arb_path` overrides it, and a test that
  injects `:find_executable` gets no fallback, so the host's home never leaks
  into a spec). The coordinator's own `PATH` need not carry `arb` (a systemd
  service).
  """
  @spec host_escript(keyword()) :: Path.t() | nil
  def host_escript(opts \\ []) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    Keyword.get_lazy(opts, :arb_path, fn -> find.("arb") || installed_arb(opts) end)
  end

  defp installed_arb(opts) do
    path =
      case Keyword.fetch(opts, :installed_arb_path) do
        {:ok, p} ->
          p

        :error ->
          if Keyword.has_key?(opts, :find_executable), do: nil, else: default_installed_arb()
      end

    if is_binary(path) and File.regular?(path), do: path
  end

  defp default_installed_arb do
    case System.get_env("ARB_INSTALL_BIN") do
      p when is_binary(p) and p != "" -> Path.expand(p)
      _ -> Path.join(System.user_home!(), ".local/bin/arb")
    end
  end

  @doc """
  The `{host path, container path}` binds that give a container `arb`: the
  launcher as `#{@launcher_dest}` and the escript at `escript` beside it as
  `#{@escript_dest}`. Takes `launcher_file/1`'s options.
  """
  @spec mounts(Path.t(), keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def mounts(escript, opts \\ []) when is_binary(escript) do
    with {:ok, launcher} <- launcher_file(opts) do
      {:ok, [{launcher, @launcher_dest}, {escript, @escript_dest}]}
    end
  end

  @doc """
  `launcher/0` as an executable file on the host, named by its content under
  `:launcher_dir` (default `<image root>/cli`, `Arbiter.Config.Paths.image_root/0`)
  and written once: a container binds it read-only, and a remote node or a
  pushed image layer fetches it by hash like any other CLI file.
  """
  @spec launcher_file(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def launcher_file(opts \\ []) do
    text = launcher()
    dir = Keyword.get_lazy(opts, :launcher_dir, fn -> Path.join(Paths.image_root(), "cli") end)
    hash = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    path = Path.join(dir, "arb-launcher-" <> hash)

    if File.read(path) == {:ok, text} and executable?(path) do
      {:ok, path}
    else
      write_launcher(path, text)
    end
  end

  # Written aside and renamed into place, so a concurrent spawn never binds a
  # half-written launcher.
  defp write_launcher(path, text) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, text),
         :ok <- File.chmod(tmp, 0o755),
         :ok <- File.rename(tmp, path) do
      {:ok, path}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:arb_launcher_unwritable, path, reason}}
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) == 0o111
      _ -> false
    end
  end

  @doc """
  The OTP release the escript at `path` was compiled on, from its `arb-otp=`
  stamp. `:error` for a file that is missing, is not an escript, or predates
  the stamp.
  """
  @spec built_otp(Path.t()) :: {:ok, String.t()} | :error
  def built_otp(path) when is_binary(path) do
    with {:ok, ["#!" <> _, line2 | _]} <- header_lines(path),
         [_, otp] <- Regex.run(@stamp_re, line2) do
      {:ok, otp}
    else
      _ -> :error
    end
  end

  @doc """
  The `arb` a worker container runs: a `sh` launcher for the escript at
  `:script` (default `#{@escript_dest}`) on the runtime at `:runtime` (default
  `#{@runtime}`). See the moduledoc for the order it tries.
  """
  @spec launcher(keyword()) :: String.t()
  def launcher(opts \\ []) do
    script = Keyword.get(opts, :script, @escript_dest)
    runtime = Keyword.get(opts, :runtime, @runtime)

    """
    #!/bin/sh
    # `arb` in a worker container: generated by Arbiter (bd-59m96o), do not edit.
    #
    # The arb escript was compiled by the host's Erlang/OTP, and a BEAM file
    # loads only on that release or a newer one: an OTP 29 arb on an image that
    # pins OTP 27 dies with "corrupt atom table". So it runs on the runtime
    # Arbiter's worker base image carries for it, and on the image's own Erlang
    # only when there is no such runtime and that Erlang is new enough.
    script=#{sh_quote(script)}
    runtime=#{sh_quote(runtime)}

    """ <> @launcher_body
  end

  defp sh_quote(text), do: "'" <> String.replace(text, "'", ~S"'\''") <> "'"

  # The header lines, from a bounded read: the archive behind them can be
  # megabytes with no newline, and a non-escript can be anything.
  defp header_lines(path) do
    File.open(path, [:read, :binary], fn io ->
      case IO.binread(io, @header_bytes) do
        data when is_binary(data) -> String.split(data, "\n")
        _ -> []
      end
    end)
  end
end
