# フロントエンドの公開オリジン(FRONTEND_ORIGIN、カンマ区切りで複数可)。
# 例: "https://react-frontend-beige.vercel.app,https://worktempo.vercel.app"
# CORS の許可(config/initializers/cors.rb)と、Google ログイン後の戻り先に使う。
module FrontendOrigin
  DEFAULT = "http://localhost:5173".freeze

  module_function

  def allowed
    ENV.fetch("FRONTEND_ORIGIN", DEFAULT).split(",").map(&:strip).reject(&:empty?).presence || [ DEFAULT ]
  end

  # ログインを始めた画面のオリジン(candidate)が許可リストにあればそれを、無ければ先頭を返す。
  # candidate は URL でもオリジンでもよい。許可外のホストへは決してリダイレクトしない(オープンリダイレクト防止)。
  def resolve(candidate)
    requested_origin = origin_of(candidate)
    allowed.include?(requested_origin) ? requested_origin : allowed.first
  end

  def origin_of(url)
    uri = URI.parse(url.to_s)
    return nil unless uri.scheme && uri.host

    default_port = uri.scheme == "https" ? 443 : 80
    port_suffix = uri.port && uri.port != default_port ? ":#{uri.port}" : ""
    "#{uri.scheme}://#{uri.host}#{port_suffix}"
  rescue URI::InvalidURIError
    nil
  end
end
