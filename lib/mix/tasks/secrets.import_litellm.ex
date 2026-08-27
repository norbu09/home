defmodule Mix.Tasks.Secrets.ImportLitellm do
  @moduledoc """
  Import provider API keys from a LiteLLM `.env` file into Home's encrypted store.

      mix secrets.import_litellm
      mix secrets.import_litellm --path /path/to/.env
  """

  use Mix.Task

  @shortdoc "Import LiteLLM API keys into the encrypted secret store"

  @default_path Path.expand("~/litellm/.env")

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    path = path_arg(args) || @default_path

    unless File.exists?(path) do
      Mix.raise("LiteLLM env file not found: #{path}")
    end

    {imported, skipped, keys} = Home.Secrets.LiteLLMImporter.import_file(path)

    Enum.each(Enum.reverse(keys), fn {service, key} ->
      Mix.shell().info("imported #{service}/#{key}")
    end)

    Mix.shell().info("LiteLLM secret import complete: #{imported} imported, #{skipped} skipped")
  end

  defp path_arg(args) do
    case OptionParser.parse!(args, strict: [path: :string]) do
      {[path: path], []} -> path
      {_, []} -> nil
      {_, extra} -> Mix.raise("unexpected arguments: #{Enum.join(extra, " ")}")
    end
  end
end
