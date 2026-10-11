defmodule Arbiter.Test.ArbEscriptFixture do
  @moduledoc """
  A stand-in for the `arb` escript (bd-59m96o): a real escript whose one module
  was compiled by the Erlang/OTP running the tests, behind the header
  `mix escript.build` writes for arb (`ArbiterCli.MixProject.escript/0`):

      #! /usr/bin/env escript
      %% arb-otp=29
      %%! -escript main arbfix

  Its BEAM is in this OTP's format, so an older OTP refuses it exactly as it
  refuses the real arb (an OTP 28+ build on OTP 27: "corrupt atom table").
  Run, it prints `arbfix otp=<release of the VM running it> args=<a,b,...>`.
  """

  @module_source """
  -module(arbfix).
  -export([main/1]).
  main(Args) ->
      io:format("arbfix otp=~s args=~s~n",
                [erlang:system_info(otp_release), lists:join(",", Args)]).
  """

  @doc """
  Write the escript into `dir` and return its path. Options: `:name` (default
  `"arb.escript"`) and `:stamp`, the comment line's OTP release (default this
  VM's; `nil` writes the empty comment an escript built before bd-59m96o has).
  """
  @spec build!(Path.t(), keyword()) :: Path.t()
  def build!(dir, opts \\ []) do
    File.mkdir_p!(dir)
    path = Path.join(dir, Keyword.get(opts, :name, "arb.escript"))

    comment =
      case Keyword.get(opts, :stamp, System.otp_release()) do
        nil -> ""
        otp -> "arb-otp=#{otp}"
      end

    src = Path.join(dir, "arbfix.erl")
    File.write!(src, @module_source)
    {:ok, :arbfix, beam} = :compile.file(String.to_charlist(src), [:binary, :return_errors])
    {:ok, {_, zip}} = :zip.create(~c"arbfix.zip", [{~c"arbfix.beam", beam}], [:memory])

    File.write!(
      path,
      ["#! /usr/bin/env escript\n", "%% #{comment}\n", "%%! -escript main arbfix\n", zip]
    )

    File.chmod!(path, 0o755)
    path
  end
end
