defmodule Arbiter.ToolchainPinsTest do
  @moduledoc """
  The Elixir/Erlang toolchain is pinned in several places that nothing else
  ties together: `.tool-versions` (mise and the worker-image generator), the CI
  matrix, the release workflow, the release OTP build script, the worker-image
  fallback and each app's `elixir:` requirement. A bump that misses one leaves
  CI, the published tarball and the worker image on different toolchains, so
  this test fails until they agree. `.tool-versions` is the source of truth.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image

  @root Path.expand("../../../..", __DIR__)

  defp read!(path), do: @root |> Path.join(path) |> File.read!()

  defp tool_versions do
    for line <- String.split(read!(".tool-versions"), "\n"),
        [tool, version | _] <- [line |> String.split("#") |> hd() |> String.split()],
        into: %{},
        do: {tool, version}
  end

  defp erlang, do: Map.fetch!(tool_versions(), "erlang")

  defp elixir do
    tool_versions() |> Map.fetch!("elixir") |> String.replace(~r/-otp-\d+\z/, "")
  end

  defp otp_major, do: erlang() |> String.split(".") |> hd()

  defp scan(text, regex), do: regex |> Regex.scan(text, capture: :all_but_first) |> List.flatten()

  test ".tool-versions pins an Elixir built for the pinned OTP major" do
    assert tool_versions()["elixir"] == "#{elixir()}-otp-#{otp_major()}"
    assert elixir() =~ ~r/\A1\.20\.\d+\z/
    assert otp_major() == "29"
  end

  test "ci.yml installs the pinned toolchain in every job and keys caches on it" do
    ci = read!(".github/workflows/ci.yml")

    assert scan(ci, ~r/otp-version: "([^"]+)"/) == List.duplicate(erlang(), 2)
    assert scan(ci, ~r/elixir-version: "([^"]+)"/) == List.duplicate(elixir(), 2)

    keys = scan(ci, ~r/\$\{\{ runner\.os \}\}-(otp[^-]+-elixir[^-]+)-/)
    assert keys != []
    assert Enum.uniq(keys) == ["otp#{erlang()}-elixir#{elixir()}"]
  end

  test "release.yml installs the pinned Elixir for the pinned OTP major" do
    release = read!(".github/workflows/release.yml")

    assert scan(release, ~r/ELIXIR_VERSION="([^"]+)"/) == [elixir()]
    assert scan(release, ~r/OTP_MAJOR="([^"]+)"/) == [otp_major()]
    assert release =~ "Build Erlang/OTP #{otp_major()} with static OpenSSL"
  end

  test "the release OTP build script builds the pinned OTP" do
    script = read!("scripts/build-release-otp.sh")

    assert scan(script, ~r/^OTP_VERSION="([^"]+)"/m) == [erlang()]
  end

  test "the worker-image fallback toolchain is the pinned one" do
    assert Image.default_toolchain() == %{erlang: erlang(), elixir: elixir()}
  end

  test "every app requires the pinned Elixir minor" do
    [major, minor | _] = String.split(elixir(), ".")

    for app <- ~w(arbiter arbiter_web arbiter_cli arbiter_release_env) do
      assert scan(read!("apps/#{app}/mix.exs"), ~r/^\s*elixir: "([^"]+)"/m) ==
               ["~> #{major}.#{minor}"],
             "apps/#{app}/mix.exs elixir requirement"
    end
  end
end
