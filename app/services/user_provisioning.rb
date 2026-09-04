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

  # 招待リンク(署名付きトークン)の有効期限
  INVITATION_EXPIRY = 14.days

  def frontend_url
    ENV["FRONTEND_URL"].presence || "https://react-frontend-beige.vercel.app"
  end

  # 登録URL付きの招待メール。リンク先(/invite/:token)でパスワードを設定すると登録が完了する。
  # 送信者(inviter)が Google 未連携でも連携済みユーザーのトークンにフォールバックして送る。
  def send_invite!(invitee:, inviter:)
    invite_token = invitee.signed_id(purpose: :invitation, expires_in: INVITATION_EXPIRY)
    invite_url = "#{frontend_url}/invite/#{invite_token}"
    tenant_name = inviter.owned_tenants.first&.name
    subject = "【勤怠アプリ】#{inviter.display_name}さんから招待が届きました"
    body = <<~BODY
      #{invitee.display_name} 様

      #{inviter.display_name}さんが勤怠アプリ#{tenant_name.present? ? "（#{tenant_name}）" : ""}にあなたを招待しました。

      下記URLからパスワードを設定して、登録を完了してください（リンクの有効期限: 14日間）。
      #{invite_url}

      ※ Googleアカウント（このメールアドレス: #{invitee.email}）をお持ちの場合は、
         #{frontend_url}/sign_in の「Googleでログイン」からもそのまま利用を開始できます。

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

  # 登録完了の確認メール。招待リンクからパスワードを設定し終えたユーザーに送る。
  def send_registration_complete!(user:)
    subject = "【勤怠アプリ】登録が完了しました"
    body = <<~BODY
      #{user.display_name} 様

      勤怠アプリへの登録が完了しました。このメールは登録確認のお知らせです。

      ログインはこちら:
      #{frontend_url}/sign_in

      メールアドレス: #{user.email}

      ---
      勤怠アプリ
    BODY

    GmailSender.new(user: GoogleAuth.credential_user(user)).send_mail(
      to: user.email, subject: subject, body: body, from_name: "勤怠アプリ"
    )
  end

  # 乙が契約書に署名したことを甲(発行者)へ知らせるメール。
  # ユーザー登録は自動では行わず、甲が契約書一覧の「招待」ボタンを押したときに
  # 招待メール送信＋登録が走る(承認ゲート)。
  def send_signed_notice!(contract:)
    owner = contract.user
    app_url = ENV["FRONTEND_URL"].presence || "https://react-frontend-beige.vercel.app"
    subject = "【勤怠アプリ】#{contract.party_b_name}さんが契約書に署名しました"
    body = <<~BODY
      #{owner.display_name} 様

      「#{contract.title}」に署名がありました。

      署名者: #{contract.signer_name}
      乙の氏名: #{contract.party_b_name}
      メールアドレス: #{contract.party_b_email.presence || "(未入力)"}

      内容を確認のうえ、アプリの契約書一覧で「📨 招待」を押すと、
      上記メールアドレスへ登録用の招待メールが送られ、ユーザーとして登録されます。
      #{app_url}/contracts

      ---
      勤怠アプリ
    BODY

    GmailSender.new(user: GoogleAuth.credential_user(owner)).send_mail(
      to: owner.email, subject: subject, body: body, from_name: "勤怠アプリ"
    )
  end
end
