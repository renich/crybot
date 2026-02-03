require "../auth/oauth"

module Crybot
  module Commands
    class Login
      def self.execute : Nil
        Auth::OAuth.login
      end
    end
  end
end
