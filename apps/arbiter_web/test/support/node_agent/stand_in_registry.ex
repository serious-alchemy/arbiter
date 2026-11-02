defmodule ArbiterWeb.StandInRegistry do
  @moduledoc """
  SI4's stand-in container registry: the read half of the OCI distribution API
  (`GET /v2/`, `GET|HEAD /v2/<name>/manifests/<ref>`, `GET|HEAD /v2/<name>/blobs/<digest>`)
  as a Plug served by Bandit on a loopback port, behind HTTP Basic auth that accepts
  one login.

  Images live in an `Agent` (`put_image/3` builds an OCI manifest, a config blob
  carrying the given labels, and one layer blob). Every login a client presents is
  kept, in memory only, so a test can assert which credential reached the registry
  (`presented/1`) and what it served (`served/1`).

      agent = start_supervised!({Agent, fn -> StandInRegistry.state("reader", "pw") end})

      server =
        start_supervised!(
          {Bandit, plug: {StandInRegistry, agent: agent}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
        )
  """

  @behaviour Plug

  import Plug.Conn

  @manifest_type "application/vnd.oci.image.manifest.v1+json"
  @config_type "application/vnd.oci.image.config.v1+json"
  @layer_type "application/vnd.oci.image.layer.v1.tar"

  @doc "The registry's starting state: it accepts `user:password` and holds nothing."
  @spec state(String.t(), String.t()) :: map()
  def state(user, password),
    do: %{login: {user, password}, manifests: %{}, blobs: %{}, presented: [], served: []}

  @doc "Store an image under repository `name` whose config carries `labels`; its digest."
  @spec put_image(pid(), String.t(), %{String.t() => String.t()}) :: String.t()
  def put_image(agent, name, labels) do
    layer = "stand-in layer of #{name}\n"

    config =
      Jason.encode!(%{
        "architecture" => "amd64",
        "os" => "linux",
        "config" => %{"Labels" => labels},
        "rootfs" => %{"type" => "layers", "diff_ids" => [digest(layer)]}
      })

    manifest =
      Jason.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => @manifest_type,
        "config" => %{
          "mediaType" => @config_type,
          "digest" => digest(config),
          "size" => byte_size(config)
        },
        "layers" => [
          %{"mediaType" => @layer_type, "digest" => digest(layer), "size" => byte_size(layer)}
        ]
      })

    ref = digest(manifest)

    Agent.update(agent, fn s ->
      %{
        s
        | manifests: Map.put(s.manifests, {name, ref}, manifest),
          blobs: s.blobs |> Map.put(digest(config), config) |> Map.put(digest(layer), layer)
      }
    end)

    ref
  end

  @doc "Every login presented, oldest first: `{user, password}` or `:anonymous`."
  @spec presented(pid()) :: [{String.t(), String.t()} | :anonymous]
  def presented(agent), do: Agent.get(agent, &Enum.reverse(&1.presented))

  @doc "Every path served with a 200, oldest first."
  @spec served(pid()) :: [String.t()]
  def served(agent), do: Agent.get(agent, &Enum.reverse(&1.served))

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # -- the plug ------------------------------------------------------------------------

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :agent)

  @impl true
  def call(conn, agent) do
    login = login(conn)
    Agent.update(agent, &%{&1 | presented: [login | &1.presented]})

    if login == Agent.get(agent, & &1.login) do
      route(conn, agent)
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Basic realm="stand-in"))
      |> send_resp(401, ~s({"errors":[{"code":"UNAUTHORIZED"}]}))
    end
  end

  defp login(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, pair} <- Base.decode64(encoded),
         [user, password] <- String.split(pair, ":", parts: 2) do
      {user, password}
    else
      _ -> :anonymous
    end
  end

  defp route(%{path_info: ["v2"]} = conn, _agent), do: send_resp(conn, 200, "{}")

  defp route(%{path_info: ["v2" | rest]} = conn, agent) do
    {name, kind, ref} = split(rest)

    found =
      Agent.get(agent, fn s ->
        case kind do
          "manifests" -> s.manifests[{name, ref}] && {@manifest_type, s.manifests[{name, ref}]}
          "blobs" -> s.blobs[ref] && {"application/octet-stream", s.blobs[ref]}
          _ -> nil
        end
      end)

    case found do
      {type, body} ->
        Agent.update(agent, &%{&1 | served: [conn.request_path | &1.served]})

        conn
        |> put_resp_header("content-type", type)
        |> put_resp_header("docker-content-digest", digest(body))
        |> send_resp(200, if(conn.method == "HEAD", do: "", else: body))

      nil ->
        send_resp(conn, 404, ~s({"errors":[{"code":"NOT_FOUND"}]}))
    end
  end

  defp route(conn, _agent), do: send_resp(conn, 404, "")

  # `<name…>/manifests/<ref>` or `<name…>/blobs/<digest>`.
  defp split(segments) do
    case Enum.split(segments, -2) do
      {name, [kind, ref]} when name != [] -> {Enum.join(name, "/"), kind, ref}
      _ -> {nil, nil, nil}
    end
  end
end
