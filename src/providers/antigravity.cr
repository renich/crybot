require "./base"
require "../auth/token_store"
require "json"
require "http/client"
require "uuid"

module Crybot
  module Providers
    class AntigravityProvider < LLMProvider
      DEFAULT_MODEL = "antigravity-gemini-3-pro"
      API_ENDPOINT  = "https://daily-cloudcode-pa.sandbox.googleapis.com"
      FALLBACK_PROJECT = "rising-fact-p41fc"

      def initialize(@api_key : String, @api_base : String, default_model : String = DEFAULT_MODEL)
        @default_model = default_model
      end

      def chat(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Response
        # Retry logic: try to cover all accounts if possible
        account_count = [Auth::TokenStore.list.size, 1].max
        max_retries = [account_count * 2, 5].max
        
        max_retries.times do |attempt|
          begin
            return attempt_chat(messages, tools, model)
          rescue e : Exception
            if retryable_error?(e)
              puts "Rate limit/Auth error. Retrying (attempt #{attempt + 1}/#{max_retries})..." if ENV["DEBUG"]?
              sleep 1.seconds
              next
            end
            raise e
          end
        end
        raise "Max retries exceeded for Antigravity API (tried #{max_retries} times). All accounts may be exhausted."
      end

      private def attempt_chat(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Response
        token, project_id, email = Auth::TokenStore.get_valid_token("antigravity")
        actual_model = resolve_model_name(model || @default_model)
        url = "#{API_ENDPOINT}/v1internal:generateContent"

        headers = HTTP::Headers{
          "Content-Type"      => "application/json",
          "Authorization"     => "Bearer #{token}",
          "User-Agent"        => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Antigravity/1.15.8 Chrome/138.0.7204.235 Electron/37.3.1 Safari/537.36",
          "X-Goog-Api-Client" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
          "Client-Metadata"   => "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}",
        }

        body = build_payload(project_id, actual_model, messages, tools)
        response = HTTP::Client.post(url, headers, body.to_json)

        # Fallback logic for permission/quota issues
        if (response.status_code == 403 || response.status_code == 429) && project_id != FALLBACK_PROJECT
          puts "Trying fallback project '#{FALLBACK_PROJECT}'..." if ENV["DEBUG"]?
          body["project"] = JSON::Any.new(FALLBACK_PROJECT)
          response = HTTP::Client.post(url, headers, body.to_json)
        end

        unless response.success?
          handle_api_failure(response, email)
        end

        parse_response(response.body)
      end

      private def retryable_error?(e : Exception) : Bool
        msg = e.message || ""
        msg.includes?("429") || msg.includes?("401") || msg.includes?("403")
      end

      private def resolve_model_name(raw_model : String) : String
        clean = raw_model.split('/').last.gsub(/^antigravity-/, "")
        if clean.starts_with?("gemini-3-pro") && !clean.matches?(/-(low|medium|high)$/)
          "#{clean}-low"
        else
          clean
        end
      end

      private def handle_api_failure(response : HTTP::Client::Response, email : String)
        if [401, 403, 429].includes?(response.status_code)
          Auth::TokenStore.record_failure(email)
        end
        raise "Antigravity API request failed: #{response.status_code} - #{response.body}"
      end

      private def build_payload(project_id : String, model : String, messages : Array(Message), tools : Array(ToolDef)?) : Hash(String, JSON::Any)
        request_body = build_inner_request(messages, tools)
        request_body["sessionId"] = JSON::Any.new("crybot-#{UUID.random}")

        {
          "project"     => JSON::Any.new(project_id),
          "model"       => JSON::Any.new(model),
          "request"     => JSON::Any.new(request_body),
          "requestType" => JSON::Any.new("agent"),
          "userAgent"   => JSON::Any.new("antigravity"),
          "requestId"   => JSON::Any.new("agent-#{UUID.random}"),
        }
      end

      private def build_inner_request(messages : Array(Message), tools : Array(ToolDef)?) : Hash(String, JSON::Any)
        contents = [] of Hash(String, JSON::Any)
        system_parts = [] of Hash(String, JSON::Any)

        messages.each do |msg|
          case msg.role
          when "system"
            system_parts << {"text" => JSON::Any.new(msg.content || "")}
          when "user"
            contents << {
              "role"  => JSON::Any.new("user"),
              "parts" => JSON::Any.new([JSON::Any.new({"text" => JSON::Any.new(msg.content || "")})]),
            }
          when "assistant"
            parts = [] of Hash(String, JSON::Any)
            parts << {"text" => JSON::Any.new(msg.content.not_nil!)} if msg.content
            if tool_calls = msg.tool_calls
              tool_calls.each do |call|
                parts << {
                  "functionCall" => JSON::Any.new({
                    "name" => JSON::Any.new(call.name),
                    "args" => JSON::Any.new(call.arguments.transform_values { |v| v }),
                  })
                }
              end
            end
            contents << {
              "role"  => JSON::Any.new("model"),
              "parts" => JSON::Any.new(parts.map { |p| JSON::Any.new(p) }),
            }
          when "tool"
            response_hash = begin
              JSON.parse(msg.content || "{}").as_h
            rescue
              {"result" => JSON::Any.new(msg.content || "")}
            end
            contents << {
              "role" => JSON::Any.new("function"),
              "parts" => JSON::Any.new([
                JSON::Any.new({
                  "functionResponse" => JSON::Any.new({
                    "name" => JSON::Any.new(msg.name || ""),
                    "response" => JSON::Any.new(response_hash)
                  })
                })
              ])
            }
          end
        end

        body = {
          "contents"         => JSON::Any.new(contents.map { |c| JSON::Any.new(c) }),
          "generationConfig" => JSON::Any.new({
            "temperature"     => JSON::Any.new(0.7),
            "maxOutputTokens" => JSON::Any.new(8192),
          }),
        }

        if !system_parts.empty?
          parts_json = system_parts.map { |p| JSON::Any.new(p) }
          body["systemInstruction"] = JSON::Any.new({"parts" => JSON::Any.new(parts_json)})
        end

        if tools && !tools.empty?
          tool_decls = tools.map do |t|
            {
              "name"        => JSON::Any.new(t.name),
              "description" => JSON::Any.new(t.description),
              "parameters"  => JSON::Any.new(t.parameters),
            }
          end
          body["tools"] = JSON::Any.new([
            JSON::Any.new({ "functionDeclarations" => JSON::Any.new(tool_decls.map { |d| JSON::Any.new(d) }) })
          ])
        end

        body
      end

      private def parse_response(body : String) : Response
        json = JSON.parse(body)
        root = json["response"]? || json
        root = root.as_a.first if root.as_a? && !root.as_a.empty?

        candidates = root["candidates"]?
        raise "Error: No candidates returned" unless candidates && candidates.as_a? && !candidates.as_a.empty?

        content_parts = candidates[0]["content"]?.try(&.["parts"]?)
        text_content = ""
        tool_calls = [] of ToolCall

        if content_parts.try(&.as_a?)
          content_parts.not_nil!.as_a.each do |part|
            text_content += part["text"].as_s if part["text"]?
            
            if func = part["functionCall"]?
               name = func["name"].as_s
               args = func["args"].as_h
               args_hash = {} of String => JSON::Any
               args.each { |k, v| args_hash[k] = v }
               tool_calls << ToolCall.new("call_#{UUID.random}", name, args_hash)
            end
          end
        end

        Response.new(content: text_content, tool_calls: tool_calls.empty? ? nil : tool_calls)
      end
    end
  end
end
