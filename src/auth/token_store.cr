require "json"
require "file_utils"
require "../config/loader"

module Crybot
  module Auth
    struct Account
      include JSON::Serializable

      property email : String
      property refresh_token : String
      property project_id : String
      property access_token : String?
      property expires_at : Int64? # Unix timestamp
      property failure_count : Int32 = 0
      property last_failure : Int64?

      def initialize(@email, @refresh_token, @project_id, @access_token = nil, @expires_at = nil)
      end

      def expired?
        if expires = @expires_at
          Time.unix(expires) < Time.utc
        else
          true
        end
      end
    end

    class TokenStore
      ACCOUNTS_FILE = Config::Loader.config_dir / "accounts.json"

      @@accounts : Array(Account) = [] of Account
      @@loaded = false

      def self.load
        return if @@loaded
        if File.exists?(ACCOUNTS_FILE)
          begin
            json = File.read(ACCOUNTS_FILE)
            @@accounts = Array(Account).from_json(json)
          rescue e
            puts "Warning: Failed to load accounts file: #{e.message}"
            @@accounts = [] of Account
          end
        end
        @@loaded = true
      end

      def self.save
        dir = File.dirname(ACCOUNTS_FILE)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(ACCOUNTS_FILE, @@accounts.to_json)
      end

      def self.add_account(account : Account)
        load
        # Remove existing account with same email if exists
        @@accounts.reject! { |acc| acc.email == account.email }
        @@accounts << account
        save
      end

      def self.list : Array(Account)
        load
        @@accounts
      end

      def self.has_accounts? : Bool
        load
        !@@accounts.empty?
      end

      def self.record_failure(email : String?)
        return unless email
        load
        account = @@accounts.find { |a| a.email == email }
        return unless account

        account.failure_count += 1
        account.last_failure = Time.utc.to_unix
        save
      end

      def self.get_valid_token(provider_type : String = "google") : Tuple(String, String, String)
        load
        raise "No accounts authenticated. Run 'crybot auth login' first." if @@accounts.empty?

        # Simple strategy: Find first account that works (can be refreshed)
        # In future: implement load balancing logic here

        # Sort by failure count to try healthy accounts first
        sorted_accounts = @@accounts.sort_by(&.failure_count)

        sorted_accounts.each do |account|
          begin
            token = ensure_valid_token(account)
            return {token, account.project_id, account.email}
          rescue e
            # Log failure and try next
            account.failure_count += 1
            account.last_failure = Time.utc.to_unix
            save
            next
          end
        end

        raise "All accounts failed to refresh tokens."
      end

      private def self.ensure_valid_token(account : Account)
        if !account.expired?
          if token = account.access_token
            return token
          end
        end

        # Refresh token
        new_token, expires_in = OAuth.refresh_token(account.refresh_token)

        account.access_token = new_token
        account.expires_at = Time.utc.to_unix + expires_in - 60 # Buffer of 60s
        account.failure_count = 0                               # Reset failures on success
        save

        new_token
      end
    end
  end
end
