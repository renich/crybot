require "./openai_base"
require "../auth/token_store"

module Crybot
  module Providers
    # Antigravity provider (OpenAI-compatible)
    class AntigravityProvider < OpenAICompatible
      DEFAULT_MODEL = "antigravity-gemini-3-pro"

      def initialize(api_key : String, api_base : String, default_model : String = DEFAULT_MODEL)
        super(api_key, default_model, api_base)
      end

      private def build_headers : HTTP::Headers
        token, project_id = Auth::TokenStore.get_valid_token("antigravity")

        headers = HTTP::Headers{
          "Content-Type"        => "application/json",
          "Authorization"       => "Bearer #{token}",
          "X-Goog-User-Project" => project_id,
          "User-Agent"          => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Antigravity/1.15.8 Chrome/138.0.7204.235 Electron/37.3.1 Safari/537.36",
          "X-Goog-Api-Client"   => "google-cloud-sdk vscode_cloudshelleditor/0.1",
          "Client-Metadata"     => "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}",
        }
        headers
      end

      # Antigravity requires SNI. The "unrecognized name" error suggests the server (gateway)
      # is strict about SNI matching the host.
      # Crystal's HTTP::Client should handle this, but let's be explicit about the endpoint
      # by ensuring we are hitting the correct hostname.
      # The default config has https://api.antigravity.ai/v1.
      #
      # WAIT - Looking at the error "SSL_connect: error:0A000458:SSL routines::tlsv1 unrecognized name"
      # This usually happens when connecting to an IP address with HTTPS, or when the server
      # requires SNI and the client isn't sending it correctly for the specific host.
      #
      # Antigravity is actually a proxy. The URL "https://api.antigravity.ai/v1" might be correct,
      # but let's double check if we need to set the hostname in TLS context.
      #
      # Actually, the reference implementation uses "https://daily-cloudcode-pa.sandbox.googleapis.com".
      # The config in loader.cr was set to "https://api.antigravity.ai/v1" which might be wrong or a placeholder.
      #
      # Let's fix the default API base in the code to match the reference implementation
      # if the user hasn't changed it.
      #
      # Reference:
      # export const ANTIGRAVITY_ENDPOINT_DAILY = "https://daily-cloudcode-pa.sandbox.googleapis.com";
      #
      # If the config has the placeholder "https://api.antigravity.ai/v1", we should probably use the real one.
      #
      # Let's override endpoint_url to handle this.

      private def endpoint_url : String
        base = @api_base
        # Fix placeholder if present
        if base == "https://api.antigravity.ai/v1"
          base = "https://daily-cloudcode-pa.sandbox.googleapis.com"
        end
        # The 404 indicates /v1/chat/completions is wrong for this Google endpoint.
        # Antigravity via Google Cloud Code likely uses a different path.
        # Looking at reference implementation (CLIProxyAPI), it proxies requests.
        # But if we are hitting Google directly, we need the correct path.
        #
        # Reference implementation uses:
        # `${baseEndpoint}/v1internal:loadCodeAssist` for project ID
        # But for chat?
        #
        # It seems `opencode-antigravity-auth` actually proxies the request to `https://api.antigravity.ai/v1/chat/completions` which is THEIR proxy.
        # BUT we are trying to hit Google directly to avoid relying on a 3rd party proxy if possible, OR we misunderstood the architecture.
        #
        # Wait, the reference implementation `opencode-antigravity-auth` is a plugin for OpenCode that connects to `https://api.antigravity.ai` which acts as a gateway?
        # NO, the reference code imports `ANTIGRAVITY_ENDPOINT_DAILY = "https://daily-cloudcode-pa.sandbox.googleapis.com"`.
        #
        # Let's check how it constructs the chat URL.
        # It seems it might be using the Vertex AI path if it's acting as a Gemini client?
        #
        # Actually, `opencode-antigravity-auth` seems to be an *auth* plugin that allows OpenCode (which speaks OpenAI protocol) to talk to... what?
        #
        # If we look at the error `The requested URL /v1/chat/completions was not found on this server`, it confirms we are hitting Google (the 404 page is Google's), but the path is wrong.
        #
        # Google's Cloud Code API usually uses paths like `/v1/projects/{project}/locations/{location}/...`
        # OR it might be `/v1internal/companions/...`
        #
        # Let's try to find the correct endpoint from the reference code we read earlier.
        # The reference had `fetchProjectID` hitting `${baseEndpoint}/v1internal:loadCodeAssist`.
        #
        # If we can't find the exact OpenAI-compatible endpoint on Google's side (it might not exist natively!),
        # then Antigravity might NOT be OpenAI compatible directly.
        #
        # However, the user said "Antigravity is OpenAI compatible at a specific URL".
        # If `daily-cloudcode-pa.sandbox.googleapis.com` is the base, maybe the path is different.
        #
        # Let's try `/v1/publishers/google/models/{model}:predict` or similar? No, that's Vertex.
        #
        # Re-reading the user's prompt: "Antigravity is OpenAI compatible at a specific URL. I know OpenClaw supports it."
        #
        # If the user meant the *service* provided by `opencode-antigravity-auth` (which runs locally?), that would explain it.
        # But we are implementing the client *inside* Crybot.
        #
        # If `daily-cloudcode-pa.sandbox.googleapis.com` is indeed the target, it is likely NOT OpenAI compatible.
        #
        # BUT, `src/providers/gemini.cr` implements the native Google protocol.
        # Antigravity might just be a wrapped Gemini?
        #
        # Let's assume for a moment the user wants us to hit the Google endpoint `https://daily-cloudcode-pa.sandbox.googleapis.com`
        # AND use the OpenAI format. This implies there IS an OpenAI bridge there, or we are wrong about the path.
        #
        # Another possibility: The correct URL is actually `https://ide-pa.googleapis.com` or similar?
        #
        # Let's try the internal endpoint often used by these tools:
        # `/v1internal/companions/generateChat` ?
        #
        # Let's look at `gemini-cli` code or similar if we can.
        #
        # For now, let's try to revert to the user's initial hint or the reference repo's behavior more closely.
        # The reference repo *doesn't* seem to have a `chat/completions` endpoint in its *client* code.
        # It handles auth.
        #
        # Wait, `opencode-antigravity-auth` *provides* the auth to OpenCode. OpenCode then calls *someone*.
        # Does OpenCode call the plugin? Or does the plugin tell OpenCode "here is the URL"?
        #
        # If we look at the reference again (I can't read it now, it's pruned), it had `ANTIGRAVITY_ENDPOINT_DAILY`.
        #
        # Let's try to assume the user wants us to use the `GeminiProvider` logic but with the Antigravity endpoint and auth?
        #
        # The user said: "Antigravity is OpenAI compatible at a specific URL."
        #
        # If `https://daily-cloudcode-pa.sandbox.googleapis.com` returns 404 for `/v1/chat/completions`, then THAT specific URL is not OpenAI compatible at THAT path.
        #
        # Maybe the base URL should include `/v1`?
        # `https://daily-cloudcode-pa.sandbox.googleapis.com/v1/chat/completions` -> 404.
        #
        # Let's try to use the *Gemini* provider logic for Antigravity, effectively treating it as a "Custom Gemini" endpoint?
        #
        # Modify `AntigravityProvider` to inherit from `GeminiProvider` instead?
        #
        # OR, maybe the URL is `https://clients2.google.com/service/update2/...?` No.
        #
        # Let's search online for "Antigravity API OpenAI compatible".
        #
        # Found nothing obvious.
        #
        # Let's try to use `GeminiProvider` logic but with the `daily-cloudcode-pa` endpoint.
        # Google's internal APIs usually speak Protobuf/JSON that looks like Gemini/Vertex.
        #
        # Let's change `AntigravityProvider` to NOT be `OpenAICompatible`, but rather adapt the Gemini logic.
        # But the user *specifically asked* to make it `OpenAICompatible`.
        #
        # "To implement these providers, I need some details: 1. Antigravity: Is this OpenAI-compatible? ... User: Antigravity is OpenAI compatible at a specific URL."
        #
        # Maybe the URL is NOT `daily-cloudcode-pa.sandbox.googleapis.com`.
        # Maybe it IS `https://api.antigravity.ai/v1` and I shouldn't have changed it?
        # But `https://api.antigravity.ai` gave SSL error (unrecognized name).
        # This implies `api.antigravity.ai` might not have a valid cert or is behind Cloudflare requiring SNI which we sent...
        #
        # Wait, if `api.antigravity.ai` is a proxy maintained by the community (e.g. OpenClaw devs), it might work.
        # The SSL error `unrecognized name` usually means the server *requires* SNI and we didn't send it, OR we sent it and the server doesn't know that name.
        #
        # Let's try to revert the URL to `https://api.antigravity.ai/v1` AND fix the SNI issue.
        # The SNI issue might be because `HTTP::Client` creates a default context.
        #
        # But first, let's verify if `daily-cloudcode-pa.sandbox.googleapis.com` supports OpenAI.
        # Since it returns a Google 404 for `/v1/chat/completions`, it likely DOES NOT.
        #
        # So `api.antigravity.ai` must be a bridge.
        #
        # Let's revert the URL change and try to fix the connection.
        #
        base = @api_base
        "#{base}/chat/completions"
      end
    end
  end
end
