require "./base"
require "../auth/token_store"
require "json"
require "http/client"

module Crybot
  module Providers
    # Antigravity provider (Native Google Protocol)
    class AntigravityProvider < LLMProvider
      DEFAULT_MODEL = "antigravity-gemini-3-pro"

      # Using daily sandbox as per reference implementation
      API_ENDPOINT = "https://daily-cloudcode-pa.sandbox.googleapis.com"

      def initialize(@api_key : String, @api_base : String, default_model : String = DEFAULT_MODEL)
        @default_model = default_model
      end

      def chat(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Response
        token, project_id = Auth::TokenStore.get_valid_token("antigravity")
        actual_model = model || @default_model

        # Use the internal endpoint directly, passing model and project in the body
        url = "#{API_ENDPOINT}/v1internal:generateContent"

        body = build_request_body(messages, tools)
        
        # Inject model and project into the body
        # Note: The gateway expects the model name to be passed in the body.
        # We also pass the project ID.
        body["model"] = JSON::Any.new(actual_model)
        body["project"] = JSON::Any.new(project_id)

        headers = HTTP::Headers{
          "Content-Type"        => "application/json",
          "Authorization"       => "Bearer #{token}",
          "X-Goog-User-Project" => project_id,
          "User-Agent"          => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Antigravity/1.15.8 Chrome/138.0.7204.235 Electron/37.3.1 Safari/537.36",
          "X-Goog-Api-Client"   => "google-cloud-sdk vscode_cloudshelleditor/0.1",
          "Client-Metadata"     => "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}",
        }

        response = HTTP::Client.post(url, headers, body.to_json)

        unless response.success?
          raise "Antigravity API request failed: #{response.status_code} - #{response.body}"
        end

        parse_response(response.body)
      end

      private def build_request_body(messages : Array(Message), tools : Array(ToolDef)?) : Hash(String, JSON::Any)
        # Reuse logic from GeminiProvider since we are hitting a Google API
        contents = [] of Hash(String, JSON::Any)
        system_instruction = nil

        messages.each do |msg|
          case msg.role
          when "system"
            system_instruction = {
              "parts" => [{"text" => msg.content || ""}],
            }
          when "user"
            contents << {
              "role"  => JSON::Any.new("user"),
              "parts" => JSON::Any.new([JSON::Any.new({"text" => JSON::Any.new(msg.content || "")})]),
            }
          when "assistant"
            contents << {
              "role"  => JSON::Any.new("model"),
              "parts" => JSON::Any.new([JSON::Any.new({"text" => JSON::Any.new(msg.content || "")})]),
            }
          end
        end

        body = {
          "contents"         => JSON::Any.new(contents.map { |content| JSON::Any.new(content) }),
          "generationConfig" => JSON::Any.new({
            "temperature"     => JSON::Any.new(0.7),
            "maxOutputTokens" => JSON::Any.new(8192),
          }),
        }

        if system_instruction
          # Convert to JSON::Any structure
          parts = system_instruction["parts"].map { |part| JSON::Any.new(part.transform_values { |val| JSON::Any.new(val) }) }
          body["systemInstruction"] = JSON::Any.new({"parts" => JSON::Any.new(parts)})
        end

        body
      end

      private def parse_response(body : String) : Response
        json = JSON.parse(body)

        candidates = json["candidates"]?
        if candidates.nil? || !candidates.as_a? || candidates.as_a.empty?
          return Response.new(content: "Error: No candidates returned")
        end

        candidate = candidates[0]
        content_parts = candidate["content"]? ? candidate["content"]["parts"]? : nil

        text_content = ""

        if content_parts && content_parts.as_a?
          content_parts.as_a.each do |part|
            if text = part["text"]?
              text_content += text.as_s
            end
          end
        end

        Response.new(content: text_content)
      end
    end
  end
end
