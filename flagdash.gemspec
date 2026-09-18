require_relative "lib/flagdash/version"

Gem::Specification.new do |spec|
  spec.name = "flagdash"
  spec.version = FlagDash::VERSION
  spec.authors = ["FlagDash"]
  spec.email = ["support@flagdash.com"]
  spec.summary = "Official server-side FlagDash SDK for Ruby"
  spec.homepage = "https://flagdash.com/docs#sdk-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.metadata = {
    "source_code_uri" => "https://github.com/flagdash/flagdash-ruby",
    "changelog_uri" => "https://github.com/flagdash/flagdash-ruby/releases"
  }
end
