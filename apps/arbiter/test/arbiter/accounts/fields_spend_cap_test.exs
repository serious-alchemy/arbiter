defmodule Arbiter.Accounts.FieldsSpendCapTest do
  @moduledoc """
  The dollar spend cap's `quota_config` keys (bd-a6grlr): `spend_cap`,
  `spend_window`, `spend_mode` and `spend_metered`, validated by the one
  account-field registry every surface shares.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.Fields

  test "the four spend keys are registered quota_config keys" do
    for key <- ~w(spend_cap spend_window spend_mode spend_metered) do
      assert key in Fields.quota_keys()
    end
  end

  test "a valid cap validates, coercing the amount to a float" do
    assert {:ok, validated} =
             Fields.validate_quota_config(%{
               "spend_cap" => 20,
               "spend_window" => "week",
               "spend_mode" => "paced",
               "spend_metered" => true
             })

    assert validated == %{
             "spend_cap" => 20.0,
             "spend_window" => "week",
             "spend_mode" => "paced",
             "spend_metered" => true
           }
  end

  test "string amounts and booleans (CLI / form input) are coerced" do
    assert {:ok, %{"spend_cap" => 12.5, "spend_metered" => false}} =
             Fields.validate_quota_config(%{"spend_cap" => "12.5", "spend_metered" => "false"})
  end

  test "a non-positive or non-numeric amount is refused" do
    for bad <- [0, -5, "abc", "", nil, true] do
      assert {:error, {:invalid_quota_config, msg}} =
               Fields.validate_quota_config(%{"spend_cap" => bad})

      assert msg =~ "spend_cap"
    end
  end

  test "an unknown window or mode is refused" do
    assert {:error, {:invalid_quota_config, msg}} =
             Fields.validate_quota_config(%{"spend_window" => "fortnight"})

    assert msg =~ "spend_window"

    assert {:error, {:invalid_quota_config, msg}} =
             Fields.validate_quota_config(%{"spend_mode" => "strict"})

    assert msg =~ "spend_mode"
  end

  test "a patch can clear each key with nil, and `none` clears the cap" do
    assert {:ok, %{"spend_cap" => nil, "spend_window" => nil}} =
             Fields.validate_quota_config(%{"spend_cap" => nil, "spend_window" => nil}, :patch)

    assert {:ok, %{"spend_cap" => nil}} =
             Fields.validate_quota_config(%{"spend_cap" => "none"}, :patch)
  end
end
