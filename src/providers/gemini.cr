require "http"
require "json"
require "process"
require "random/secure"
require "./base"
require "../auth/token_store"

module Crybot
  module Providers
    class GeminiProvider < LLMProvider
      def initialize(@project_id : String, @location : String, @auth_command : String, @default_model : String)
      end

      def chat(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Response
        # Retry loop for rate limits (429)
        max_retries = 3
        retry_count = 0
        
        loop do
          begin
            return attempt_chat(messages, tools, model)
          rescue e : Exception
            if e.message && e.message.not_nil!.includes?("429")
              retry_count += 1
              if retry_count >= max_retries
                raise e # Give up after max retries
              end
              
              puts "Rate limited (429). Switching account (attempt #{retry_count}/#{max_retries})..."
              # The attempt_chat method records failure on 429, so next call gets a new token
              sleep 1.seconds
            else
              raise e # Re-raise other errors
            end
          end
        end
      end

      private def attempt_chat(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Response
        token, auth_project_id, email = Auth::TokenStore.get_valid_token("gemini")
        
        # Use project_id from auth if not explicitly configured (or if we want to support dynamic projects)
        # But keeping @project_id as fallback or primary if set might be better.
        # For now, let's use the authenticated project_id if available, as that's what the reference does.
        actual_project_id = auth_project_id.empty? ? @project_id : auth_project_id
        
        actual_model = model || @default_model
        
        # Determine if we should use the streamGenerateContent or generateContent endpoint
        # For now, we'll use generateContent (non-streaming) as the base implementation
        url = "https://#{@location}-aiplatform.googleapis.com/v1/projects/#{actual_project_id}/locations/#{@location}/publishers/google/models/#{actual_model}:generateContent"

        body = build_request_body(messages, tools)

        headers = HTTP::Headers{
          "Content-Type"        => "application/json",
          "Authorization"       => "Bearer #{token}",
          "X-Goog-User-Project" => actual_project_id,
        }

        response = HTTP::Client.post(url, headers, body.to_json)

        unless response.success?
          if response.status_code == 429
             Auth::TokenStore.record_failure(email)
          end
          raise "Gemini API request failed: #{response.status_code} - #{response.body}"
        end

        parse_response(response.body)
      end

      private def build_request_body(messages : Array(Message), tools : Array(ToolDef)?) : Hash(String, JSON::Any)
        contents = [] of Hash(String, JSON::Any)
        system_instruction = nil

        messages.each do |msg|
          case msg.role
          when "system"
            system_instruction = build_system_instruction(msg)
          when "tool"
            contents << build_tool_response(msg)
          when "user"
            contents << build_user_message(msg)
          when "assistant"
            contents << build_assistant_message(msg)
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
          # Convert hash to JSON::Any structure
          parts_any = system_instruction["parts"].map { |part| JSON::Any.new(part.transform_values { |v| JSON::Any.new(v) }) }
          body["systemInstruction"] = JSON::Any.new({
            "parts" => JSON::Any.new(parts_any),
          })
        end

        add_tools_to_body(body, tools)
        body
      end

      private def build_system_instruction(msg : Message)
        {
          "parts" => [
            {"text" => msg.content || ""},
          ],
        }
      end

      private def build_tool_response(msg : Message)
        parts = [] of Hash(String, JSON::Any)
        response_content = msg.content || ""

        response_hash = parse_tool_content(response_content)

        parts << {
          "functionResponse" => JSON::Any.new({
            "name"     => JSON::Any.new(msg.name || ""),
            "response" => JSON::Any.new(response_hash),
          }),
        }

        {
          "role"  => JSON::Any.new("function"),
          "parts" => JSON::Any.new(parts.map { |part| JSON::Any.new(part) }),
        }
      end

      private def parse_tool_content(content : String) : Hash(String, JSON::Any)
        json_content = JSON.parse(content)
        if hash_val = json_content.as_h?
          hash_val
        else
          {"result" => json_content}
        end
      rescue
        {"result" => JSON::Any.new(content)}
      end

      private def build_user_message(msg : Message)
        {
          "role"  => JSON::Any.new("user"),
          "parts" => JSON::Any.new([
            JSON::Any.new({"text" => JSON::Any.new(msg.content || "")}),
          ]),
        }
      end

      private def build_assistant_message(msg : Message)
        parts = [] of Hash(String, JSON::Any)

        if content = msg.content
          parts << {"text" => JSON::Any.new(content)}
        end

        if msg.tool_calls
          msg.tool_calls.try do |calls|
            calls.each do |call|
              parts << {
                "functionCall" => JSON::Any.new({
                  "name" => JSON::Any.new(call.name),
                  "args" => JSON::Any.new(call.arguments.transform_values { |v| v }),
                }),
              }
            end
          end
        end

        {
          "role"  => JSON::Any.new("model"),
          "parts" => JSON::Any.new(parts.map { |part| JSON::Any.new(part) }),
        }
      end

      private def add_tools_to_body(body : Hash(String, JSON::Any), tools : Array(ToolDef)?)
        return if tools.nil? || tools.empty?

        tool_declarations = tools.map do |tool|
          {
            "name"        => JSON::Any.new(tool.name),
            "description" => JSON::Any.new(tool.description),
            "parameters"  => JSON::Any.new(tool.parameters),
          }
        end

        body["tools"] = JSON::Any.new([
          JSON::Any.new({
            "functionDeclarations" => JSON::Any.new(tool_declarations.map { |decl| JSON::Any.new(decl) }),
          }),
        ])
      end

      private def parse_response(body : String) : Response
        json = JSON.parse(body)

        candidates = json["candidates"]?
        if candidates.nil? || !candidates.as_a? || candidates.as_a.empty?
          return Response.new(content: "Error: No candidates returned")
        end

        candidate = candidates[0]
        text_content, tool_calls = parse_content(candidate)

        finish_reason = candidate["finishReason"]?.try(&.as_s)
        usage = parse_usage(json)

        Response.new(
          content: text_content.empty? ? nil : text_content,
          tool_calls: tool_calls.empty? ? nil : tool_calls,
          usage: usage,
          finish_reason: finish_reason
        )
      end

      private def parse_content(candidate : JSON::Any) : Tuple(String, Array(ToolCall))
        text_content = ""
        tool_calls = [] of ToolCall

        content_parts = candidate["content"]? ? candidate["content"]["parts"]? : nil

        if content_parts && content_parts.as_a?
          content_parts.as_a.each do |part|
            if text = part["text"]?
              text_content += text.as_s
            elsif part["functionCall"]?
              if call = parse_function_call(part["functionCall"])
                tool_calls << call
              end
            end
          end
        end

        {text_content, tool_calls}
      end

      private def parse_function_call(fc : JSON::Any) : ToolCall?
        name = fc["name"].as_s
        args = fc["args"].as_h

        # Convert args to Hash(String, JSON::Any)
        args_hash = {} of String => JSON::Any
        args.each { |k, v| args_hash[k] = v }

        # Generate a random ID since Gemini doesn't provide one
        id = "call_#{Random::Secure.hex(4)}"

        ToolCall.new(id, name, args_hash)
      rescue
        nil
      end

      private def parse_usage(json : JSON::Any) : Usage?
        if usage_meta = json["usageMetadata"]?
          Usage.new(
            prompt_tokens: usage_meta["promptTokenCount"].as_i,
            completion_tokens: usage_meta["candidatesTokenCount"].as_i,
            total_tokens: usage_meta["totalTokenCount"].as_i
          )
        end
      rescue
        nil
      end
    end
  end
end
