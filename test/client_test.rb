require "minitest/autorun"
require_relative "../lib/flagdash"

class ClientTest < Minitest::Test
  def setup
    @calls = []
    transport = lambda do |method, url, params, json, _key, _timeout|
      @calls << [method, url, params, json]
      case URI(url).path
      when "/api/v1/server/flags" then {"evaluated" => {"checkout" => true}, "flags" => [{"key" => "checkout"}]}
      when "/api/v1/server/flags/checkout" then {"flag" => {"key" => "checkout", "evaluated_value" => true, "evaluation_path" => "rule_match"}}
      when "/api/v1/server/configs/theme" then {"config" => {"value" => "violet"}}
      when "/api/v1/server/ai-configs/agent.md" then {"ai_config" => {"content" => "Be useful"}}
      when "/api/v1/server/translations/en/common" then {"catalog" => {"messages" => {"welcome" => "Hello {name}"}}}
      when "/api/v1/server/experiments/test" then {"experiment" => {"variant_key" => "b"}}
      when "/api/v1/server/experiment-events/batch" then {"accepted" => json[:events].length}
      else {}
      end
    end
    @client = FlagDash::Client.new(sdk_key: "sk_test", region: "eu", transport: transport)
  end

  def test_reads_resources_and_context
    assert @client.flag("checkout")
    assert_equal "rule_match", @client.flag_detail("checkout", context: {user: {id: "alice"}}).reason
    assert_equal "violet", @client.config("theme")
    assert_equal "Be useful", @client.ai_config("agent.md")["content"]
    assert_equal "Hello Ada", @client.translation("common.welcome", locale: "en", variables: {name: "Ada"})
    assert_equal "b", @client.experiment("test", context: {user_id: "alice"})["variant_key"]
    assert_equal "alice", @calls.find { |call| call[1].end_with?("/checkout") }[2]["user_id"]
  end

  def test_batches_metrics
    @client.track_experiment_metric(experiment_key: "test", event_name: "purchase", user_id: "alice")
    assert @client.flush
    assert_equal 1, @calls.last[3][:events].length
  end
end
