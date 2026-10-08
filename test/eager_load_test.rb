require "test_helper"

# production は eager_load = true で起動する。test 環境は CI のときだけ eager_load するため、
# bundled gem の取りこぼし（例: csv）による LoadError を通常のテスト実行では検知できない。
# CI 環境変数の有無に関係なく、常に全アプリコードを読み込んで検証する。
class EagerLoadTest < ActiveSupport::TestCase
  test "本番と同じ eager_load で全アプリコードが読み込める" do
    assert_nothing_raised do
      Rails.application.eager_load!
    end
  end
end
