require "./base"
require "../auth/token_store"
require "json"
require "http/client"
require "uuid"

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
        # Retry loop for rate limits (429) and auth errors
        max_retries = 3
        retry_count = 0
        
        loop do
          begin
            return attempt_chat(messages, tools, model)
          rescue e : Exception
            # Check for 429 Rate Limit
            if e.message && e.message.not_nil!.includes?("429")
              retry_count += 1
              if retry_count >= max_retries
                raise e # Give up after max retries
              end
              
              # Extract retry delay if available (basic implementation for now)
              delay = 1.seconds
              puts "Rate limited (429). Switching account (attempt #{retry_count}/#{max_retries})..."
              sleep delay
              next
            end

            # Check for 401/403 Auth Errors (invalid token/grant)
            if e.message && (e.message.not_nil!.includes?("401") || e.message.not_nil!.includes?("403"))
               # If it's an auth error, we should mark the account as failed and retry
               # This handles "invalid_grant" cases where a token is revoked
               retry_count += 1
               if retry_count >= max_retries
                 raise e
               end
               
               puts "Auth error. Switching account (attempt #{retry_count}/#{max_retries})..."
               sleep 1.seconds
               next
            end

            raise e # Re-raise other errors
          end
        end
      end

      private def attempt_chat(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Response
        token, project_id, email = Auth::TokenStore.get_valid_token("antigravity")
        
        # Clean up model name
        raw_model = model || @default_model
        
        # 1. Remove "antigravity-" prefix if present
        clean_model = raw_model.split('/').last
        clean_model = clean_model.gsub(/^antigravity-/, "")
        
        # 2. Add default tier suffix (-low) for gemini-3-pro if missing
        if clean_model.starts_with?("gemini-3-pro") && !clean_model.matches?(/-(low|medium|high)$/)
          actual_model = "#{clean_model}-low"
        else
          actual_model = clean_model
        end

        # Use the internal endpoint directly
        url = "#{API_ENDPOINT}/v1internal:generateContent"

        request_body = build_request_body(messages, tools)
        
        request_id = "agent-#{UUID.random}"
        session_id = "crybot-#{UUID.random}"
        
        # Add sessionId to the inner request
        request_body["sessionId"] = JSON::Any.new(session_id)
        
        # Wrap the request body in Antigravity's expected format
        body = {
          "project"     => JSON::Any.new(project_id),
          "model"       => JSON::Any.new(actual_model),
          "request"     => JSON::Any.new(request_body),
          "requestType" => JSON::Any.new("agent"),
          "userAgent"   => JSON::Any.new("antigravity"),
          "requestId"   => JSON::Any.new(request_id),
        }

        headers = HTTP::Headers{
          "Content-Type"        => "application/json",
          "Authorization"       => "Bearer #{token}",
          "User-Agent"          => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Antigravity/1.15.8 Chrome/138.0.7204.235 Electron/37.3.1 Safari/537.36",
          "X-Goog-Api-Client"   => "google-cloud-sdk vscode_cloudshelleditor/0.1",
          "Client-Metadata"     => "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}",
        }

        response = HTTP::Client.post(url, headers, body.to_json)

        unless response.success?
          # Record failure if rate limited (429) OR auth failed (401/403)
          if response.status_code == 429 || response.status_code == 401 || response.status_code == 403
             Auth::TokenStore.record_failure(email)
          end

          # If permission denied (403), try the default fallback project ID
          # But ONLY if we haven't already recorded a failure/rotated (to avoid infinite fallback loops on bad accounts)
          # Actually, we should try fallback FIRST before giving up on the account.
          if response.status_code == 403 && project_id != "rising-fact-p41fc"
            fallback_url = "#{API_ENDPOINT}/v1internal:generateContent"
            body["project"] = JSON::Any.new("rising-fact-p41fc")
            
            response = HTTP::Client.post(fallback_url, headers, body.to_json)
            
            unless response.success?
              if response.status_code == 429 || response.status_code == 401 || response.status_code == 403
                 Auth::TokenStore.record_failure(email)
              end
              raise "Antigravity API request failed (fallback): #{response.status_code} - #{response.body}"
            end
          else
            raise "Antigravity API request failed: #{response.status_code} - #{response.body}"
          end
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

        # Antigravity API wraps responses: { "response": { "candidates": [...] } }
        # Reference: opencode-antigravity-auth/dist/src/plugin/request-helpers.js
        response_obj = json["response"]? || json
        
        # Handle array-wrapped responses (API sometimes returns arrays)
        if response_obj.as_a?
          first_obj = response_obj.as_a.first?
          response_obj = first_obj if first_obj
        end

        candidates = response_obj["candidates"]?
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
