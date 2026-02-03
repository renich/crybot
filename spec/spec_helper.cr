require "spec"
require "../src/config/loader"

# Mock config for testing
module Crybot::Config
  class Loader
    def self.config_dir : Path
      Path.new("/tmp/crybot_test")
    end
  end
end

# Ensure test directory exists
FileUtils.mkdir_p("/tmp/crybot_test")
