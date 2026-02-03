require "http/server"
require "http/client"
require "json"
require "openssl"
require "base64"
require "uri"
require "random/secure"
require "./token_store"

module Crybot
  module Auth
    module OAuth
      CLIENT_ID     = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
      CLIENT_SECRET = "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"
      REDIRECT_URI  = "http://localhost:51121/oauth-callback"

      SCOPES = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
      ]

      ANTIGRAVITY_HEADERS = {
        "User-Agent"        => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Antigravity/1.15.8 Chrome/138.0.7204.235 Electron/37.3.1 Safari/537.36",
        "X-Goog-Api-Client" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
        "Client-Metadata"   => "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}",
      }

      def self.login
        verifier = generate_verifier
        challenge = generate_challenge(verifier)
        state = Base64.urlsafe_encode(verifier)

        params = URI::Params.encode({
          "client_id"             => CLIENT_ID,
          "response_type"         => "code",
          "redirect_uri"          => REDIRECT_URI,
          "scope"                 => SCOPES.join(" "),
          "code_challenge"        => challenge,
          "code_challenge_method" => "S256",
          "state"                 => state,
          "access_type"           => "offline",
          "prompt"                => "consent",
        })

        auth_url = "https://accounts.google.com/o/oauth2/v2/auth?#{params}"

        puts "\nOpen this URL in your browser to login:"
        puts auth_url
        puts "\nWaiting for authentication..."

        # Open browser (Linux specific, maybe add checks for Mac/Windows later)
        if system("which xdg-open > /dev/null")
          Process.run("xdg-open", [auth_url])
        end

        start_server
      end

      def self.refresh_token(refresh_token : String) : Tuple(String, Int32)
        params = URI::Params.encode({
          "client_id"     => CLIENT_ID,
          "client_secret" => CLIENT_SECRET,
          "refresh_token" => refresh_token,
          "grant_type"    => "refresh_token",
        })

        response = HTTP::Client.post(
          "https://oauth2.googleapis.com/token",
          headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
          body: params
        )

        unless response.success?
          raise "Failed to refresh token: #{response.body}"
        end

        json = JSON.parse(response.body)
        access_token = json["access_token"].as_s
        expires_in = json["expires_in"].as_i

        {access_token, expires_in}
      end

      def self.start_server
        server = HTTP::Server.new do |context|
          req = context.request
          res = context.response

          if req.path == "/oauth-callback"
            code = req.query_params["code"]?
            state = req.query_params["state"]?

            if code && state
              begin
                handle_callback(code, state)
                res.content_type = "text/html"
                res.print "<h1>Login Successful!</h1><p>You can close this window and return to the terminal.</p>"
                spawn { sleep 1.seconds; exit 0 } # Exit successfully after a moment
              rescue e
                res.status_code = 500
                res.print "Error: #{e.message}"
                puts "Error during callback handling: #{e.message}"
                spawn { sleep 1.seconds; exit 1 }
              end
            else
              res.status_code = 400
              res.print "Missing code or state"
            end
          else
            res.status_code = 404
          end
        end

        server.bind_tcp "localhost", 51121
        server.listen
      end

      def self.handle_callback(code : String, state : String)
        verifier = String.new(Base64.decode(state.tr("-_", "+/")))

        # Exchange code for token
        params = URI::Params.encode({
          "client_id"     => CLIENT_ID,
          "client_secret" => CLIENT_SECRET,
          "code"          => code,
          "grant_type"    => "authorization_code",
          "redirect_uri"  => REDIRECT_URI,
          "code_verifier" => verifier,
        })

        response = HTTP::Client.post(
          "https://oauth2.googleapis.com/token",
          headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
          body: params
        )

        unless response.success?
          raise "Token exchange failed: #{response.body}"
        end

        json = JSON.parse(response.body)
        access_token = json["access_token"].as_s
        refresh_token = json["refresh_token"].as_s
        expires_in = json["expires_in"].as_i

        # Fetch user info
        user_info = fetch_user_info(access_token)
        email = user_info["email"].as_s

        # Fetch project ID
        project_id = fetch_project_id(access_token)

        account = Account.new(
          email: email,
          refresh_token: refresh_token,
          project_id: project_id,
          access_token: access_token,
          expires_at: Time.utc.to_unix + expires_in
        )

        TokenStore.add_account(account)
        puts "\nSuccessfully logged in as #{email} (Project: #{project_id})"
      end

      def self.fetch_user_info(access_token : String) : JSON::Any
        response = HTTP::Client.get(
          "https://www.googleapis.com/oauth2/v1/userinfo?alt=json",
          headers: HTTP::Headers{"Authorization" => "Bearer #{access_token}"}
        )

        unless response.success?
          raise "Failed to fetch user info"
        end

        JSON.parse(response.body)
      end

      def self.fetch_project_id(access_token : String) : String
        # Try fallbacks like the reference implementation
        endpoints = [
          "https://cloudcode-pa.googleapis.com",
          "https://daily-cloudcode-pa.sandbox.googleapis.com",
          "https://autopush-cloudcode-pa.sandbox.googleapis.com",
        ]

        headers = HTTP::Headers{
          "Authorization"     => "Bearer #{access_token}",
          "Content-Type"      => "application/json",
          "User-Agent"        => ANTIGRAVITY_HEADERS["User-Agent"],
          "X-Goog-Api-Client" => ANTIGRAVITY_HEADERS["X-Goog-Api-Client"],
          "Client-Metadata"   => ANTIGRAVITY_HEADERS["Client-Metadata"],
        }

        endpoints.each do |base_url|
          begin
            response = HTTP::Client.post(
              "#{base_url}/v1internal:loadCodeAssist",
              headers: headers,
              body: {
                "metadata" => {
                  "ideType"    => "IDE_UNSPECIFIED",
                  "platform"   => "PLATFORM_UNSPECIFIED",
                  "pluginType" => "GEMINI",
                },
              }.to_json
            )

            if response.success?
              json = JSON.parse(response.body)
              if proj = json["cloudaicompanionProject"]?
                if proj_str = proj.as_s?
                  return proj_str
                elsif proj_id = proj["id"]?
                  return proj_id.as_s
                end
              end
            end
          rescue
            next
          end
        end

        "rising-fact-p41fc" # Default fallback
      end

      def self.generate_verifier : String
        Random::Secure.urlsafe_base64(32)
      end

      def self.generate_challenge(verifier : String) : String
        digest = OpenSSL::Digest.new("SHA256")
        digest.update(verifier)
        Base64.urlsafe_encode(digest.final)
      end
    end
  end
end
