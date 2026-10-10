Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # カンマ区切りで複数指定可(例: 旧URL react-frontend-beige と新URL worktempo の併用)
    origins(*ENV.fetch("FRONTEND_ORIGIN", "http://localhost:5173").split(",").map(&:strip).reject(&:empty?))
    resource "*",
      headers: :any,
      expose: [ "Authorization", "Content-Disposition",
                "X-Wbs-Matched", "X-Wbs-Appended", "X-Wbs-Skipped",
                "X-Wbs-Changed-Cells", "X-Wbs-Unsubmitted-Cells" ], # DLファイル名(案件先プレフィックス付き)をフロントで読むため
      methods: [ :get, :post, :put, :patch, :delete, :options, :head ],
      credentials: false
  end
end
