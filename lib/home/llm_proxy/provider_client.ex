defmodule Home.LLMProxy.ProviderClient do
  @moduledoc "Network adapter around Agentic provider calls."

  alias Agentic.LLM.{Credentials, Provider}
  alias Home.LLMProxy.ProviderCatalog
  alias Home.Secrets.Store

  def chat({provider, model_id}, params) do
    with {:ok, module} <- ProviderCatalog.fetch(provider) do
      Provider.chat(module, params, provider_opts(module, model_id))
    end
  end

  def stream_chat({provider, model_id}, params, on_chunk) do
    with {:ok, module} <- ProviderCatalog.fetch(provider) do
      Provider.stream_chat(
        module,
        params,
        provider_opts(module, model_id) ++ [on_chunk: on_chunk]
      )
    end
  end

  def embeddings({provider, model_id}, input) do
    with {:ok, module} <- ProviderCatalog.fetch(provider),
         {:ok, creds} <- resolve_credentials(module) do
      transport = module.transport()
      base_url = creds.base_url_override || module.default_base_url()

      request =
        transport.build_embedding_request(input,
          base_url: base_url,
          api_key: creds.api_key,
          model: model_id,
          extra_headers: creds.headers
        )

      case Req.post(request.url,
             json: request.body,
             headers: request.headers,
             receive_timeout: timeout()
           ) do
        {:ok, %{status: status, body: body, headers: headers}} ->
          transport.parse_embedding_response(status, body, headers)

        {:error, exception} ->
          {:error,
           %Agentic.LLM.Error{
             message: "HTTP error: #{Exception.message(exception)}",
             status: nil,
             classification: :timeout,
             raw: exception
           }}
      end
    end
  end

  defp resolve_credentials(module) do
    case Credentials.resolve(module, credential_opts(module)) do
      {:ok, creds} ->
        {:ok, creds}

      :not_configured ->
        {:error, %{message: "#{module.id()} not configured", classification: :auth}}
    end
  end

  defp provider_opts(module, model_id) do
    [model: model_id, receive_timeout: timeout()]
    |> Keyword.merge(credential_opts(module))
  end

  defp credential_opts(module) do
    case Store.get_first_env(module.env_vars()) do
      {:ok, key} -> [api_key: key]
      {:error, _} -> []
    end
  end

  defp timeout do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:receive_timeout, 120_000)
  end
end
