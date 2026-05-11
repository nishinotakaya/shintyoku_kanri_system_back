source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.3"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
gem "rack-cors"

# Auth
gem "devise", "~> 5.0"
gem "devise-jwt", "~> 0.12"
# Devise 4.9.4 が Zeitwerk 2.7 の strict require と非互換のため 2.6 系に固定
gem "zeitwerk", "~> 2.6.0"

# Excel 既存テンプレートを書式維持で編集
gem "rubyXL", "~> 3.4"

# OpenAI
gem "ruby-openai", "~> 7.4"

# PDF テキスト抽出 (発注書 PDF からの注文番号/金額自動抽出に使用)
gem "pdf-reader", "~> 2.13"

# .env loader (development)
gem "dotenv-rails", "~> 3.1", groups: [ :development, :test ]

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

gem "omniauth-google-oauth2", "~> 1.2"
# omniauth-rails_csrf_protection は API モードでは不要（CSRF トークンがない）

gem "google-apis-sheets_v4", "~> 0.47.0"
gem "google-apis-gmail_v1", "~> 0.36"

gem "dockerfile-rails", ">= 1.7", group: :development
