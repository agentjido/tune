Application.ensure_all_started(:req_llm)

for name <- ~w(OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY) do
  System.delete_env(name)
end

ExUnit.start(capture_log: true)
