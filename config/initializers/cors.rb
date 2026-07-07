Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("FRONTEND_ORIGIN", "http://localhost:5173")
    resource "*",
      headers: :any,
      expose: [ "Authorization", "Content-Disposition" ], # DLファイル名(案件先プレフィックス付き)をフロントで読むため
      methods: [ :get, :post, :put, :patch, :delete, :options, :head ],
      credentials: false
  end
end
