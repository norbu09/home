defmodule Home.Secrets.LiteLLMImporterTest do
  use Home.DataCase, async: false

  alias Home.Secrets.{LiteLLMImporter, Store}

  @tag :tmp_dir
  test "imports LiteLLM subscription aliases under provider-compatible keys", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".env")

    File.write!(path, """
    KIMI_SUB_KEY=kimi-secret
    ZAI_SUB_KEY=zai-secret
    DEEPINFRA_API_KEY=deepinfra-secret
    NOVITA_API_KEY=novita-secret
    IGNORED_KEY=ignored
    """)

    assert {4, 0, keys} = LiteLLMImporter.import_file(path)
    assert {"llm", "KIMI_API_KEY"} in keys
    assert {"llm", "ZAI_API_KEY"} in keys
    assert {:ok, "kimi-secret"} = Store.get("llm", "KIMI_API_KEY")
    assert {:ok, "zai-secret"} = Store.get("llm", "ZAI_API_KEY")
    assert {:ok, "deepinfra-secret"} = Store.get("llm", "DEEPINFRA_API_KEY")
    assert {:ok, "novita-secret"} = Store.get("llm", "NOVITA_API_KEY")
  end
end
