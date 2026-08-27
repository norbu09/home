defmodule Home.Secrets.StoreTest do
  use Home.DataCase, async: false

  alias Home.Secrets.Store

  test "stores and reads a secret without exposing plaintext in the row" do
    assert {:ok, secret} = Store.put("llm", "TEST_API_KEY", "sk-test", description: "test key")
    assert secret.encrypted_value != "sk-test"
    assert {:ok, "sk-test"} = Store.get("llm", "TEST_API_KEY")
  end

  test "falls back to the matching env var when the db secret is absent" do
    System.put_env("ENV_ONLY_KEY", "env-secret")

    try do
      assert {:ok, "env-secret"} = Store.get("llm", "ENV_ONLY_KEY")
    after
      System.delete_env("ENV_ONLY_KEY")
    end
  end
end
