defmodule Home.LLMProxyTestClient do
  alias Agentic.LLM.Response

  def chat({:zai, "glm-5.2"}, _params) do
    {:error, %{message: "rate limited", classification: :rate_limit, retry_after_ms: 1}}
  end

  def chat({provider, model}, params) do
    {:ok,
     %Response{
       content: [%{type: :text, text: "served by #{provider}/#{model}"}],
       stop_reason: :end_turn,
       usage: %{input_tokens: length(params["messages"] || []), output_tokens: 4},
       model_id: "#{provider}/#{model}",
       raw: %{}
     }}
  end

  def stream_chat({:zai, "glm-5.2"}, _params, on_chunk) do
    on_chunk.("bad first route")
    {:error, %{message: "stream failed", classification: :overloaded}}
  end

  def stream_chat({_provider, _model}, _params, on_chunk) do
    on_chunk.("hello")
    on_chunk.(" world")

    {:ok,
     %Response{
       content: [%{type: :text, text: "hello world"}],
       stop_reason: :end_turn,
       usage: %{input_tokens: 1, output_tokens: 2},
       model_id: "test/stream",
       raw: %{}
     }}
  end

  def embeddings({_provider, _model}, input) when is_list(input) do
    {:ok, Enum.map(input, fn _ -> [0.1, 0.2, 0.3] end)}
  end

  def embeddings({_provider, _model}, _input), do: {:ok, [[0.1, 0.2, 0.3]]}
end
