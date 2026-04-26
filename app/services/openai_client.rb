require "openai"

class OpenaiClient
  # ユーザー個別のキーがあればそれを優先、なければ環境変数
  def self.for(user)
    new(api_key_for(user))
  end

  def self.client(user = nil)
    new(api_key_for(user)).client
  end

  def self.api_key_for(user)
    user&.openai_api_key.presence || ENV["OPENAI_API_KEY"] || Rails.application.credentials.dig(:openai, :api_key)
  end

  # 後方互換
  def self.api_key
    api_key_for(nil)
  end

  attr_reader :api_key

  def initialize(api_key)
    @api_key = api_key
  end

  def client
    @client ||= OpenAI::Client.new(access_token: @api_key, log_errors: Rails.env.development?)
  end

  def self.chat_model
    ENV.fetch("OPENAI_MODEL", "gpt-4o-mini")
  end

  def self.stt_model
    ENV.fetch("OPENAI_STT_MODEL", "whisper-1")
  end

  def self.transcribe(file, user: nil)
    res = client(user).audio.transcribe(parameters: {
      model: stt_model,
      file: file,
      language: "ja"
    })
    res["text"]
  end
end
