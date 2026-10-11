defmodule ArbiterCli.EscriptStampTest do
  @moduledoc """
  bd-59m96o: the `arb` escript records the Erlang/OTP release it was compiled
  on in its comment line (`%% arb-otp=29`). A BEAM file loads only on that
  release or a newer one, so the server reads the stamp to give worker images a
  runtime arb can load (`Arbiter.Worker.ArbCli.built_otp/1`), and the launcher
  that runs arb inside a container reads it to refuse an older Erlang clearly.
  """
  use ExUnit.Case, async: true

  test "the escript's comment line carries the release it is compiled on" do
    assert Mix.Project.config()[:escript][:comment] == "arb-otp=#{System.otp_release()}"
  end
end
