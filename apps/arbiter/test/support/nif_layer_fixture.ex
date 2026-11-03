defmodule Arbiter.Test.NifLayerFixture do
  @moduledoc """
  SI5: a real Mix project with a native-style dependency, a seed layer made from it,
  and the offline gate that proves the layer was relocated correctly.

  The dependency (`nifdep`) is a path dependency under `deps/`. Mix rechecks a path
  dependency on every compile, which makes a wrong relocation observable: a manifest
  that names another directory than the one Mix runs in makes Mix compile the
  dependency again (`==> nifdep` in the gate's output). For a `lazy_html` or `exqlite`
  NIF that rebuild is a download of a precompiled binary or a C build, and the gate has
  no network. (A Hex dependency is not rechecked at compile time, so a test with no
  network cannot show it; the `priv` links a NIF needs are covered in
  `DepsRelocateTest`.) The dependency's custom compiler writes `priv/nif.so`.

    * `build_layer/1` compiles the project at a scratch `src` directory, copies `deps/`,
      `_build/` and the `.complete` stamp (`lock=`, `image=`, `src=`) into a `layer`
      directory laid out as `/opt/arbiter/seed`, then deletes `src`.
    * `checkout/3` is a git checkout of the project's committed files (`mix.exs`,
      `mix.lock`, `lib/`; no `deps`, no `_build`), the way a node's shadow clone and a
      pod's worktree start.
    * `gate/1` is the offline gate: `mix compile` in the checkout with nothing to fetch.
      `rebuilt?/1` says whether it compiled the dependency again.
  """

  @mix_exs """
  defmodule Proj.MixProject do
    use Mix.Project

    def project,
      do: [app: :proj, version: "0.1.0", elixir: "~> 1.15", deps: [{:nifdep, path: "deps/nifdep"}]]

    def application, do: []
  end
  """

  @dep_mix_exs """
  defmodule Mix.Tasks.Compile.Nifdep do
    use Mix.Task.Compiler

    def run(_args) do
      File.mkdir_p!("priv")
      File.write!("priv/nif.so", "nif")
      {:ok, []}
    end
  end

  defmodule Nifdep.MixProject do
    use Mix.Project

    def project, do: [app: :nifdep, version: "0.1.0", compilers: [:nifdep | Mix.compilers()]]
    def application, do: []
  end
  """

  @lock "%{}\n"

  @type layer :: %{
          layer: String.t(),
          src: String.t(),
          stamp: String.t(),
          lock: String.t(),
          lock_hash: String.t()
        }

  @doc """
  Compile the project under `<base>/src` and lay a seed layer out at `<base>/layer`.
  `src` no longer exists afterwards.
  """
  @spec build_layer(String.t()) :: layer()
  def build_layer(base) do
    src = Path.join(base, "src")
    layer = Path.join(base, "layer")

    write_project(src, @lock)
    File.mkdir_p!(Path.join(src, "deps/nifdep/lib"))
    File.write!(Path.join(src, "deps/nifdep/mix.exs"), @dep_mix_exs)

    File.write!(
      Path.join(src, "deps/nifdep/lib/nifdep.ex"),
      "defmodule Nifdep do\n  def priv, do: :code.priv_dir(:nifdep)\nend\n"
    )

    {out, 0} = mix(src, ["deps.compile"])
    true = rebuilt?(out)

    File.mkdir_p!(layer)
    {_, 0} = System.cmd("cp", ["-a", Path.join(src, "deps"), Path.join(layer, "deps")])
    {_, 0} = System.cmd("cp", ["-a", Path.join(src, "_build"), Path.join(layer, "_build")])
    lock_hash = :crypto.hash(:sha256, @lock) |> Base.encode16(case: :lower)
    stamp = "lock=#{lock_hash}\nimage=localhost/arbiter-dev/beam:abc123\nsrc=#{src}\n"
    File.write!(Path.join(layer, ".complete"), stamp)
    File.rm_rf!(src)

    %{layer: layer, src: src, stamp: stamp, lock: @lock, lock_hash: lock_hash}
  end

  @doc """
  A git checkout at `dir` of the project `built` was made from, with its lockfile (or
  `lock:` another, or `nil` for none, to model a branch that changed it).
  """
  @spec checkout(String.t(), layer(), keyword()) :: String.t()
  def checkout(dir, built, opts \\ []) do
    write_project(dir, Keyword.get(opts, :lock, built.lock))
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"])
    dir
  end

  defp write_project(dir, lock) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), @mix_exs)
    File.write!(Path.join(dir, "lib/proj.ex"), "defmodule Proj do\n  def x, do: 1\nend\n")
    File.write!(Path.join(dir, ".gitignore"), "/deps\n/_build\n")
    if lock, do: File.write!(Path.join(dir, "mix.lock"), lock)
  end

  @doc "The offline gate: `mix compile` in `dir`. `{output, status}`."
  @spec gate(String.t()) :: {String.t(), non_neg_integer()}
  def gate(dir), do: mix(dir, ["compile"])

  @doc "Did this output compile the dependency (again)?"
  @spec rebuilt?(String.t()) :: boolean()
  def rebuilt?(output), do: String.contains?(output, "==> nifdep")

  # sobelow_skip ["CI.System"]
  defp mix(dir, args) do
    mix = System.find_executable("mix") || raise "mix is not on PATH"

    System.cmd(mix, args,
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"LANG", "C.UTF-8"},
        {"MIX_BUILD_PATH", nil},
        {"MIX_DEPS_PATH", nil},
        {"MIX_EXS", nil},
        {"MIX_TARGET", nil}
      ]
    )
  end

  # sobelow_skip ["CI.System"]
  defp git!(dir, args) do
    {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    :ok
  end
end
