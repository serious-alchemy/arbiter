defmodule Arbiter.Worker.Image.SeedScanTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image.SeedScan

  test "no records is clean" do
    assert SeedScan.check("") == :ok
  end

  test "credential file names are hits" do
    out = "F\t./deps/a/hex.config\nF\t./deps/b/.git-credentials\nF\t./id_ed25519\n"

    assert {:error, hits} = SeedScan.check(out)

    assert {:credential_file, "./deps/a/hex.config"} in hits
    assert {:credential_file, "./deps/b/.git-credentials"} in hits
    assert {:credential_file, "./id_ed25519"} in hits
  end

  test "userinfo URLs are hits, plain and ssh login URLs are not" do
    ok =
      "G\tdeps/a/.git/config\thttps://github.com/acme/a.git\n" <>
        "G\tdeps/b/.git/config\tssh://git@github.com/acme/b.git\n" <>
        "G\tdeps/c/.git/config\tgit@github.com:acme/c.git\n"

    assert SeedScan.check(ok) == :ok

    bad = "G\tdeps/d/.git/config\thttps://user:tok@example.com/d.git\n"
    assert {:error, [{:userinfo_url, "deps/d/.git/config"}]} = SeedScan.check(bad)

    token_only = "G\tdeps/e/.git/config\thttps://ghp_abc@github.com/e.git\n"
    assert {:error, [{:userinfo_url, _}]} = SeedScan.check(token_only)
  end

  test "the script runs against a real tree and reports credential files and userinfo URLs" do
    root = Path.join(System.tmp_dir!(), "seedscan-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "deps/p/.git"))
    File.mkdir_p!(Path.join(root, "deps/q/.git"))

    File.write!(
      Path.join(root, "deps/p/.git/config"),
      "[remote \"origin\"]\n\turl = https://u:t@h.io/p.git\n"
    )

    File.write!(
      Path.join(root, "deps/q/.git/config"),
      "[remote \"origin\"]\n\turl = https://h.io/q.git\n"
    )

    File.write!(Path.join(root, "deps/q/cacerts.pem"), "-----BEGIN CERTIFICATE-----\nabc\n")
    File.write!(Path.join(root, "deps/q/key.pem"), "-----BEGIN PRIVATE KEY-----\nabc\n")

    script = String.replace(SeedScan.script(), "cd /opt/arbiter/seed", "cd #{root}")
    {out, 0} = System.cmd("sh", ["-c", script])

    assert {:error, hits} = SeedScan.check(out)
    assert {:userinfo_url, "deps/p/.git/config"} in hits
    assert {:credential_file, "./deps/q/key.pem"} in hits
    refute Enum.any?(hits, &match?({_, "./deps/q/cacerts.pem"}, &1))
    refute Enum.any?(hits, &match?({_, "deps/q/.git/config"}, &1))
  end
end
