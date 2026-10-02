defmodule Arbiter.Worker.Egress.PolicyTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Egress.Policy

  defp ctx(opts) do
    {:ok, baseline} = Policy.normalize_baseline(Keyword.get(opts, :baseline, []))

    %{
      baseline: baseline,
      grants: Keyword.get(opts, :grants, []),
      safe_defaults_exclude: Keyword.get(opts, :exclude, [])
    }
  end

  describe "exact host:port matching" do
    test "a baseline entry allows exactly its host and port" do
      c = ctx(baseline: ["repo.hex.pm:443"])
      assert {:allow, :baseline} = Policy.decide("repo.hex.pm", 443, c)
      assert {:deny, :not_granted} = Policy.decide("repo.hex.pm", 80, c)
      assert {:deny, :not_granted} = Policy.decide("builds.hex.pm", 443, c)
      assert {:deny, :not_granted} = Policy.decide("evil.repo.hex.pm", 443, c)
    end

    test "hosts compare case-insensitively and ignore a trailing dot" do
      c = ctx(baseline: ["Repo.Hex.PM:443"])
      assert {:allow, :baseline} = Policy.decide("REPO.hex.pm.", 443, c)
    end

    test "a ticket grant allows its host and port, with or without the network: prefix" do
      c = ctx(grants: ["api.example.com:443", "network:status.example.com:8443"])
      assert {:allow, :grant} = Policy.decide("api.example.com", 443, c)
      assert {:allow, :grant} = Policy.decide("status.example.com", 8443, c)
      assert {:deny, :not_granted} = Policy.decide("status.example.com", 443, c)
    end

    test "an unparseable target is denied" do
      c = ctx(baseline: ["a.example.com:443"])
      assert {:deny, :invalid_target} = Policy.decide("bad host", 443, c)
      assert {:deny, :invalid_target} = Policy.decide("a.example.com", 0, c)
      assert {:deny, :invalid_target} = Policy.decide("a.example.com", 70_000, c)
      assert {:deny, :invalid_target} = Policy.decide("", 443, c)
    end
  end

  describe "wildcards" do
    test "a leading *. in an operator baseline matches subdomains, not the apex" do
      c = ctx(baseline: ["*.hex.pm:443"])
      assert {:allow, :baseline} = Policy.decide("repo.hex.pm", 443, c)
      assert {:allow, :baseline} = Policy.decide("a.b.hex.pm", 443, c)
      assert {:deny, :not_granted} = Policy.decide("hex.pm", 443, c)
      assert {:deny, :not_granted} = Policy.decide("evilhex.pm", 443, c)
      assert {:deny, :not_granted} = Policy.decide("repo.hex.pm", 80, c)
    end

    test "a wildcard in a ticket grant is refused at normalization" do
      assert {:error, :wildcard_not_allowed} = Policy.normalize_grant("*.googleapis.com:443")
      assert {:error, :wildcard_not_allowed} = Policy.normalize_grant("network:*.example.com:443")
    end

    test "a wildcard grant that reaches decide/3 anyway matches nothing" do
      c = ctx(grants: ["*.googleapis.com:443"])
      assert {:deny, :not_granted} = Policy.decide("storage.googleapis.com", 443, c)
    end

    test "baseline wildcards must be a leading *. over at least two labels" do
      assert {:error, {:invalid_baseline, "*:443"}} = Policy.normalize_baseline(["*:443"])
      assert {:error, {:invalid_baseline, "*.com:443"}} = Policy.normalize_baseline(["*.com:443"])

      assert {:error, {:invalid_baseline, "a.*.com:443"}} =
               Policy.normalize_baseline(["a.*.com:443"])

      assert {:error, {:invalid_baseline, "*.hex.pm:*"}} =
               Policy.normalize_baseline(["*.hex.pm:*"])
    end

    test "baseline and grants require an explicit port" do
      assert {:error, :missing_port} = Policy.normalize_grant("api.example.com")

      assert {:error, {:invalid_baseline, "api.example.com"}} =
               Policy.normalize_baseline(["api.example.com"])
    end
  end

  describe ":no_public_upload hard deny" do
    @hosts ["catbox.moe", "0x0.st", "gist.github.com"]

    test "denied even when granted or in the baseline" do
      for host <- @hosts do
        c = ctx(baseline: ["#{host}:443"], grants: ["#{host}:443"])
        assert {:deny, :public_upload} = Policy.decide(host, 443, c), host
      end
    end

    test "subdomains of a listed host are denied too" do
      c = ctx(grants: ["files.catbox.moe:443", "litter.catbox.moe:443"])
      assert {:deny, :public_upload} = Policy.decide("files.catbox.moe", 443, c)
      assert {:deny, :public_upload} = Policy.decide("litter.catbox.moe", 443, c)
    end

    test "a wildcard baseline cannot reach a public upload host" do
      c = ctx(baseline: ["*.github.com:443"])
      assert {:deny, :public_upload} = Policy.decide("gist.github.com", 443, c)
      assert {:allow, :baseline} = Policy.decide("api.github.com", 443, c)
    end

    test "a workspace safe_defaults_exclude of :no_public_upload lifts it" do
      for host <- @hosts do
        c = ctx(grants: ["#{host}:443"], exclude: [:no_public_upload])
        assert {:allow, :grant} = Policy.decide(host, 443, c), host
      end
    end

    test "excluding another category does not lift it" do
      c = ctx(grants: ["catbox.moe:443"], exclude: [:no_force_push])
      assert {:deny, :public_upload} = Policy.decide("catbox.moe", 443, c)
    end

    test "an unrelated lookalike host is not caught" do
      c = ctx(grants: ["notcatbox.moe:443"])
      assert {:allow, :grant} = Policy.decide("notcatbox.moe", 443, c)
    end
  end

  describe "IP literals" do
    test "match exactly and canonicalise" do
      c = ctx(grants: ["10.1.2.3:5432"])
      assert {:allow, :grant} = Policy.decide("10.1.2.3", 5432, c)
      assert {:deny, :not_granted} = Policy.decide("10.1.2.4", 5432, c)
    end

    test "a bracketed IPv6 literal parses" do
      assert {:ok, {"::1", 443}} = Policy.parse_authority("[::1]:443")
      assert {:ok, {"example.com", 443}} = Policy.parse_authority("example.com:443")
      assert {:error, _} = Policy.parse_authority("example.com")
      assert {:error, _} = Policy.parse_authority("example.com:abc")
    end
  end
end
