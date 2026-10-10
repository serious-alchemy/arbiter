defmodule Arbiter.NodeAgent.PodChannelKit do
  @moduledoc false
  # Test helpers for the k8s pod channel (`Arbiter.NodeAgent.PodChannel`): a CA,
  # a run table, the pod's side of `/boot` and a TLS client that presents what
  # the pod would.

  alias Arbiter.NodeAgent.PodChannel.{Cert, Runs, Tls}
  alias Arbiter.NodeAgent.RunSpec

  @server_names ["arbiter-controller", "localhost"]

  def ca(opts \\ []) do
    now = DateTime.utc_now()
    Cert.ca(DateTime.add(now, -60), DateTime.add(now, Keyword.get(opts, :ttl, 3600)))
  end

  def server_identity(ca) do
    now = DateTime.utc_now()

    Cert.server(
      ca,
      @server_names,
      [{127, 0, 0, 1}],
      DateTime.add(now, -60),
      DateTime.add(now, 3600)
    )
  end

  def spec!(run \\ "run-1", bridges \\ ["proxy", "arb"], overrides \\ %{}) do
    {:ok, spec} =
      RunSpec.validate(
        Map.merge(
          %{
            "version" => 1,
            "run" => run,
            "task" => "bd-abc",
            "name" => "arb-#{run}",
            "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
            "cwd" => "/work/tree",
            "mounts" => [%{"kind" => "worktree", "path" => "/work/tree"}],
            "bridges" => Enum.map(bridges, &%{"name" => &1, "path" => "/var/eg/#{&1}.sock"}),
            "secrets" => %{"TOKEN" => "s3cret"},
            "checkout" => %{"branch" => "feature/x", "base" => "main", "interval_s" => 60},
            "command" => ["claude"]
          },
          overrides
        )
      )

    spec
  end

  @doc "Register `spec`'s run, bind `pod_ip`, redeem the nonce: `%{nonce:, files:}` (the tar, unpacked)."
  def boot!(runs, spec, pod_ip, deadline \\ nil) do
    deadline = deadline || DateTime.add(DateTime.utc_now(), 600)
    {:ok, nonce} = Runs.register(runs, spec, deadline)
    :ok = Runs.bind_pod_ip(runs, spec.run, pod_ip)
    {:ok, _run, tar} = Runs.redeem(runs, nonce, pod_ip)
    %{nonce: nonce, files: unpack(tar)}
  end

  def unpack(tar) do
    {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
    Map.new(files, fn {name, body} -> {to_string(name), body} end)
  end

  @doc "`:ssl.connect` options presenting leaf `name` out of a `/boot` tar's `files`."
  def client_opts(files, name, ca, extra \\ []) do
    [{:Certificate, der, _}] = :public_key.pem_decode(files["tls/#{name}.crt"])
    [{:ECPrivateKey, key, _}] = :public_key.pem_decode(files["tls/#{name}.key"])
    client_opts_der(der, key, ca, extra)
  end

  @doc "Options presenting a certificate made by `Cert.leaf/6` (`%{der:, key:}`)."
  def client_opts_leaf(%{der: der, key: key}, ca, extra \\ []),
    do: client_opts_der(der, :public_key.der_encode(:ECPrivateKey, key), ca, extra)

  defp client_opts_der(der, key_der, ca, extra) do
    [
      cert: der,
      key: {:ECPrivateKey, key_der},
      cacerts: [ca.der],
      verify: :verify_peer,
      server_name_indication: ~c"arbiter-controller",
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ extra
  end

  def client_opts_no_cert(ca) do
    [
      cacerts: [ca.der],
      verify: :verify_peer,
      server_name_indication: ~c"arbiter-controller"
    ]
  end

  def server_opts(identity, ca, extra \\ []), do: Tls.server_options(identity, ca, extra)
end
