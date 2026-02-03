require "../config/loader"
require "../providers/base"
require "../providers/litellm"
require "../providers/openai"
require "../providers/anthropic"
require "../providers/openrouter"
require "../providers/vllm"
require "../providers/antigravity"
require "../providers/gemini"
require "./context"
require "./tools/registry"
require "./tools/filesystem"
require "./tools/shell"
require "./tools/web"
require "./tools/memory"
require "../session/manager"
require "../mcp/manager"

module Crybot
  module Agent
    class Loop
      @config : Config::ConfigFile
      @provider : Providers::LLMProvider
      @context_builder : ContextBuilder
      @session_manager : Session::Manager
      @max_iterations : Int32
      @mcp_manager : MCP::Manager?

      def initialize(@config : Config::ConfigFile)
        @provider = create_provider
        @context_builder = ContextBuilder.new(@config)
        @session_manager = Session::Manager.instance
        @max_iterations = @config.agents.defaults.max_tool_iterations

        # Register built-in tools
        register_tools

        # Initialize MCP manager
        @mcp_manager = MCP::Manager.new(@config.mcp)
      end

      private def create_provider : Providers::LLMProvider
        model = @config.agents.defaults.model
        provider_name, actual_model = parse_model_string(model)

        case provider_name
        when "openai", "gpt"       then create_openai(actual_model)
        when "anthropic", "claude" then create_anthropic(actual_model)
        when "openrouter"          then create_openrouter(actual_model)
        when "vllm"                then create_vllm(actual_model)
        when "antigravity"         then create_antigravity(actual_model)
        when "gemini"              then create_gemini(actual_model)
        else                            create_zhipu(actual_model)
        end
      end

      private def create_openai(model : String)
        api_key = @config.providers.openai.api_key
        raise "OpenAI API key not configured" if api_key.empty?
        Providers::OpenAIProvider.new(api_key, model)
      end

      private def create_anthropic(model : String)
        api_key = @config.providers.anthropic.api_key
        raise "Anthropic API key not configured" if api_key.empty?
        Providers::AnthropicProvider.new(api_key, model)
      end

      private def create_openrouter(model : String)
        api_key = @config.providers.openrouter.api_key
        raise "OpenRouter API key not configured" if api_key.empty?
        Providers::OpenRouterProvider.new(api_key, model)
      end

      private def create_vllm(model : String)
        api_base = @config.providers.vllm.api_base
        raise "vLLM api_base not configured" if api_base.empty?
        Providers::VLLMProvider.new(@config.providers.vllm.api_key, api_base, model)
      end

      private def create_antigravity(model : String)
        api_base = @config.providers.antigravity.api_base
        raise "Antigravity api_base not configured" if api_base.empty?
        Providers::AntigravityProvider.new(@config.providers.antigravity.api_key, api_base, model)
      end

      private def create_gemini(model : String)
        project_id = @config.providers.gemini.project_id
        location = @config.providers.gemini.location
        auth_command = @config.providers.gemini.auth_command

        raise "Gemini project_id not configured" if project_id.empty?

        Providers::GeminiProvider.new(project_id, location, auth_command, model)
      end

      private def create_zhipu(model : String)
        api_key = @config.providers.zhipu.api_key
        raise "Zhipu API key not configured" if api_key.empty?
        Providers::ZhipuProvider.new(api_key, model)
      end

      private def parse_model_string(model : String) : Tuple(String, String)
        parts = model.split('/', 2)
        if parts.size == 2
          {parts[0], parts[1]}
        else
          # Default provider based on model name patterns
          provider = detect_provider_from_model(model)
          {provider, model}
        end
      end

      private def detect_provider_from_model(model : String) : String
        case model
        when /^gpt-/        then "openai"
        when /^claude-/     then "anthropic"
        when /^glm-/        then "zhipu"
        when /^deepseek-/   then "openrouter"
        when /^qwen-/       then "openrouter"
        when /^antigravity/ then "antigravity"
        when /^gemini-/     then "gemini"
        else                     "zhipu"
        end
      end

      def process(session_key : String, user_message : String) : String
        # Get or create session
        history = @session_manager.get_or_create(session_key)

        # Build messages
        messages = @context_builder.build_messages(user_message, history)

        # Main loop
        iteration = 0
        final_response = ""

        while iteration < @max_iterations
          iteration += 1

          # Call LLM
          tools_schemas = Tools::Registry.to_schemas
          response = @provider.chat(messages, tools_schemas, @config.agents.defaults.model)

          # Add assistant message to history
          messages = @context_builder.add_assistant_message(messages, response)

          # Check for tool calls
          calls = response.tool_calls
          if calls && !calls.empty?
            # Execute each tool call
            calls.each do |tool_call|
              result = Tools::Registry.execute(tool_call.name, tool_call.arguments)
              messages = @context_builder.add_tool_result(messages, tool_call, result)
            end

            # Continue loop to get next response with tool results
            next
          end

          # No tool calls, we're done
          final_response = response.content || ""
          break
        end

        if iteration >= @max_iterations
          final_response = "Error: Maximum tool iterations (#{@max_iterations}) exceeded."
        end

        # Save session (only keep last 50 messages to avoid bloating)
        if messages.size > 50
          messages_to_save = messages[-50..-1]
        else
          messages_to_save = messages
        end
        @session_manager.save(session_key, messages_to_save)

        final_response
      end

      private def register_tools : Nil
        Tools::Registry.register(Tools::ReadFileTool.new)
        Tools::Registry.register(Tools::WriteFileTool.new)
        Tools::Registry.register(Tools::EditFileTool.new)
        Tools::Registry.register(Tools::ListDirTool.new)
        Tools::Registry.register(Tools::ExecTool.new)
        Tools::Registry.register(Tools::WebSearchTool.new)
        Tools::Registry.register(Tools::WebFetchTool.new)

        # Memory tools
        Tools::Registry.register(Tools::SaveMemoryTool.new)
        Tools::Registry.register(Tools::SearchMemoryTool.new)
        Tools::Registry.register(Tools::ListRecentMemoriesTool.new)
        Tools::Registry.register(Tools::RecordMemoryTool.new)
        Tools::Registry.register(Tools::MemoryStatsTool.new)
      end
    end
  end
end
