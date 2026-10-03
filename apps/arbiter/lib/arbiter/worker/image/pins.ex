defmodule Arbiter.Worker.Image.Pins do
  @moduledoc """
  The base-image digest pin store (bd-9r5jdt, design §2.2 and §2.4).

  A worker image's `FROM` lines are pinned by digest, so a registry tag that
  moves under an unchanged Containerfile cannot change what Arbiter builds
  (supply chain, §8). The pin for `docker.io/library/debian:bookworm-slim` is
  looked up here: the first request resolves the tag against the registry and
  records the digest, later requests reuse it, and the **weekly base refresh**
  (`refresh/1`, run by `Arbiter.Worker.Image.Refresher`) re-resolves every pin.
  A moved digest changes the content-hash tag of every image built on it, so
  the next dispatch builds the refreshed image; OS security updates arrive
  through that, and nothing else moves a base.

  The store is one JSON file, `<image_root>/pins.json`:

      {"pins": {"<ref>": {"digest": "sha256:…", "resolved_at": "<iso8601>"}},
       "refreshed_at": "<iso8601>" | null}

  Resolution asks `skopeo inspect` first (it reports the *index* digest, which
  is the same on every architecture) and falls back to `podman pull` plus
  `podman image inspect` (the per-platform manifest digest) on a host without
  skopeo. Both go through `Arbiter.Worker.Image.run/3`, so tests stub them.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.Image

  @week_ms 7 * 24 * 60 * 60 * 1000
  @digest_re ~r/\Asha256:[0-9a-f]{64}\z/
  @resolve_timeout_ms 300_000

  @type state :: %{
          pins: %{String.t() => %{String.t() => String.t()}},
          refreshed_at: String.t() | nil
        }

  @doc "The pin file for `opts[:root]` (default `Paths.image_root/0`)."
  @spec file(keyword()) :: String.t()
  def file(opts \\ []),
    do: Path.join(Keyword.get_lazy(opts, :root, &Paths.image_root/0), "pins.json")

  @doc "The stored pins (an empty store when the file is absent or unreadable)."
  @spec load(keyword()) :: state()
  def load(opts \\ []) do
    with {:ok, body} <- File.read(file(opts)),
         {:ok, %{"pins" => %{} = pins} = data} <- Jason.decode(body) do
      %{pins: pins, refreshed_at: data["refreshed_at"]}
    else
      _ -> %{pins: %{}, refreshed_at: nil}
    end
  end

  defp save(state, opts) do
    path = file(opts)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    File.write!(
      tmp,
      Jason.encode!(%{pins: state.pins, refreshed_at: state.refreshed_at}, pretty: true)
    )

    File.rename!(tmp, path)
    state
  end

  @doc """
  A resolver for `Image.plan/3`: a stored pin if there is one, else resolve the
  tag against the registry and store the result.
  """
  @spec resolver(keyword()) :: (String.t() -> {:ok, String.t()} | {:error, term()})
  def resolver(opts \\ []) do
    fn ref ->
      case load(opts).pins[ref] do
        %{"digest" => digest} -> {:ok, digest}
        _ -> resolve_and_store(ref, opts)
      end
    end
  end

  defp resolve_and_store(ref, opts) do
    with {:ok, digest} <- resolve_remote(ref, opts) do
      state = load(opts)
      save(put_pin(state, ref, digest), opts)
      {:ok, digest}
    end
  end

  defp put_pin(state, ref, digest) do
    entry = %{"digest" => digest, "resolved_at" => now_iso()}
    %{state | pins: Map.put(state.pins, ref, entry)}
  end

  @doc "Resolve `ref` to a `sha256:` digest against its registry."
  @spec resolve_remote(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_remote(ref, opts \\ []) do
    run_opts = Keyword.merge(opts, timeout: @resolve_timeout_ms)

    case Image.run(
           "skopeo",
           ["inspect", "--no-tags", "--format", "{{.Digest}}", "docker://" <> ref],
           run_opts
         ) do
      {out, 0} -> check_digest(out)
      {_, 127} -> resolve_with_podman(ref, run_opts)
      {out, _} -> {:error, "skopeo inspect failed: #{String.slice(String.trim(out), 0, 200)}"}
    end
  end

  defp resolve_with_podman(ref, opts) do
    with {_, 0} <- Image.run("podman", ["pull", "--quiet", ref], opts),
         {out, 0} <-
           Image.run("podman", ["image", "inspect", "--format", "{{.Digest}}", ref], opts) do
      check_digest(out)
    else
      {out, status} ->
        {:error, "podman exited #{status}: #{String.slice(String.trim(out), 0, 200)}"}
    end
  end

  defp check_digest(out) do
    digest = String.trim(out)

    if Regex.match?(@digest_re, digest),
      do: {:ok, digest},
      else: {:error, "not a sha256 digest: #{inspect(String.slice(digest, 0, 80))}"}
  end

  @doc """
  The weekly base refresh: re-resolve every stored pin and record when it ran.

  Returns the pins whose digest moved (`:changed`, as `{ref, old, new}`) and the
  ones that could not be resolved (`:failed`, left as they were: a registry
  outage never un-pins a base).
  """
  @spec refresh(keyword()) :: %{
          changed: [{String.t(), String.t(), String.t()}],
          failed: [{String.t(), String.t()}]
        }
  def refresh(opts \\ []) do
    state = load(opts)

    {state, changed, failed} =
      Enum.reduce(Enum.sort(state.pins), {state, [], []}, fn {ref, %{"digest" => old}},
                                                             {st, ch, fl} ->
        case resolve_remote(ref, opts) do
          {:ok, ^old} -> {put_pin(st, ref, old), ch, fl}
          {:ok, new} -> {put_pin(st, ref, new), [{ref, old, new} | ch], fl}
          {:error, reason} -> {st, ch, [{ref, reason} | fl]}
        end
      end)

    save(%{state | refreshed_at: now_iso()}, opts)
    %{changed: Enum.reverse(changed), failed: Enum.reverse(failed)}
  end

  @doc """
  Whether the weekly refresh is due: there are pins, and the last refresh (or,
  before the first one, the oldest resolution) is over a week old. An install
  that never built an image has nothing to refresh.
  """
  @spec due?(keyword()) :: boolean()
  def due?(opts \\ []) do
    %{pins: pins, refreshed_at: refreshed_at} = load(opts)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    last =
      refreshed_at ||
        pins |> Map.values() |> Enum.map(& &1["resolved_at"]) |> Enum.min(fn -> nil end)

    with true <- map_size(pins) > 0,
         {:ok, at, _} <- DateTime.from_iso8601(last || "") do
      DateTime.diff(now, at, :millisecond) >= @week_ms
    else
      _ -> false
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
