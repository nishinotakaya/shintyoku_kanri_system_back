# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t rails_backend .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name rails_backend rails_backend

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.0
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages（Node + Python + Chromium ランタイム依存 + 日本語フォント）
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 sqlite3 \
      python3 python3-openpyxl \
      ca-certificates gnupg \
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 \
      libxkbcommon0 libpango-1.0-0 libcairo2 libasound2 libxcomposite1 \
      libxdamage1 libxfixes3 libxrandr2 fonts-noto-cjk && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Install Node deps + Playwright Chromium (HTML→PDF 用)
COPY package.json package-lock.json ./
RUN npm ci && \
    npx playwright install chromium && \
    rm -rf ~/.npm

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/




# Final stage for app image
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails
COPY --from=build /root/.cache/ms-playwright /root/.cache/ms-playwright

ENV PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
ENV PORT=80
CMD ["./bin/thrust", "./bin/rails", "server"]
