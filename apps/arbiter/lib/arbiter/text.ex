defmodule Arbiter.Text do
  @moduledoc """
  UTF-8-safe text helpers. A byte-offset cut (`binary_part/3`) can land inside
  a multi-byte codepoint (`±` is `<<0xC2, 0xB1>>`, box-drawing characters are
  three bytes); the leftover byte makes a string that fails `Jason.encode!/1`.
  Every excerpt of tool / CI output that ends up in a note, message or brief
  goes through here.
  """

  @doc "Replaces invalid UTF-8 sequences with U+FFFD. `nil` passes through."
  @spec scrub(String.t() | nil) :: String.t() | nil
  def scrub(nil), do: nil

  def scrub(text) when is_binary(text),
    do: if(String.valid?(text), do: text, else: do_scrub(text))

  defp do_scrub(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {_, ok, <<_bad, rest::binary>>} -> ok <> "�" <> do_scrub(rest)
    end
  end

  @doc "The first `max` bytes of `text`, without a trailing partial codepoint."
  @spec head_bytes(String.t(), non_neg_integer()) :: String.t()
  def head_bytes(text, max) when is_binary(text) and byte_size(text) <= max, do: text

  def head_bytes(text, max) when is_binary(text) do
    text |> binary_part(0, max) |> drop_trailing_partial()
  end

  @doc "The last `max` bytes of `text`, without a leading partial codepoint."
  @spec tail_bytes(String.t(), non_neg_integer()) :: String.t()
  def tail_bytes(text, max) when is_binary(text) and byte_size(text) <= max, do: text

  def tail_bytes(text, max) when is_binary(text) do
    size = byte_size(text)
    drop_leading_continuations(binary_part(text, size - max, max))
  end

  defp drop_leading_continuations(<<b, rest::binary>>) when b in 0x80..0xBF,
    do: drop_leading_continuations(rest)

  defp drop_leading_continuations(bin), do: bin

  defp drop_trailing_partial(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {_, valid, _rest} -> valid
    end
  end
end
