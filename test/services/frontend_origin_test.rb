require "test_helper"

class FrontendOriginTest < ActiveSupport::TestCase
  ORIGINS = "https://react-frontend-beige.vercel.app, https://worktempo.vercel.app"

  def with_frontend_origin(value)
    previous = ENV["FRONTEND_ORIGIN"]
    ENV["FRONTEND_ORIGIN"] = value
    yield
  ensure
    ENV["FRONTEND_ORIGIN"] = previous
  end

  test "カンマ区切りを許可リストとして読む" do
    with_frontend_origin(ORIGINS) do
      assert_equal [ "https://react-frontend-beige.vercel.app", "https://worktempo.vercel.app" ], FrontendOrigin.allowed
    end
  end

  test "許可リストにある開始元へ戻す（パス付き URL でもオリジンで判定）" do
    with_frontend_origin(ORIGINS) do
      assert_equal "https://worktempo.vercel.app", FrontendOrigin.resolve("https://worktempo.vercel.app/sign_in")
    end
  end

  test "許可外・不正・未指定は先頭へ戻す（オープンリダイレクトしない）" do
    with_frontend_origin(ORIGINS) do
      assert_equal "https://react-frontend-beige.vercel.app", FrontendOrigin.resolve("https://evil.example")
      assert_equal "https://react-frontend-beige.vercel.app", FrontendOrigin.resolve("https://worktempo.vercel.app.evil.example")
      assert_equal "https://react-frontend-beige.vercel.app", FrontendOrigin.resolve("javascript:alert(1)")
      assert_equal "https://react-frontend-beige.vercel.app", FrontendOrigin.resolve(nil)
    end
  end

  test "単一値の従来設定もそのまま動く" do
    with_frontend_origin("https://react-frontend-beige.vercel.app") do
      assert_equal "https://react-frontend-beige.vercel.app", FrontendOrigin.resolve(nil)
    end
  end

  test "ローカルはポート付きオリジンで照合する" do
    with_frontend_origin("http://localhost:5173") do
      assert_equal "http://localhost:5173", FrontendOrigin.resolve("http://localhost:5173/sign_in")
    end
  end
end
