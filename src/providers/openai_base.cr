require "http"
require "json"
require "./base"

module Crybot
  module Providers
    # Base class for OpenAI-compatible API providers
    # All providers using the OpenAI chat completions format can inherit from this
    abstract class OpenAICompatible < LLMProvider
      @api_key : String
      @default_model : String
      @api_base : String

      def initialize(@api_key : String, @default_model : String, @api_base : String)
      end

      def chat(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Response
        request_body = build_request_body(messages, tools, model)

        headers = build_headers

        response = HTTP::Client.post(endpoint_url, headers, request_body.to_json, tls: create_tls_context)

        unless response.success?
          raise "API request failed: #{response.status_code} - #{response.body}"
        end

        parse_response(response.body)
      end

      private def create_tls_context
        # Use default context but ensure SNI is handled correctly if possible.
        # Crystal's OpenSSL bindings should handle this.
        # If we need to force it, we can create a context.
        # For now, returning nil lets HTTP::Client create the default one.
        nil
      end

      private def endpoint_url : String
        "#{@api_base}/chat/completions"
      end

      private def build_headers : HTTP::Headers
        HTTP::Headers{
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{@api_key}",
        }
      end

      private def build_request_body(messages : Array(Message), tools : Array(ToolDef)?, model : String?) : Hash(String, JSON::Any)
        body = {
          "model"    => JSON::Any.new(model || @default_model),
          "messages" => JSON::Any.new(messages.map(&.to_h).map { |hash| JSON::Any.new(hash) }),
        }

        # Add tools if present
        unless tools.nil? || tools.empty?
          body["tools"] = JSON::Any.new(tools.map(&.to_h).map { |hash| JSON::Any.new(hash) })
        end

        body
      end

      private def parse_response(body : String) : Response
        json = JSON.parse(body)

        content = nil
        tool_calls = nil
        usage = nil
        finish_reason = nil

        choices_value = json["choices"]?
        if choices_value && choices_value.as_a?
          choice = choices_value.as_a[0]
          msg_value = choice["message"]?
          if msg_value
            msg = msg_value
            content_value = msg["content"]?
            content = content_value.as_s if content_value

            tool_calls_value = msg["tool_calls"]?
            if tool_calls_value && tool_calls_value.as_a?
              tool_calls = parse_tool_calls(tool_calls_value)
            end
          end

          finish_reason_value = choice["finish_reason"]?
          finish_reason = finish_reason_value.as_s if finish_reason_value
        end

        usage_value = json["usage"]?
        if usage_value
          usage_data = usage_value
          usage = Usage.new(
            prompt_tokens: usage_data["prompt_tokens"].as_i.to_i32,
            completion_tokens: usage_data["completion_tokens"].as_i.to_i32,
            total_tokens: usage_data["total_tokens"].as_i.to_i32,
          )
        end

        Response.new(content: content, tool_calls: tool_calls, usage: usage, finish_reason: finish_reason)
      end

      private def parse_tool_calls(calls : JSON::Any) : Array(ToolCall)
        result = [] of ToolCall

        calls.as_a.each do |call|
          id = call["id"].as_s
          func = call["function"]
          name = func["name"].as_s
          arguments_str = func["arguments"].as_s
          arguments = JSON.parse(arguments_str).as_h

          # Convert JSON::Any to proper Hash(String, JSON::Any)
          args_hash = {} of String => JSON::Any
          arguments.each do |k, v|
            args_hash[k] = v
          end

          result << ToolCall.new(
            id: id,
            name: name,
            arguments: args_hash,
          )
        end

        result
      end
    end
  end
end
