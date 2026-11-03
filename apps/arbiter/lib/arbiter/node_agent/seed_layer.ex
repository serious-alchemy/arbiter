defmodule Arbiter.NodeAgent.SeedLayer do
  @moduledoc """
  Deps for a machine node's run from the seed layer of the image it pulled (SI5,
  `docs/design/remote-workers.md` §21.2.1, "Deps on a machine node come from the
  image's seed layer, with a fallback").

  The published image carries `/opt/arbiter/seed/{deps,_build,mix_home}` and the
  `.complete` stamp (`lock=` the SHA-256 of the `mix.lock` it was built from,
  `image=` the toolchain tag, `src=` the directory it was compiled at). `install/3`:

    1. **Probe.** `podman create` of the run image (nothing runs) and one
       `podman cp` of the stamp. No stamp means the publisher shipped no seed layer
       (`{:fallback, :no_seed_layer}`).
    2. **Lock.** The stamp's `lock=` must be the SHA-256 of the checkout's `mix.lock`
       at `HEAD`. A branch that changed its lockfile does not match
       (`{:fallback, {:lock_mismatch, checkout, layer}}`): the caller runs today's seed
       job for the checkout's own lock, which needs Hex from the node.
    3. **Extract once per seed layer.** The layer is copied out into
       `<root>/layer-<lock12>-<stamp12>` (`podman cp`, into a staging directory and
       renamed, so the final name only ever appears whole). The name is keyed by the
       stamp, which is the seed layer's identity (the lock, the toolchain tag, the
       directory it was compiled at), not by the run image, so a CLI update that moves
       the image's digest extracts nothing again.
    4. **Install.** `DepsCache.install_extracted/4`: `deps/` and `_build/` reflinked
       (or copied) into the checkout, the manifests and `priv` links relocated from the
       stamp's `src=` to `:retarget_to`, the layer's `mix_home` into the run's `HOME`.

  **Relocation target.** Mix compares the directory it runs in with the one a
  dependency's manifest records and rebuilds on a difference, which offline fails on a
  NIF dependency. On a node the checkout is copied to a host directory but runs at the
  spec's mount path inside the container, so `:retarget_to` is that path; a manifest
  naming the host path is stale at run time.

  Anything unexpected is `{:fallback, reason}`, never an error: the caller falls back
  to the seed job and the run starts as it always has.

  Options: `:root` and `:scratch` (the node's deps cache and its staging area),
  `:home` (the run's `HOME`), `:retarget_to`, `:podman`, `:runner` (the
  `Arbiter.Worker.Container.cmd/4` seam), `:cp_hook` (`DepsCache`'s).
  """

  alias Arbiter.Worker.Container
  alias Arbiter.Worker.DepsCache
  alias Arbiter.Worker.ReleaseEnv


  @seed_dir "/opt/arbiter/seed"
  @quick_timeout_ms 60_000
  @extract_timeout_ms 10 * 60_000

  @type fallback :: :no_lockfile | :no_seed_layer | :bad_stamp | tuple()

  @doc "Install the seed layer of `ref` into `shadow`, or say why the caller must seed it."
  @spec install(String.t(), String.t(), keyword()) :: {:ok, map()} | {:fallback, fallback()}
  def install(shadow, ref, opts) when is_binary(shadow) and is_binary(ref) do
    with {:ok, lock} <- checkout_lock(shadow),
         {:ok, name} <- create(ref, opts) do
      try do
        with {:ok, text, stamp} <- read_stamp(name, opts),
             :ok <- same_lock(lock, stamp),
             {:ok, dir} <- extract(name, text, stamp, opts) do
          install_dir(dir, stamp, shadow, opts)
        end
      after
        remove(name, opts)
      end
    end
  end

  # -- the checkout's lock ---------------------------------------------------------------

  defp checkout_lock(shadow) do
    case DepsCache.lock_hash(shadow, "HEAD") do
      {:ok, lock} -> {:ok, lock}
      {:error, :no_lockfile} -> {:fallback, :no_lockfile}
    end
  end

  # -- probe -------------------------------------------------------------------------------

  # `create` runs nothing and needs no network (`--pull=never`: the digest is already
  # here, `ImagePull` made it so). The command is never executed, only required.
  defp create(ref, opts) do
    name = Container.name_for("seed-" <> random())

    case podman(
           opts,
           ["create", "--pull=never", "--name", name, "--", ref, "true"],
           @quick_timeout_ms
         ) do
      {_, 0} -> {:ok, name}
      {out, status} -> {:fallback, {:create_failed, status, tail(out)}}
    end
  end

  defp read_stamp(name, opts) do
    dir = Path.join(scratch(opts), "stamp-" <> random())
    file = Path.join(dir, ".complete")

    try do
      File.mkdir_p!(dir)

      with {_, 0} <-
             podman(opts, ["cp", "#{name}:#{@seed_dir}/.complete", file], @quick_timeout_ms),
           {:ok, text} <- File.read(file),
           %{lock: lock, src: src} = stamp when is_binary(lock) and is_binary(src) <-
             DepsCache.parse_stamp(text) do
        {:ok, text, stamp}
      else
        {_out, status} when is_integer(status) -> {:fallback, :no_seed_layer}
        {:error, _} -> {:fallback, :no_seed_layer}
        %{} -> {:fallback, :bad_stamp}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp same_lock(lock, %{lock: lock}), do: :ok
  defp same_lock(lock, %{lock: layer}), do: {:fallback, {:lock_mismatch, lock, layer}}

  # -- extract, once per seed layer ---------------------------------------------------------

  defp extract(name, text, %{lock: lock}, opts) do
    dir = Path.join(root(opts), "layer-" <> binary_part(lock, 0, 12) <> "-" <> digest12(text))

    if complete?(dir) do
      {:ok, dir}
    else
      :global.trans(
        {{__MODULE__, dir}, self()},
        fn -> extract_locked(name, dir, opts) end,
        [node()],
        :infinity
      )
    end
  end

  defp extract_locked(name, dir, opts) do
    if complete?(dir) do
      {:ok, dir}
    else
      staging = dir <> ".tmp-" <> random()

      try do
        File.mkdir_p!(staging)

        with {_, 0} <-
               podman(opts, ["cp", "#{name}:#{@seed_dir}/.", staging], @extract_timeout_ms),
             true <- complete?(staging) and File.dir?(Path.join(staging, "deps")),
             :ok <- File.rename(staging, dir) do
          {:ok, dir}
        else
          # Another node process won the rename; its copy is as good.
          {:error, _} ->
            if complete?(dir), do: {:ok, dir}, else: {:fallback, :extract_failed}

          {out, status} when is_integer(status) ->
            {:fallback, {:extract_failed, status, tail(out)}}

          false ->
            {:fallback, :incomplete_layer}
        end
      rescue
        e in File.Error -> {:fallback, {:extract_failed, Exception.message(e)}}
      after
        force_rm_rf(staging)
      end
    end
  end

  defp complete?(dir), do: File.regular?(Path.join(dir, ".complete"))

  # -- install -------------------------------------------------------------------------------

  defp install_dir(dir, %{lock: lock}, shadow, opts) do
    install_opts = Keyword.take(opts, [:home, :retarget_to, :cp_hook])

    case DepsCache.install_extracted(dir, lock, shadow, install_opts) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:fallback, {:install_failed, reason}}
    end
  end

  # -- helpers -------------------------------------------------------------------------------

  defp remove(name, opts) do
    _ = podman(opts, ["rm", "--force", "--ignore", name], @quick_timeout_ms)
    :ok
  end

  defp podman(opts, args, timeout) do
    podman = Keyword.get(opts, :podman) || System.find_executable("podman") || "podman"
    Container.cmd(Keyword.take(opts, [:runner]), podman, args, timeout: timeout)
  end

  defp root(opts), do: Keyword.fetch!(opts, :root)
  defp scratch(opts), do: Keyword.fetch!(opts, :scratch)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp digest12(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp tail(output), do: output |> String.trim() |> String.slice(-500, 500)

  # The layer's directories can be read-only; make the tree writable before removing it.
  defp force_rm_rf(path) do
    if File.exists?(path) do
      _ = ReleaseEnv.cmd("chmod", ["-R", "u+rwX", path], stderr_to_stdout: true)
      File.rm_rf(path)
    end

    :ok
  end
end
