defmodule Home.SettingsTest do
  use Home.DataCase, async: false

  alias Home.Settings

  test "put/get round-trips a string value" do
    assert {:ok, _} = Settings.put("test.key", "hello")
    assert Settings.get("test.key") == "hello"
  end

  test "put upserts an existing key" do
    assert {:ok, _} = Settings.put("test.upsert", "one")
    assert {:ok, _} = Settings.put("test.upsert", "two")
    assert Settings.get("test.upsert") == "two"
  end

  test "get_bool/2 defaults and toggles" do
    assert Settings.get_bool("test.missing") == false
    assert Settings.get_bool("test.missing", true) == true

    assert {:ok, _} = Settings.put_bool("test.flag", true)
    assert Settings.get_bool("test.flag") == true

    assert {:ok, _} = Settings.put_bool("test.flag", false)
    assert Settings.get_bool("test.flag") == false
  end

  test "put_json/get_json round-trip maps" do
    assert {:ok, _} = Settings.put_json("test.json", %{"a" => 1, "b" => ["x"]})
    assert Settings.get_json("test.json") == %{"a" => 1, "b" => ["x"]}
    assert Settings.get_json("test.absent", :fallback) == :fallback
  end
end
