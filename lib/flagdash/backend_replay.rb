module FlagDash
  # Privacy-safe, explicit event timeline for trusted Ruby backends.
  class BackendReplay
    SENSITIVE = /pass(word)?|secret|token|authorization|cookie|session|api[-_]?key|credit|card|cvv|cvc|otp|ssn/i

    def initialize(sdk_key:, base_url: "https://flagdash.io", identity: nil, release: nil, metadata: {}, timeout: 5, transport: nil)
      @sdk_key = sdk_key
      @base_url = base_url.delete_suffix("/")
      @identity = identity
      @release = release
      @metadata = sanitize(metadata)
      @timeout = timeout
      @transport = transport || method(:request)
      @started_at = Time.now.utc
      @events = []
      @sequence = 0
      @mutex = Mutex.new
    end

    def start
      response = @transport.call(:post, "#{@base_url}/api/v1/replay-sessions/start", {
        type: "trace", platform: "ruby", sdk_name: "flagdash-ruby",
        started_at: @started_at.iso8601(6), identity: @identity, release: @release, metadata: @metadata
      })
      return false if response == :disabled
      @id = response.fetch("id")
      true
    rescue StandardError
      false
    end

    def event(name, category: "action", attributes: {})
      @mutex.synchronize do
        return unless @id && !name.to_s.empty? && @events.length < 1_000
        @events << { name: name.to_s[0, 100], category: category.to_s[0, 40], timestamp: Time.now.utc.iso8601(6), attributes: sanitize(attributes) }
      end
    end

    def breadcrumb(message, attributes = {})
      event(message, category: "breadcrumb", attributes: attributes)
    end

    def capture_exception(error, attributes = {})
      event(error.class.name, category: "exception", attributes: attributes)
    end

    def context_headers
      @id ? { "x-flagdash-replay-id" => @id } : {}
    end

    def flush
      loop do
        batch, sequence = @mutex.synchronize do
          break [nil, nil] unless @id && !@events.empty?
          [@events.shift(100), (@sequence += 1) - 1]
        end
        break unless batch
        bytes = JSON.generate(batch)
        manifest = @transport.call(:post, "#{@base_url}/api/v1/replay-sessions/#{@id}/chunks/presign", {
          sequence: sequence, byte_size: bytes.bytesize, event_count: batch.length, content_encoding: "identity"
        })
        @transport.call(:put, manifest.fetch("upload").fetch("url"), bytes, manifest.fetch("upload").fetch("headers", {}))
      end
      true
    end

    def stop
      flush
      return true unless @id
      @transport.call(:post, "#{@base_url}/api/v1/replay-sessions/#{@id}/complete", {
        ended_at: Time.now.utc.iso8601(6), duration_ms: ((Time.now.utc - @started_at) * 1_000).to_i
      })
      true
    end

    private

    def request(method, url, body = nil, headers = {})
      uri = URI(url)
      request = method == :put ? Net::HTTP::Put.new(uri) : Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@sdk_key}" unless method == :put
      request["Content-Type"] = "application/json" unless method == :put
      headers.each { |key, value| request[key] = value }
      request.body = body.is_a?(String) ? body : JSON.generate(body)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout, read_timeout: @timeout) { |http| http.request(request) }
      return :disabled if response.code.to_i == 204
      raise "FlagDash replay HTTP #{response.code}" unless response.code.to_i.between?(200, 299)
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    end

    def sanitize(value, depth = 0)
      return "[REDACTED]" if depth > 8
      case value
      when Hash then value.to_a.first(500).to_h { |key, item| [key, key.to_s.match?(SENSITIVE) ? "[REDACTED]" : sanitize(item, depth + 1)] }
      when Array then value.first(500).map { |item| sanitize(item, depth + 1) }
      when String then value[0, 2_000]
      when NilClass, TrueClass, FalseClass, Numeric then value
      else "[REDACTED]"
      end
    end
  end
end
