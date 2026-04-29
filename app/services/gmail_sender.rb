require "base64"
require "mail"
require "stringio"
require "google/apis/gmail_v1"
require "signet/oauth_2/client"

# Google Gmail API 経由でメールを送る (OAuth トークン必須)。
# 添付ファイル付きにも対応。テスト送信先制御 (OUTBOUND_TEST_RECIPIENT) あり。
#
# user.google_access_token + google_refresh_token を利用。
# scope に https://www.googleapis.com/auth/gmail.send が含まれている必要あり (devise.rb 参照)。
class GmailSender
  Attachment = Struct.new(:filename, :content_type, :body, keyword_init: true)

  def initialize(user:)
    @user = user
    raise "Google アクセストークンがありません。再度 Google ログインしてください。" if @user.google_access_token.blank?
  end

  # to: 文字列 or 配列
  # attachments: [{ filename:, content_type:, body: <String binary> }]
  def send_mail(to:, subject:, body:, attachments: [], from_name: nil)
    # 宛先は呼び出し元 (Frontend) が指定したものをそのまま使う。
    # OUTBOUND_TEST_RECIPIENT は to が空のときのみフォールバックとして利用。
    actual_to = Array(to).flatten.map { |t| t.to_s.strip }.reject(&:empty?).uniq
    if actual_to.empty?
      fallback = ENV["OUTBOUND_TEST_RECIPIENT"].to_s.strip
      actual_to = [ fallback ] if fallback.present?
    end
    raise "送信先がありません" if actual_to.empty?

    # Mail gem に文字列で To を渡すと RFC822 ヘッダが確実に作られる
    to_header = actual_to.join(", ")
    Rails.logger.info("[GmailSender] to=#{to_header} from=#{@user.email} attachments=#{attachments.size}")

    mail = Mail.new
    mail.from    = from_name ? "#{from_name} <#{@user.email}>" : @user.email
    mail.to      = to_header
    mail.subject = subject
    mail.body    = body.to_s
    mail.charset = "UTF-8"

    Array(attachments).each do |att|
      mail.add_file(filename: att[:filename], content: att[:body])
      mail.attachments[att[:filename]].content_type = att[:content_type] if att[:content_type]
    end

    raw_body = mail.to_s
    raise "メールの To ヘッダが生成されませんでした" unless raw_body.include?("To: ")
    Rails.logger.info("[GmailSender] raw size=#{raw_body.bytesize} bytes")

    service = Google::Apis::GmailV1::GmailService.new
    service.authorization = build_auth

    # multipart/related (RFC822 アップロード) で送信。
    # JSON + base64(raw) 方式は ~5MB 上限・添付込みでパース失敗しやすい。
    # upload_source + content_type='message/rfc822' なら ~35MB 程度まで OK。
    res = service.send_user_message(
      "me",
      Google::Apis::GmailV1::Message.new,
      upload_source: StringIO.new(raw_body),
      content_type: "message/rfc822"
    )
    res.id
  end

  private

  def build_auth
    auth = Signet::OAuth2::Client.new(
      token_credential_uri: "https://oauth2.googleapis.com/token",
      client_id: ENV["GOOGLE_CLIENT_ID"],
      client_secret: ENV["GOOGLE_CLIENT_SECRET"],
      access_token: @user.google_access_token,
      refresh_token: @user.google_refresh_token
    )
    if @user.google_token_expires_at && @user.google_token_expires_at < Time.current && @user.google_refresh_token.present?
      auth.fetch_access_token!
      @user.update!(google_access_token: auth.access_token, google_token_expires_at: Time.current + 3600)
    end
    auth
  end
end

# 送信先ガード: ENV[OUTBOUND_TEST_RECIPIENT] が設定されていれば常にそこへ向ける。
# ATTENDANCE_PATTERNS.md「外部送信を伴う機能の安全運用パターン」参照。
module MailRecipientGuard
  def self.actual_to(intended)
    test_to = ENV["OUTBOUND_TEST_RECIPIENT"]
    test_to.present? ? test_to : intended
  end
end
