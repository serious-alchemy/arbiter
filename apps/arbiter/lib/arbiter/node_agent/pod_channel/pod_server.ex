defmodule Arbiter.NodeAgent.PodChannel.PodServer do
  @moduledoc """
  The pod channel's HTTPS listener, `:9444` (`docs/design/remote-workers.md` §16
  K§9.3): Bandit over TLS serving `Arbiter.NodeAgent.PodChannel.PodPlug`.

  `verify_peer` against the install's CA with `fail_if_no_peer_cert: false`, so
  `/boot` can be reached before the pod has any certificate; a client that does
  offer one still has it verified (expiry, CA, `clientAuth`), and the plug
  refuses every route but `/boot` without a `control` leaf. HTTP/1.1 only.

  Options: `:identity`, `:ca`, `:runs`, `:config` (the primary), `:ip`, `:port`
  (`0` picks one), `:notify`, `:max_upload_bytes`, `:backlog`.
  """

  alias Arbiter.NodeAgent.PodChannel.{PodPlug, Tls}

  @doc "A child spec for a supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    plug_opts = Keyword.take(opts, [:runs, :config, :notify, :max_upload_bytes])

    transport =
      Tls.server_options(Keyword.fetch!(opts, :identity), Keyword.fetch!(opts, :ca),
        require_client_cert: false
      ) ++
        [
          backlog: Keyword.get(opts, :backlog, 1024),
          nodelay: true,
          reuseaddr: true
        ]

    bandit =
      {Bandit,
       plug: {PodPlug, plug_opts},
       scheme: :https,
       ip: Keyword.get(opts, :ip, {0, 0, 0, 0}),
       port: Keyword.get(opts, :port, 9444),
       http_2_options: [enabled: false],
       thousand_island_options: [transport_options: transport],
       startup_log: false}

    Supervisor.child_spec(bandit, id: Keyword.get(opts, :id, __MODULE__))
  end

  @doc "The port a started server is bound to."
  @spec port(pid()) :: :inet.port_number()
  def port(pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end
end
