require "json"
require "http"

module Crybot
  module MCP
    # MCP JSON-RPC 2.0 Client
    # Implements the Model Context Protocol for connecting to external tools/resources
    class Client
      @request_id : Int64 = 0_i64
      @server_name : String
      @command : String?
      @url : String?
      @process : Process?
      @running : Bool = false

      def initialize(@server_name : String, @command : String? = nil, @url : String? = nil)
        raise "Either command or url must be provided" if @command.nil? && @url.nil?
      end

      def start : Nil
        if @command
          # Start stdio-based MCP server
          start_stdio_server
        else
          # HTTP-based MCP server (not yet implemented)
          raise "HTTP MCP servers not yet supported"
        end
        @running = true

        # Initialize MCP connection
        initialize_mcp
      end

      def stop : Nil
        @running = false
        return unless process = @process
        process.terminate
        @process = nil
      end

      def list_tools : Array(Tool)
        send_request("tools/list") do |response|
          tools = response.dig?("result", "tools")
          if tools && tools.as_a?
            tools.as_a.map { |tool_json| Tool.from_json(tool_json.to_json) }
          else
            [] of Tool
          end
        end
      end

      def call_tool(name : String, arguments : Hash(String, JSON::Any)) : ToolCallResult
        send_request("tools/call", {
          "name"      => name,
          "arguments" => arguments,
        }) do |response|
          ToolCallResult.from_json(response.dig?("result").to_json)
        end
      end

      def list_resources : Array(Resource)
        send_request("resources/list") do |response|
          resources = response.dig?("result", "resources")
          if resources && resources.as_a?
            resources.as_a.map { |resource_json| Resource.from_json(resource_json.to_json) }
          else
            [] of Resource
          end
        end
      end

      def read_resource(uri : String) : ResourceContents
        send_request("resources/read", {
          "uri" => uri,
        }) do |response|
          ResourceContents.from_json(response.dig?("result").to_json)
        end
      end

      private def start_stdio_server : Nil
        command = @command
        return unless command

        parts = command.split(' ')
        exec_cmd = parts.first
        args = parts[1..]

        @process = Process.new(exec_cmd, args,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe
        )

        # Give the server a moment to start
        sleep 0.5.seconds
      end

      private def initialize_mcp : Nil
        send_request("initialize", {
          "protocolVersion" => "2025-11-25",
          "capabilities"    => {
            "tools"     => true,
            "resources" => true,
          },
          "clientInfo" => {
            "name"    => "crybot",
            "version" => "0.1.0",
          },
        }) do |_|
          # Send initialized notification
          send_notification("initialized")
        end
      end

      private def send_request(method : String, params = nil, & : JSON::Any -> _)
        @request_id += 1
        request = build_request(@request_id, method, params)

        response = send_and_receive(request)

        if error = response["error"]?
          raise "MCP Error (#{method}): #{error}"
        end

        yield response
      end

      private def send_notification(method : String, params = nil) : Nil
        request = {
          "jsonrpc" => "2.0",
          "method"  => method,
          "params"  => params,
        }.to_json

        send_to_server(request)
      end

      private def build_request(id : Int64, method : String, params) : String
        {
          "jsonrpc" => "2.0",
          "id"      => id,
          "method"  => method,
          "params"  => params,
        }.to_json
      end

      private def send_and_receive(request : String) : JSON::Any
        send_to_server(request)
        receive_from_server
      end

      private def send_to_server(data : String) : Nil
        if process = @process
          # Send with Content-Length header for stdio transport
          message = "Content-Length: #{data.bytesize}\r\n\r\n#{data}"
          process.input << message
          process.input.flush
        else
          raise "MCP server process not running"
        end
      end

      private def receive_from_server : JSON::Any
        if process = @process
          # Read Content-Length header
          header_line = process.output.gets
          unless header_line && header_line.starts_with?("Content-Length:")
            raise "Invalid MCP response: missing Content-Length"
          end

          length = header_line.split(':')[1].strip.to_i

          # Skip blank line
          process.output.gets

          # Read JSON response
          buffer = Bytes.new(length)
          process.output.read_fully(buffer)

          JSON.parse(String.new(buffer))
        else
          raise "MCP server process not running"
        end
      end

      # MCP Schema Types

      struct Tool
        include JSON::Serializable

        property name : String
        property description : String?
        property input_schema : Hash(String, JSON::Any)

        def to_crybot_tool : Tools::Base::ToolSchema
          Tools::Base::ToolSchema.new(
            name: name,
            description: description || "",
            parameters: input_schema
          )
        end
      end

      struct ToolCallResult
        include JSON::Serializable

        property content : Array(ContentItem)
        property is_error : Bool?

        def to_response_string : String
          content.map(&.to_s).join("\n")
        end
      end

      struct ContentItem
        include JSON::Serializable

        property type : String
        property text : String?
        property data : String?
        property mime_type : String?

        def to_s : String
          case type
          when "text" then text || ""
          when "resource"
            "[Resource: #{data || "unknown"}]"
          else
            "[#{type}]"
          end
        end
      end

      struct Resource
        include JSON::Serializable

        property uri : String
        property name : String
        property description : String?
        property mime_type : String?
      end

      struct ResourceContents
        include JSON::Serializable

        property contents : Array(ResourceContent)

        def to_response_string : String
          contents.map(&.to_s).join("\n")
        end
      end

      struct ResourceContent
        include JSON::Serializable

        property uri : String
        property mime_type : String?
        property text : String?

        def to_s : String
          text || "[Binary content: #{mime_type || "unknown"}]"
        end
      end
    end
  end
end
