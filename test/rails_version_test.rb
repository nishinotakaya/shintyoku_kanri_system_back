require "test_helper"

# Rails 8.1 系（8.1.4 以上）へ更新済みであることを保証する。DB は触らない。
class RailsVersionTest < ActiveSupport::TestCase
  test "Rails のバージョンが 8.1 系である" do
    assert Rails.version.start_with?("8.1."), "Rails 8.1 系を期待したが #{Rails.version} だった"
  end

  test "Rails のバージョンが 8.1.4 以上である" do
    assert_operator Gem::Version.new(Rails.version), :>=, Gem::Version.new("8.1.4")
  end

  test "Ruby のバージョンが 3.4.11 以上の 3.4 系である" do
    assert RUBY_VERSION.start_with?("3.4."), "Ruby 3.4 系を期待したが #{RUBY_VERSION} だった"
    assert_operator Gem::Version.new(RUBY_VERSION), :>=, Gem::Version.new("3.4.11")
  end
end
