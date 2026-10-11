defmodule Arbiter.Accounts.AdmissionModeTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.AdmissionMode
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Settings

  defp account!(slug, attrs \\ %{}) do
    {:ok, account} =
      Ash.create(ProviderAccount, Map.merge(%{provider: :claude, slug: slug}, attrs))

    account
  end

  describe "the account field" do
    test "edit_account sets, reads back and clears the override" do
      account = account!("am-edit")
      assert account.admission == nil

      assert {:ok, %{admission: :enforce}} =
               Accounts.edit_account(account.id, %{"admission" => "enforce"})

      assert {:ok, %{admission: nil}} = Accounts.edit_account(account.id, %{"admission" => nil})
    end

    test "a bad mode is refused" do
      account = account!("am-bad")

      assert {:error, {:invalid_account, msg}} =
               Accounts.edit_account(account.id, %{"admission" => "strict"})

      assert msg =~ "admission"
    end
  end

  describe "effective/2" do
    test "falls back to the installation key and says so" do
      assert %{mode: :shadow, source: :installation} =
               AdmissionMode.effective(account!("am-inherit"), :shadow)

      assert %{mode: :legacy, source: :installation} = AdmissionMode.effective(nil, :legacy)
    end

    test "an override wins over the installation key" do
      account = account!("am-over", %{admission: :enforce})
      assert %{mode: :enforce, source: :account} = AdmissionMode.effective(account, :legacy)

      legacy = account!("am-legacy", %{admission: :legacy})
      assert %{mode: :legacy, source: :account} = AdmissionMode.effective(legacy, :enforce)
    end

    test "two accounts resolve to different modes under one installation key" do
      a = account!("am-a", %{admission: :enforce})
      b = account!("am-b")
      assert AdmissionMode.mode(a, :shadow) == :enforce
      assert AdmissionMode.mode(b, :shadow) == :shadow
    end
  end

  describe "walk_mode/0" do
    test "is the strictest of the installation key and every override" do
      assert AdmissionMode.walk_mode() == :legacy
      account!("am-w1", %{admission: :shadow})
      assert AdmissionMode.walk_mode() == :shadow
      account!("am-w2", %{admission: :enforce})
      assert AdmissionMode.walk_mode() == :enforce
    end

    test "the installation key counts when no account overrides" do
      {:ok, _} = Settings.set_scheduler_admission(:shadow)
      assert AdmissionMode.walk_mode() == :shadow
    end
  end
end
