require "../auth/oauth"

module Crybot
  module Commands
    class Login
      def self.execute : Nil
        Config::Loader.ensure_directories
        Auth::OAuth.login
      end
    end
  end
end
