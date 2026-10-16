defmodule Mix.Tasks.Arbiter.Containerfile do
  @shortdoc "Print a Containerfile the primary also builds (controller, worker-base)"
  @moduledoc """
  Prints the Containerfile for an image Arbiter publishes, from the same
  generator the primary uses, so release CI and the primary cannot drift
  (docs/design/remote-workers.md §20.8, KH7).

  ## Usage

      mix arbiter.containerfile controller [--pin] [--out PATH]
      mix arbiter.containerfile worker-base [--pin] [--arb-otp N] [--out PATH] [--hash-out PATH]

    * `controller` is `Arbiter.Worker.Image.Publisher.Pipeline.controller_containerfile/0`:
      the image `ghcr.io/<owner>/arbiter-controller` is built from, with the
      release tarball as `release.tar.gz` in the build context.
    * `worker-base` is `Arbiter.Worker.Image.base_containerfile/1`: the shared
      base of every worker image (empty build context), for arb's Erlang/OTP
      release `--arb-otp` (default: the host arb's, else this VM's).

  Options:

    * `--pin` rewrites every external `FROM` to `ref@sha256:…` (`Image.pin/2`,
      digests resolved against the registry with `skopeo`, else `podman`), exactly
      as the primary does before it hashes or builds. Release CI always pins.
    * `--out PATH` writes the Containerfile there instead of stdout.
    * `--hash-out PATH` (worker-base, needs `--pin`) writes the base's content hash,
      the tag of `ghcr.io/<owner>/arbiter-worker-base:<hash>`, and the one a primary tags
      the same base with.

  Needs no database and does not start the application.
  """

  use Mix.Task

  alias Arbiter.Worker.ArbCli
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Pins
  alias Arbiter.Worker.Image.Publisher.Pipeline

  @kinds ~w(controller worker-base)
  @switches [pin: :boolean, out: :string, hash_out: :string, arb_otp: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")

    case OptionParser.parse(argv, strict: @switches) do
      {opts, [kind], []} when kind in @kinds ->
        write!(kind, opts, &Pins.resolve_remote/1)

      {_, [kind], []} ->
        Mix.raise("unknown kind #{inspect(kind)}; expected one of: #{Enum.join(@kinds, ", ")}")

      {_, _, invalid} when invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      _ ->
        Mix.raise("usage: mix arbiter.containerfile <#{Enum.join(@kinds, "|")}> [options]")
    end
  end

  @doc false
  @spec write!(String.t(), keyword(), (String.t() -> {:ok, String.t()} | {:error, term()})) ::
          :ok
  def write!(kind, opts, resolver) do
    case render(kind, opts, resolver) do
      {:ok, text, meta} ->
        emit(text, opts[:out])
        if path = opts[:hash_out], do: File.write!(path, meta.hash <> "\n")
        :ok

      {:error, reason} ->
        Mix.raise("arbiter.containerfile #{kind}: #{inspect(reason)}")
    end
  end

  @doc """
  `{:ok, containerfile, %{hash: hash | nil}}` for `kind`. `hash` is set only for a
  pinned `worker-base`; `resolver` is `Image.pin/2`'s.
  """
  @spec render(String.t(), keyword(), (String.t() -> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t(), %{hash: String.t() | nil}} | {:error, term()}
  def render("controller", opts, resolver) do
    if opts[:hash_out], do: {:error, :hash_is_for_worker_base}, else: controller(opts, resolver)
  end

  def render("worker-base", opts, resolver) do
    arb_otp = Keyword.get_lazy(opts, :arb_otp, fn -> ArbCli.runtime_otp() end)

    cond do
      opts[:pin] ->
        with {:ok, base} <- Image.base_layer(resolver, arb_otp) do
          {:ok, base.containerfile, %{hash: base.hash}}
        end

      opts[:hash_out] ->
        {:error, :hash_needs_pin}

      true ->
        {:ok, Image.base_containerfile(arb_otp), %{hash: nil}}
    end
  end

  def render(kind, _opts, _resolver), do: {:error, {:unknown_kind, kind}}

  defp controller(opts, resolver) do
    text = Pipeline.controller_containerfile()

    if opts[:pin] do
      with {:ok, pinned, _pins} <- Image.pin(text, resolver), do: {:ok, pinned, %{hash: nil}}
    else
      {:ok, text, %{hash: nil}}
    end
  end

  defp emit(text, nil), do: IO.write(text)
  defp emit(text, path), do: File.write!(path, text)
end
