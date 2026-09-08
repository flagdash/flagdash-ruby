require "json"
require "net/http"
require "securerandom"
require "time"
require "uri"
require_relative "flagdash/version"
require_relative "flagdash/backend_replay"

module FlagDash
  Detail = Struct.new(:key, :value, :reason, :variation_key, keyword_init: true)

  class Client
    REGION_ENV = %w[FLAGDASH_REGION FLY_REGION AWS_REGION AWS_DEFAULT_REGION VERCEL_REGION GOOGLE_CLOUD_REGION RAILWAY_REPLICA_REGION RENDER_REGION].freeze

    def initialize(sdk_key:, base_url: "https://flagdash.io", timeout: 5, cache_ttl: 60, region: nil, transport: nil)
      raise ArgumentError, "sdk_key is required" if sdk_key.to_s.empty?

      @sdk_key = sdk_key
      @base_url = base_url.delete_suffix("/")
      @timeout = timeout
      @cache_ttl = cache_ttl
      @region = region || REGION_ENV.map { |name| ENV[name] }.compact.first
      @transport = transport || method(:http_request)
      @cache = {}
      @mutex = Mutex.new
      @events = []
    end

    def flag(key, default: false, context: nil)
      return flag_detail(key, default: default, context: context).value if context && !context.empty?

      cached("flag:#{key}") { all_flags.fetch(key, default) }
    end

    def flag_detail(key, default: nil, context: nil)
      data = request(:get, "/server/flags/#{segment(key)}", params: context_params(context))
      flag = data.fetch("flag")
      Detail.new(key: flag.fetch("key", key), value: flag.fetch("evaluated_value", default),
                 reason: flag.fetch("evaluation_path", "default"), variation_key: flag["variation_key"])
    rescue StandardError
      Detail.new(key: key, value: default, reason: "default", variation_key: nil)
    end

    def all_flags(context: nil)
      return fetch_flags(context) if context && !context.empty?

      cached("all_flags") { fetch_flags(nil) }
    end

    def list_flags
      request(:get, "/server/flags", params: context_params(nil)).fetch("flags", [])
    end

    def config(key, default: nil)
      cached("config:#{key}") do
        request(:get, "/server/configs/#{segment(key)}").fetch("config", {}).fetch("value", default)
      end
    rescue StandardError
      default
    end

    def get_config(key)
      request(:get, "/server/configs/#{segment(key)}")["config"]
    end

    def list_configs
      request(:get, "/server/configs").fetch("configs", [])
    end

    # Fetch a decrypted secret by key.
    #
    # Deliberately unlike #config: never cached, never defaulted, and it raises
    # on failure. Returning a stale or default credential is worse than failing
    # loudly — a rotated key must take effect on the next call.
    #
    # Requires an sk_ key carrying the secrets:read scope.
    def get_secret(key)
      secret = request(:get, "/server/secrets/#{segment(key)}")["secret"]
      raise "FlagDash: secret '#{key}' returned no value" unless secret.is_a?(Hash) && secret.key?("value")

      secret
    end

    # Just the decrypted value. Raises for the same reasons as #get_secret.
    # Explicit backend resolution; errors propagate and plaintext is never cached.
    def resolve_config(key)
      request(:post, "/server/configs/#{segment(key)}/resolve", json: {}).fetch("config")
    end

    def resolve_ai_release(key, user_id: "anonymous")
      request(:post, "/server/ai-config-releases/#{segment(key)}/resolve", json: {user_id: user_id}).fetch("ai_config")
    end

    def secret(key)
      get_secret(key)["value"]
    end

    # Uncached evaluation; secret references remain unresolved.
    def ai_config_release(key, user_id: "anonymous")
      request(:get, "/ai-config-releases/#{segment(key)}", params: {user_id: user_id}).fetch("ai_config")
    end

    def ai_config(file_name)
      cached("ai:#{file_name}") { request(:get, "/server/ai-configs/#{segment(file_name)}")["ai_config"] }
    rescue StandardError
      nil
    end

    def list_ai_configs(file_type: nil, folder: :any)
      request(:get, "/server/ai-configs").fetch("ai_configs", []).select do |item|
        (!file_type || item["file_type"] == file_type.to_s) && (folder == :any || item["folder"] == folder)
      end
    end

    def translation(key, locale:, default: nil, variables: {})
      namespace, message = key.split(".", 2)
      return default || key unless message

      catalog = cached("translation:#{locale}:#{namespace}") do
        request(:get, "/server/translations/#{segment(locale)}/#{segment(namespace)}").fetch("catalog", {})
      end
      pattern = catalog.fetch("messages", {})[message]
      return default || key unless pattern

      pattern.gsub(/\{([\w.]+)\}/) { |match| variables.fetch(Regexp.last_match(1), variables.fetch(Regexp.last_match(1).to_sym, match)).to_s }
    rescue StandardError
      default || key
    end

    def experiment(key, context:)
      return nil unless identity(context)

      request(:get, "/server/experiments/#{segment(key)}", params: context_params(context))["experiment"]
    rescue StandardError
      nil
    end

    def track_experiment_metric(experiment_key:, event_name:, user_id:, value: nil, properties: {}, event_id: nil, occurred_at: nil)
      event = {event_id: event_id || "evt_#{SecureRandom.uuid}", experiment_key: experiment_key,
               event_name: event_name, user_id: user_id, value: value, properties: properties,
               occurred_at: occurred_at || Time.now.utc.iso8601}
      @mutex.synchronize { @events << event if @events.length < 1_000 }
      nil
    end

    def flush
      loop do
        batch = @mutex.synchronize { @events.first(100) }
        break if batch.empty?

        request(:post, "/server/experiment-events/batch", json: {events: batch})
        @mutex.synchronize { @events.shift(batch.length) }
      end
      true
    rescue StandardError
      false
    end

    def clear_cache
      @mutex.synchronize { @cache.clear }
    end

    def close
      flush
    end

    private

    def fetch_flags(context)
      values = request(:get, "/server/flags", params: context_params(context)).fetch("evaluated", {})
      @mutex.synchronize { values.each { |key, value| put_cache("flag:#{key}", value) } } unless context
      values
    end

    def cached(key)
      return yield if @cache_ttl.zero?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      hit = @mutex.synchronize { @cache[key] }
      return hit[0] if hit && hit[1] > now

      value = yield
      @mutex.synchronize { put_cache(key, value) }
      value
    end

    def put_cache(key, value)
      @cache[key] = [value, Process.clock_gettime(Process::CLOCK_MONOTONIC) + @cache_ttl]
    end

    def request(method, path, params: {}, json: nil)
      @transport.call(method, "#{@base_url}/api/v1#{path}", params, json, @sdk_key, @timeout)
    end

    def http_request(method, url, params, json, key, timeout)
      uri = URI(url)
      uri.query = URI.encode_www_form(params) unless params.empty?
      request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(json) if json
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) { |http| http.request(request) }
      raise "FlagDash HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end

    def context_params(context)
      result = (context || {}).transform_keys(&:to_s)
      user = result.delete("user")
      user&.each { |key, value| result[key.to_s == "id" ? "user_id" : "user_#{key}"] = value }
      result["region"] ||= @region if @region
      result
    end

    def identity(context)
      context[:user_id] || context["user_id"] || context[:unit_id] || context["unit_id"] || context.dig(:user, :id) || context.dig("user", "id")
    end

    def segment(value)
      URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end
  end
end
