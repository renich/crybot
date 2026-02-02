require "file_utils"
require "time"
require "../config/loader"

module Crybot
  module Agent
    class MemoryManager
      @memory_dir : Path
      @daily_log_dir : Path
      @current_log_file : Path
      @last_log_date : Time

      def initialize(workspace_dir : Path)
        @memory_dir = workspace_dir / "memory"
        @daily_log_dir = @memory_dir / "logs"
        @current_log_file = @daily_log_dir / "current.md"
        @last_log_date = Time.local.to_utc

        ensure_directories
      end

      # Read the main MEMORY.md file
      def read : String
        memory_file = @memory_dir / "MEMORY.md"

        return "" unless File.exists?(memory_file)

        File.read(memory_file)
      end

      # Write to the main MEMORY.md file
      def write(content : String) : Nil
        File.write(@memory_dir / "MEMORY.md", content)
      end

      # Append to the current day's log
      def append_to_daily_log(content : String) : Nil
        current_date = Time.local.to_utc

        # Check if we need to rotate to a new day
        if current_date > @last_log_date
          rotate_log(current_date)
        end

        # Append to current day's log
        File.open(@current_log_file, "a") do |file|
          timestamp = Time.local.to_s("%Y-%m-%d %H:%M:%S")
          file.puts "\n---\n\n[#{timestamp}] #{content}"
        end

        @last_log_date = current_date
      end

      # Read entries from a specific day's log
      def read_daily_log(date : Time) : Array(String)
        log_file = @daily_log_dir / "#{date.to_s("%Y-%m-%d")}.md"

        return [] of String unless File.exists?(log_file)

        content = File.read(log_file)
        content.split("---\n\n").reject(&.empty?)
      end

      # Read all log files and return entries
      def read_all_logs : Array(String)
        return [] of String unless Dir.exists?(@daily_log_dir)

        entries = [] of String

        Dir.children(@daily_log_dir).each do |filename|
          next unless filename.ends_with?(".md") && filename != "current.md"

          log_file = @daily_log_dir / filename
          content = File.read(log_file)
          entries.concat(content.split("---\n\n").reject(&.empty?))
        end

        entries
      end

      # Search memory using simple keyword matching
      def search(query : String) : Array(String)
        # Search in MEMORY.md
        memory_content = read
        memory_entries = memory_content.split("---\n\n").reject(&.empty?)

        # Search in daily logs
        log_entries = read_all_logs

        all_entries = memory_entries + log_entries
        results = [] of String

        query_lower = query.downcase

        all_entries.each do |entry|
          if entry.downcase.includes?(query_lower)
            results << entry
          end
        end

        results
      end

      # Get recent entries (last N days)
      def get_recent(days : Int32) : Array(String)
        cutoff_date = Time.local.to_utc - days.days
        entries = read_all_logs

        entries.select do |entry|
          # Extract timestamp from entry
          if entry.match(/^\[(.*?)\]/)
            timestamp_str = $1
            if timestamp = Time.parse(timestamp_str, "%Y-%m-%d %H:%M:%S", Time::Location::UTC)
              timestamp > cutoff_date
            else
              true # If can't parse, include it
            end
          else
            true
          end
        end
      end

      # Get memory statistics
      def stats : Hash(String, Int32)
        memory_file = @memory_dir / "MEMORY.md"
        memory_size = (File.exists?(memory_file) ? File.size(memory_file) : 0).to_i32

        log_count = 0
        log_size = 0_i64

        if Dir.exists?(@daily_log_dir)
          Dir.children(@daily_log_dir).each do |filename|
            next unless filename.ends_with?(".md") && filename != "current.md"
            log_file = @daily_log_dir / filename
            log_size += File.size(log_file)
            log_count += 1
          end
        end

        {
          "memory_file_size" => memory_size,
          "log_file_count"   => log_count,
          "log_total_size"   => log_size.to_i32,
        }
      end

      # Compact memory (move old logs to archive)
      def compact(keep_days : Int32 = 30) : Nil
        cutoff_date = Time.local.to_utc - keep_days.days

        Dir.children(@daily_log_dir).each do |filename|
          next unless filename.ends_with?(".md") && filename != "current.md"

          # Parse date from filename (YYYY-MM-DD.md)
          if filename.match(/^(\d{4}-\d{2}-\d{2})\.md$/)
            date_str = $1
            if date = Time.parse(date_str, "%Y-%m-%d", Time::Location::UTC)
              if date < cutoff_date
                # Move to archive
                archive_dir = @memory_dir / "archive"
                Dir.mkdir_p(archive_dir)

                old_file = @daily_log_dir / filename
                new_file = archive_dir / filename

                FileUtils.mv(old_file, new_file)
              end
            end
          end
        end
      end

      # Clear memory
      def clear : Nil
        File.write(@memory_dir / "MEMORY.md", "")
        Dir.mkdir_p(@daily_log_dir)

        if File.exists?(@current_log_file)
          File.write(@current_log_file, "")
        end
      end

      private def ensure_directories : Nil
        Dir.mkdir_p(@memory_dir)
        Dir.mkdir_p(@daily_log_dir)
      end

      private def rotate_log(new_date : Time) : Nil
        # Close current log
        if File.exists?(@current_log_file)
          File.write(@current_log_file, "") # Clear it
        end

        # Create new day's log
        @current_log_file = @daily_log_dir / "#{new_date.to_s("%Y-%m-%d")}.md"

        File.write(@current_log_file, "# Memory Log - #{new_date.to_s("%Y-%m-%d")}\n\n")
        @last_log_date = new_date
      end
    end

    # Simple Memory class for backward compatibility
    class Memory
      def initialize(workspace_dir : Path)
        @manager = MemoryManager.new(workspace_dir)
      end

      def read : String
        @manager.read
      end

      def write(content : String) : Nil
        @manager.write(content)
      end

      def append_to_daily_log(content : String) : Nil
        @manager.append_to_daily_log(content)
      end
    end
  end
end
