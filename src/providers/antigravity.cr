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

      # Antigravity requires SNI. The "unrecognized name" error suggests the server (gateway)
      # is strict about SNI matching the host.
      # Crystal's HTTP::Client should handle this, but let's be explicit about the endpoint
      # by ensuring we are hitting the correct hostname.
      # The default config has https://api.antigravity.ai/v1.
      #
      # WAIT - Looking at the error "SSL_connect: error:0A000458:SSL routines::tlsv1 unrecognized name"
      # This usually happens when connecting to an IP address with HTTPS, or when the server
      # requires SNI and the client isn't sending it correctly for the specific host.
      #
      # Antigravity is actually a proxy. The URL "https://api.antigravity.ai/v1" might be correct,
      # but let's double check if we need to set the hostname in TLS context.
      #
      # Actually, the reference implementation uses "https://daily-cloudcode-pa.sandbox.googleapis.com".
      # The config in loader.cr was set to "https://api.antigravity.ai/v1" which might be wrong or a placeholder.
      #
      # Let's fix the default API base in the code to match the reference implementation
      # if the user hasn't changed it.
      #
      # Reference:
      # export const ANTIGRAVITY_ENDPOINT_DAILY = "https://daily-cloudcode-pa.sandbox.googleapis.com";
      #
      # If the config has the placeholder "https://api.antigravity.ai/v1", we should probably use the real one.
      #
      # Let's override endpoint_url to handle this.

      private def endpoint_url : String
        base = @api_base
        # Fix placeholder if present
        if base == "https://api.antigravity.ai/v1"
          base = "https://daily-cloudcode-pa.sandbox.googleapis.com"
        end
        "#{base}/v1/chat/completions"
      end
    end
  end
end
