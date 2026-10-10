defmodule Arbiter.NodeAgent.PodChannel.CATest do
  @moduledoc """
  The per-install CA is created on first boot and then read back
  (`docs/design/remote-workers.md` §16 K§9.2, K§2.4): the private key goes to
  the store (a Secret in the cluster), only the public certificate is
  published, and nothing else the pod channel mints is ever handed to a store.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Arbiter.NodeAgent.PodChannel.{CA, Cert}
  alias Arbiter.NodeAgent.PodChannel.CAStore

  defmodule MemoryStore do
    @moduledoc false
    @behaviour Arbiter.NodeAgent.PodChannel.CAStore

    @impl true
    def load(agent), do: Agent.get(agent, & &1.stored) || :none

    @impl true
    def save(agent, material) do
      Agent.update(agent, fn s -> %{s | stored: {:ok, material}, saves: s.saves + 1} end)
    end

    @impl true
    def publish(agent, cert_pem), do: Agent.update(agent, &%{&1 | published: cert_pem})
  end

  defp memory do
    agent =
      start_supervised!({Agent, fn -> %{stored: nil, saves: 0, published: nil} end},
        id: make_ref()
      )

    {{MemoryStore, agent}, agent}
  end

  test "first boot creates the CA, stores it and publishes only the certificate" do
    {store, agent} = memory()

    assert {:ok, ca} = CA.load_or_create(store)

    state = Agent.get(agent, & &1)
    assert state.saves == 1
    assert {:ok, %{cert: cert, key: key}} = state.stored
    assert cert == Cert.pem_cert(ca.der)
    assert key =~ "EC PRIVATE KEY"
    assert state.published == cert
    refute state.published =~ "PRIVATE KEY"
  end

  test "the next boot reads the same CA instead of replacing it" do
    {store, agent} = memory()
    {:ok, first} = CA.load_or_create(store)
    {:ok, second} = CA.load_or_create(store)

    assert first.der == second.der
    assert Agent.get(agent, & &1.saves) == 1
  end

  test "the public certificate is published on every boot" do
    {store, agent} = memory()
    {:ok, _} = CA.load_or_create(store)
    Agent.update(agent, &%{&1 | published: nil})
    {:ok, ca} = CA.load_or_create(store)

    assert Agent.get(agent, & &1.published) == Cert.pem_cert(ca.der)
  end

  test "a stored CA that is expired or damaged is an error, never silently replaced" do
    {store, agent} = memory()
    past = DateTime.add(DateTime.utc_now(), -7200)
    expired = Cert.ca(DateTime.add(past, -3600), DateTime.add(past, 3600))

    Agent.update(
      agent,
      &%{&1 | stored: {:ok, %{cert: Cert.pem_cert(expired.der), key: Cert.pem_key(expired.key)}}}
    )

    assert {:error, {:ca_invalid, _}} = CA.load_or_create(store)
    assert Agent.get(agent, & &1.saves) == 0

    Agent.update(agent, &%{&1 | stored: {:ok, %{cert: "garbage", key: "garbage"}}})
    assert {:error, _} = CA.load_or_create(store)
    assert Agent.get(agent, & &1.saves) == 0
  end

  test "a store that cannot save fails the boot" do
    defmodule ReadOnlyStore do
      @moduledoc false
      @behaviour Arbiter.NodeAgent.PodChannel.CAStore
      def load(_), do: :none
      def save(_, _), do: {:error, :forbidden}
      def publish(_, _), do: :ok
    end

    assert {:error, {:ca_save_failed, :forbidden}} = CA.load_or_create({ReadOnlyStore, nil})
  end

  describe "the directory store" do
    test "keeps the key at 0600 and round-trips", %{tmp_dir: dir} do
      store = {CAStore.Dir, dir}
      {:ok, ca} = CA.load_or_create(store)

      %File.Stat{mode: mode} = File.stat!(Path.join(dir, "ca.key"))
      assert Bitwise.band(mode, 0o777) == 0o600
      assert File.read!(Path.join(dir, "ca.crt")) == Cert.pem_cert(ca.der)

      assert {:ok, again} = CA.load_or_create(store)
      assert again.der == ca.der
    end
  end

  test "leaf minting for a run uses the stored CA" do
    {store, _} = memory()
    {:ok, ca} = CA.load_or_create(store)
    now = DateTime.utc_now()
    leaf = Cert.leaf(ca, "run-x", "proxy", DateTime.add(now, -60), DateTime.add(now, 600))

    assert {:ok, _} = :public_key.pkix_path_validation(ca.der, [leaf.der], [])
  end
end
