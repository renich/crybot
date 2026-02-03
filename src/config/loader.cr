require "file_utils"
require "./schema"

module Crybot
  module Config
    class Loader
      CONFIG_DIR    = Path.home / ".crybot"
      CONFIG_FILE   = CONFIG_DIR / "config.yml"
      WORKSPACE_DIR = CONFIG_DIR / "workspace"
      SESSIONS_DIR  = CONFIG_DIR / "sessions"
      MEMORY_DIR    = WORKSPACE_DIR / "memory"
      SKILLS_DIR    = WORKSPACE_DIR / "skills"

      @@config : ConfigFile?

      def self.config_dir : Path
        CONFIG_DIR
      end

      def self.config_file : Path
        CONFIG_FILE
      end

      def self.workspace_dir : Path
        WORKSPACE_DIR
      end

      def self.sessions_dir : Path
        SESSIONS_DIR
      end

      def self.memory_dir : Path
        MEMORY_DIR
      end

      def self.skills_dir : Path
        SKILLS_DIR
      end

      def self.load : ConfigFile
        cached = @@config
        return cached unless cached.nil?

        unless File.exists?(CONFIG_FILE)
          ensure_directories
          create_default_config
          puts "Created default configuration at #{CONFIG_FILE}"
        end

        content = File.read(CONFIG_FILE)
        result = ConfigFile.from_yaml(content)
        @@config = result
        result
      end

      def self.reload : ConfigFile
        @@config = nil
        load
      end

      def self.ensure_directories : Nil
        Dir.mkdir_p(CONFIG_DIR) unless Dir.exists?(CONFIG_DIR)
        Dir.mkdir_p(WORKSPACE_DIR) unless Dir.exists?(WORKSPACE_DIR)
        Dir.mkdir_p(SESSIONS_DIR) unless Dir.exists?(SESSIONS_DIR)
        Dir.mkdir_p(MEMORY_DIR) unless Dir.exists?(MEMORY_DIR)
        Dir.mkdir_p(SKILLS_DIR) unless Dir.exists?(SKILLS_DIR)
      end

      def self.create_default_config : Nil
        return if File.exists?(CONFIG_FILE)

        default_config = <<-YAML
        agents:
          defaults:
            model: glm-4.7-flash
            max_tokens: 8192
            temperature: 0.7
            max_tool_iterations: 20

        providers:
          zhipu:
            api_key: ""  # Get from https://open.bigmodel.cn/
          openai:
            api_key: ""  # Get from https://platform.openai.com/
          anthropic:
            api_key: ""  # Get from https://console.anthropic.com/
          openrouter:
            api_key: ""  # Get from https://openrouter.ai/
          vllm:
            api_key: ""  # Often empty for local vLLM
            api_base: ""  # e.g., http://localhost:8000/v1
          antigravity:
            api_key: ""
            api_base: "https://api.antigravity.ai/v1"
          gemini:
            project_id: ""
            location: "us-central1"
            auth_command: "gcloud auth print-access-token"

        channels:
          telegram:
            enabled: false
            token: ""
            allow_from: []

        tools:
          web:
            search:
              api_key: ""  # Brave Search API
              max_results: 5

        mcp:
          servers: []
          # Example MCP servers:
          # - name: filesystem
          #   command: npx -y @modelcontextprotocol/server-filesystem /path/to/allowed/directory
          # - name: github
          #   command: npx -y @modelcontextprotocol/server-github
          # - name: brave-search
          #   command: npx -y @modelcontextprotocol/server-brave-search
        YAML

        File.write(CONFIG_FILE, default_config)
      end
    end
  end
end
