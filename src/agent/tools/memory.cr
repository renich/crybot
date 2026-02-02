require "../memory"
require "./base"

module Crybot
  module Agent
    module Tools
      # Save important information to long-term memory
      class SaveMemoryTool < Tool
        def name : String
          "save_memory"
        end

        def description : String
          "Save important information to long-term memory (MEMORY.md). Use this for facts, preferences, or information worth remembering indefinitely."
        end

        def parameters : Hash(String, JSON::Any)
          {
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({
              "content" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("The content to save to long-term memory. Use clear, concise language."),
              }),
            }),
            "required" => JSON::Any.new([JSON::Any.new("content")]),
          }
        end

        def execute(args : Hash(String, JSON::Any)) : String
          content = args["content"].as_s

          workspace_dir = Config::Loader.workspace_dir
          memory_manager = MemoryManager.new(workspace_dir)

          # Read existing memory
          existing = memory_manager.read

          # Append new memory with timestamp
          timestamp = Time.local.to_s("%Y-%m-%d %H:%M:%S")
          new_entry = "\n## #{timestamp}\n\n#{content}\n"

          memory_manager.write(existing + new_entry)

          "Saved to long-term memory."
        end
      end

      # Search memory by keyword
      class SearchMemoryTool < Tool
        def name : String
          "search_memory"
        end

        def description : String
          "Search long-term memory and daily logs for information matching a query. Returns relevant memory entries."
        end

        def parameters : Hash(String, JSON::Any)
          {
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({
              "query" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Search query - keywords to look for in memory"),
              }),
            }),
            "required" => JSON::Any.new([JSON::Any.new("query")]),
          }
        end

        def execute(args : Hash(String, JSON::Any)) : String
          query = args["query"].as_s

          workspace_dir = Config::Loader.workspace_dir
          memory_manager = MemoryManager.new(workspace_dir)

          results = memory_manager.search(query)

          if results.empty?
            "No memories found matching '#{query}'."
          else
            "Found #{results.size} memory entr#{results.size == 1 ? "y" : "ies"}:\n\n" + results.join("\n\n---\n\n")
          end
        end
      end

      # List recent memory entries
      class ListRecentMemoriesTool < Tool
        def name : String
          "list_recent_memories"
        end

        def description : String
          "List recent memory entries from daily logs. Useful for recalling recent conversations or activities."
        end

        def parameters : Hash(String, JSON::Any)
          {
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({
              "days" => JSON::Any.new({
                "type"        => JSON::Any.new("integer"),
                "description" => JSON::Any.new("Number of days to look back (default: 7)"),
                "default"     => JSON::Any.new(7),
              }),
            }),
            "required" => JSON::Any.new([] of JSON::Any),
          }
        end

        def execute(args : Hash(String, JSON::Any)) : String
          days = args["days"]?.try(&.as_i) || 7

          workspace_dir = Config::Loader.workspace_dir
          memory_manager = MemoryManager.new(workspace_dir)

          results = memory_manager.get_recent(days)

          if results.empty?
            "No recent memories found in the last #{days} day#{days == 1 ? "" : "s"}."
          else
            "Recent memories (last #{days} day#{days == 1 ? "" : "s"}):\n\n" + results.join("\n\n---\n\n")
          end
        end
      end

      # Record an event to daily log
      class RecordMemoryTool < Tool
        def name : String
          "record_memory"
        end

        def description : String
          "Record an event, action, or observation to the daily log. Use this for tracking what you've done or learned during this session."
        end

        def parameters : Hash(String, JSON::Any)
          {
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({
              "content" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("The content to record to the daily log"),
              }),
            }),
            "required" => JSON::Any.new([JSON::Any.new("content")]),
          }
        end

        def execute(args : Hash(String, JSON::Any)) : String
          content = args["content"].as_s

          workspace_dir = Config::Loader.workspace_dir
          memory_manager = MemoryManager.new(workspace_dir)

          memory_manager.append_to_daily_log(content)

          "Recorded to daily log."
        end
      end

      # Get memory statistics
      class MemoryStatsTool < Tool
        def name : String
          "memory_stats"
        end

        def description : String
          "Get statistics about memory usage (file sizes, log counts, etc.)"
        end

        def parameters : Hash(String, JSON::Any)
          {
            "type"       => JSON::Any.new("object"),
            "properties" => JSON::Any.new({} of String => JSON::Any),
          }
        end

        def execute(args : Hash(String, JSON::Any)) : String
          workspace_dir = Config::Loader.workspace_dir
          memory_manager = MemoryManager.new(workspace_dir)

          stats = memory_manager.stats

          <<-TEXT
          Memory Statistics:

          Main memory file: #{stats["memory_file_size"]} bytes
          Daily log files: #{stats["log_file_count"]}
          Total log size: #{stats["log_total_size"]} bytes
          TEXT
        end
      end
    end
  end
end
