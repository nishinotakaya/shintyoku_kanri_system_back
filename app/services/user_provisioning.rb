# ユーザーの新規登録(招待)まわりの共通処理。
# 管理画面(admin/users)からの作成・招待メール再送と、契約書署名後の乙の自動登録の両方から使う。
module UserProvisioning
  module_function

  # creator の配下メンバーとしてユーザーを作る。
  # creator が admin 以外(サブ管理者)なら画面構成(機能フラグ・勤怠カテゴリ・締日)を引き継ぎ、
  # 管理対象 + テナントメンバーに紐づける(勤怠の閲覧対象セレクト・ユーザー一覧・カレンダーに出る)。
  def create_member!(email:, display_name:, creator:)
    user = User.new(
      email: email,
      display_name: display_name.to_s.strip.presence || email.split("@").first,
      password: Devise.friendly_token[0, 24]  # 本人は Google ログインで入るためランダムでよい
    )
    unless creator.admin?
      user.feature_flags = creator.feature_flags.to_h
      user.work_categories = creator.work_categories
      user.closing_day = creator.closing_day
    end
    user.save!
    unless creator.admin?
      creator.manager_assignments.find_or_create_by!(managee_id: user.id)
      creator.owned_tenants.first&.tenant_memberships&.find_or_create_by!(user_id: user.id)
    end
    user
  end

  # 登録URL(Google ログイン案内)の招待メール。送信者(inviter)が Google 未連携でも
  # 連携済みユーザーのトークンにフォールバックして送る。文面上の差出人は inviter のまま。
  def send_invite!(invitee:, inviter:)
    sign_in_url = ENV["FRONTEND_URL"].presence || "https://react-frontend-beige.vercel.app"
    subject = "【勤怠アプリ】#{inviter.display_name}さんから招待が届きました"
    body = <<~BODY
      #{invitee.display_name} 様

      #{inviter.display_name}さんが勤怠アプリにあなたを招待しました。

      下記URLにアクセスし、Googleアカウント（このメールアドレス: #{invitee.email}）でログインしてください。
      #{sign_in_url}/sign_in

      ※ Googleログインのメールアドレスが上記と一致すれば、自動で本アプリのアカウントに紐づきます。
      ※ ログイン後、メニュー右上の ⚙ 設定 → アカウント から表示名や請求書情報を編集できます。

      ご不明点があれば #{inviter.email} までご連絡ください。

      ---
      勤怠アプリ
    BODY

    GmailSender.new(user: GoogleAuth.credential_user(inviter)).send_mail(
      to: invitee.email,
      subject: subject,
      body: body,
      from_name: inviter.display_name
    )
  end
end
