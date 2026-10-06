defmodule Arbiter.Nodes.CredentialsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Credentials

  describe "join tokens" do
    test "are arbj_ + 52 base32 chars (256 bits) and never repeat" do
      {secret, hash} = Credentials.generate_join_token()

      assert "arbj_" <> body = secret
      assert byte_size(body) == 52
      assert body =~ ~r/\A[a-z2-7]+\z/
      assert hash == Credentials.hash(secret)
      refute elem(Credentials.generate_join_token(), 0) == secret
    end

    test "the hash is a hex sha256 that does not contain the secret" do
      {secret, hash} = Credentials.generate_join_token()

      assert hash =~ ~r/\A[0-9a-f]{64}\z/
      refute String.contains?(hash, secret)
    end

    test "join_token?/1 recognises only the arbj_ shape" do
      {secret, _} = Credentials.generate_join_token()

      assert Credentials.join_token?(secret)
      refute Credentials.join_token?("arbn_abc.def")
      refute Credentials.join_token?("arbj_")
      refute Credentials.join_token?(nil)
    end
  end

  describe "node credentials" do
    test "embed the node id and a 256-bit secret" do
      cred = Credentials.generate_node_credential("0192-node")

      assert "arbn_0192-node." <> secret = cred.credential
      assert byte_size(secret) == 52
      assert cred.hash == Credentials.hash(secret)
      assert cred.prefix == String.slice(secret, 0, 8)
      refute String.contains?(cred.hash, secret)
    end

    test "parse/1 round-trips and refuses everything else" do
      cred = Credentials.generate_node_credential("0192-node")

      assert {:ok, "0192-node", secret} = Credentials.parse_node_credential(cred.credential)
      assert Credentials.hash(secret) == cred.hash

      for bad <- ["", "arbn_", "arbn_.x", "arbn_id.", "arbn_nodot", "arbj_abc.def", "x", nil, 5] do
        assert Credentials.parse_node_credential(bad) == :error, inspect(bad)
      end
    end

    test "matches?/2 compares in constant time against a stored hash" do
      cred = Credentials.generate_node_credential("n1")
      {:ok, _id, secret} = Credentials.parse_node_credential(cred.credential)

      assert Credentials.matches?(secret, cred.hash)
      refute Credentials.matches?("wrong", cred.hash)
      refute Credentials.matches?(secret, nil)
      refute Credentials.matches?(secret, "")
    end
  end
end
