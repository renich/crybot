require "./openai_base"
require "../auth/token_store"

module Crybot
  module Providers
    # Antigravity provider (OpenAI-compatible)
    class AntigravityProvider < OpenAICompatible
      DEFAULT_MODEL = "antigravity-gemini-3-pro"

      def initialize(api_key : String, api_base : String, default_model : String = DEFAULT_MODEL)
        super(api_key, default_model, api_base)
      end

      private def build_headers : HTTP::Headers
        token, project_id = Auth::TokenStore.get_valid_token("antigravity")

        headers = HTTP::Headers{
          "Content-Type"        => "application/json",
          "Authorization"       => "Bearer #{token}",
          "X-Goog-User-Project" => project_id,
          "User-Agent"          => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Antigravity/1.15.8 Chrome/138.0.7204.235 Electron/37.3.1 Safari/537.36",
          "X-Goog-Api-Client"   => "google-cloud-sdk vscode_cloudshelleditor/0.1",
          "Client-Metadata"     => "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}",
        }
        headers
      end
    end
  end
end
