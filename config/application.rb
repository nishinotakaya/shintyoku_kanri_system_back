require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RailsBackend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = "Asia/Tokyo"
    config.i18n.default_locale = :ja
    config.i18n.available_locales = [ :ja, :en ]
    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.yml")]
    # DB の DATETIME 解釈は UTC のまま（Rails 標準）。アプリ内の Time は JST で扱う
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # OmniAuth にセッションが必要なので最小限追加
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore, key: "_attendance_session"

    # API only モードで action_mailer/railtie を読み込んでいないため、
    # Devise gem の app/mailers/devise/mailer.rb を eager_load から除外する
    # （メール送信機能を使わないため、実際の利用は発生しない）
    initializer "exclude_devise_mailer_from_eager_load", after: :let_zeitwerk_take_over do
      devise_spec = Gem.loaded_specs["devise"]
      Rails.autoloaders.main.ignore("#{devise_spec.full_gem_path}/app/mailers") if devise_spec
    end
  end
end
