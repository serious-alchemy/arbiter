defmodule Arbiter.Worker.DepsRelocate.EtfTest do
  @moduledoc """
  SI5: `DepsRelocate` rewrites a Mix manifest's recorded directory without decoding the
  term, because a decode with `:safe` refuses any manifest that names an atom this VM
  has not seen (every dependency's module names) and the relocation then silently does
  nothing. The rewrite walks the external term format, copies everything but the
  matching binaries and creates no atom.
  """
  use ExUnit.Case, async: true

  import Bitwise, only: [<<<: 2]

  alias Arbiter.Worker.DepsRelocate.Etf

  @from "/seed/scratch/src"
  @to "/work/run-1"

  defp rewrite!(term, opts \\ []) do
    bin = :erlang.term_to_binary(term, opts)
    assert {:ok, out} = Etf.rewrite(bin, @from, @to)
    :erlang.binary_to_term(out)
  end

  test "rewrites a binary equal to, or under, the old directory, wherever it sits" do
    term =
      {35, %{"a" => @from <> "/deps/x"}, [@from, "other", {:k, @from <> "/lib"}],
       %{(@from <> "/key") => 1}, 7.5, -3, 1 <<< 70, :atom, [1, 2, 3 | :improper]}

    assert rewrite!(term) ==
             {35, %{"a" => @to <> "/deps/x"}, [@to, "other", {:k, @to <> "/lib"}],
              %{(@to <> "/key") => 1}, 7.5, -3, 1 <<< 70, :atom, [1, 2, 3 | :improper]}
  end

  test "a path that only shares a prefix with the old directory is left alone" do
    term = {@from <> "-other/deps", @from <> "x"}
    assert Etf.rewrite(:erlang.term_to_binary(term), @from, @to) == :unchanged
  end

  test "a term that does not mention the directory is :unchanged" do
    assert Etf.rewrite(:erlang.term_to_binary({:a, "b", [1]}), @from, @to) == :unchanged
  end

  test "handles compressed terms, big tuples, strings and non-ASCII atoms" do
    big = List.to_tuple(Enum.map(1..300, &{&1, @from <> "/#{&1}"}))
    term = {big, ~c"abc", :héllo, "bits"}
    out = rewrite!(term, [:compressed])
    assert elem(out, 1) == ~c"abc"
    assert elem(out, 2) == :héllo
    assert elem(elem(out, 0), 299) == {300, @to <> "/300"}
  end

  test "bitstrings, and a binary that is not a path, pass through untouched" do
    term = {<<1, 2, 3::size(5)>>, <<0, 255>>, @from}
    assert rewrite!(term) == {<<1, 2, 3::size(5)>>, <<0, 255>>, @to}
  end

  test "creates no atom: a manifest naming atoms this VM has never seen is rewritten" do
    # Hand-encoded (SMALL_ATOM_UTF8_EXT) so the atom is never interned in this VM: a
    # `:safe` decode refuses it, which is why the relocation walks the bytes instead.
    unseen = "etf_never_interned_#{System.unique_integer([:positive])}"
    atom_ext = <<119, byte_size(unseen)::8, unseen::binary>>
    path = @from <> "/deps"
    moved = @to <> "/deps"
    hand = <<131, 104, 2, atom_ext::binary, 109, byte_size(path)::32, path::binary>>

    assert_raise ArgumentError, fn -> :erlang.binary_to_term(hand, [:safe]) end
    assert {:ok, out} = Etf.rewrite(hand, @from, @to)
    assert out == <<131, 104, 2, atom_ext::binary, 109, byte_size(moved)::32, moved::binary>>
  end

  test "anything it cannot walk is :error, never a guess" do
    assert Etf.rewrite("garbage", @from, @to) == :error
    assert Etf.rewrite(<<131, 104, 2, 97, 1>>, @from, @to) == :error
    # An unknown tag (a pid) is not something a manifest holds.
    assert Etf.rewrite(:erlang.term_to_binary(self()), @from, @to) == :error
    # A compressed term that claims to be larger than the cap.
    assert Etf.rewrite(<<131, 80, 4_000_000_000::32, 0>>, @from, @to) == :error
  end
end
