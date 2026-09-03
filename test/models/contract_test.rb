require "test_helper"

# Contract: 業務委託契約書のモデルロジック(既定値・状態遷移・署名フロー・複製)。
#
# ContractPdfRenderer#call は Node(Playwright)を起動して実際にPDFを生成するため遅い。
# sign! のビジネスロジック(ステータス遷移・content_sha256・イベント記録)だけを検証したい
# テストでは、stub_contract_pdf_renderer でこのテストファイル内だけ一時的に軽量な内容へ
# 差し替える(プロダクトコードである app/services/contract_pdf_renderer.rb 自体は変更しない)。
#
# 注意: activerecord.errors 用の ja ロケールファイルが無いため、presence/inclusion など
# I18n参照型のバリデーションメッセージは「Translation missing: ...」になる(本テストでは
# メッセージ文言ではなく、エラーが「存在すること」だけを検証する)。一方 errors.add(:base, "...")
# のように文字列を直接渡している箇所(署名済みロック・SignatureImage)はI18nを経由しないため
# 実際の日本語文言をそのまま検証できる。
class ContractTest < Minitest::Test
  VALID_SIGNATURE_IMAGE =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=".freeze

  def setup
    @user = User.create!(
      email: "contract_model_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "契約 太郎",
      closing_day: 25
    )
  end

  def teardown
    @user.destroy
  end

  def test_new_record_uses_database_column_defaults_for_title_and_status
    contract = Contract.new(user: @user, party_a_name: "テスト甲")

    assert_equal "業務委託契約書", contract.title
    assert_equal "draft", contract.status
  end

  def test_validates_presence_of_title_and_party_a_name
    contract = Contract.new(user: @user, title: "", party_a_name: "")

    refute contract.valid?
    refute_empty contract.errors[:title], "titleが空のときエラーが付与されるべき"
    refute_empty contract.errors[:party_a_name], "party_a_nameが空のときエラーが付与されるべき"
  end

  def test_validates_status_inclusion
    contract = build_contract
    contract.status = "unknown"

    refute contract.valid?
    refute_empty contract.errors[:status]
  end

  def test_editable_is_true_for_draft_and_sent_only
    contract = build_contract
    assert contract.editable?

    contract.update!(status: "sent")
    assert contract.editable?

    contract.update_columns(status: "signed")
    refute contract.reload.editable?

    contract.update_columns(status: "void")
    refute contract.reload.editable?
  end

  def test_issue_generates_digest_sets_sent_status_and_thirty_day_expiry
    contract = build_contract

    raw_token = contract.issue!(actor: "user:#{@user.id}")

    contract.reload
    assert_equal "sent", contract.status
    refute_nil contract.sent_at
    assert_equal Digest::SHA256.hexdigest(raw_token), contract.share_token_digest
    refute_equal raw_token, contract.share_token_digest, "DBには生トークンではなくdigestのみ保存される"
    assert_in_delta 30.days.from_now.to_i, contract.share_expires_at.to_i, 5
    assert_equal "issued", contract.contract_events.order(:created_at).last.event
  end

  def test_reissue_invalidates_previous_share_token
    contract = build_contract

    first_raw_token = contract.issue!(actor: "user:#{@user.id}")
    assert_equal contract.id, Contract.find_by_share_token(first_raw_token).id

    second_raw_token = contract.issue!(actor: "user:#{@user.id}")

    refute_equal first_raw_token, second_raw_token
    assert_nil Contract.find_by_share_token(first_raw_token), "再発行後は旧トークンで見つからない"
    assert_equal contract.id, Contract.find_by_share_token(second_raw_token).id
  end

  def test_find_by_share_token_returns_nil_for_blank_or_unknown_token
    assert_nil Contract.find_by_share_token(nil)
    assert_nil Contract.find_by_share_token("")
    assert_nil Contract.find_by_share_token("this-token-does-not-exist")
  end

  def test_signable_is_false_before_issue_and_true_after_issue
    contract = build_contract
    refute contract.signable?

    contract.issue!(actor: "user:#{@user.id}")
    assert contract.signable?
  end

  def test_signable_is_false_after_share_expires_at_has_passed
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")
    contract.update_columns(share_expires_at: 1.minute.ago)

    refute contract.signable?
  end

  def test_signable_is_false_when_void
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")
    contract.update!(status: "void")

    refute contract.signable?
  end

  def test_sign_success_sets_status_content_hash_pdf_and_records_event
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")

    stub_contract_pdf_renderer do
      contract.sign!(signer_name: "山田 太郎", signature_image: VALID_SIGNATURE_IMAGE,
                     ip: "203.0.113.10", user_agent: "TestAgent/1.0")
    end

    contract.reload
    assert_equal "signed", contract.status
    assert_equal "山田 太郎", contract.signer_name
    refute_nil contract.signed_at
    assert_equal 64, contract.content_sha256.length, "SHA-256のhexdigestは64文字"
    assert_equal "%PDF-stub", contract.signed_pdf
    refute contract.editable?

    last_event = contract.contract_events.order(:created_at).last
    assert_equal "signed", last_event.event
    assert_equal "party_b", last_event.actor
    assert_equal "203.0.113.10", last_event.ip
  end

  def test_sign_raises_not_signable_when_contract_is_still_draft
    contract = build_contract

    assert_raises(Contract::NotSignable) do
      contract.sign!(signer_name: "山田 太郎", signature_image: VALID_SIGNATURE_IMAGE)
    end
  end

  def test_sign_raises_not_signable_when_already_signed
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")
    stub_contract_pdf_renderer do
      contract.sign!(signer_name: "山田 太郎", signature_image: VALID_SIGNATURE_IMAGE)
    end

    assert_raises(Contract::NotSignable) do
      contract.sign!(signer_name: "別の署名者", signature_image: VALID_SIGNATURE_IMAGE)
    end
  end

  def test_sign_raises_not_signable_when_expired
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")
    contract.update_columns(share_expires_at: 1.minute.ago)

    assert_raises(Contract::NotSignable) do
      contract.sign!(signer_name: "山田 太郎", signature_image: VALID_SIGNATURE_IMAGE)
    end
  end

  def test_sign_raises_not_signable_when_void
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")
    contract.update!(status: "void")

    assert_raises(Contract::NotSignable) do
      contract.sign!(signer_name: "山田 太郎", signature_image: VALID_SIGNATURE_IMAGE)
    end
  end

  # SignatureImage の検証は with_lock より前に行われるため、PDF生成には一切到達しない
  # (stub_contract_pdf_renderer が不要)。
  def test_sign_with_invalid_signature_image_raises_record_invalid_without_changing_status
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")

    assert_raises(ActiveRecord::RecordInvalid) do
      contract.sign!(signer_name: "山田 太郎", signature_image: "data:image/jpeg;base64,AAAA")
    end

    contract.reload
    assert_equal "sent", contract.status
    assert_nil contract.signed_at
    assert_nil contract.contract_events.find_by(event: "signed")
  end

  def test_freeze_prevents_body_changes_after_signed
    contract = build_contract
    contract.issue!(actor: "user:#{@user.id}")
    stub_contract_pdf_renderer do
      contract.sign!(signer_name: "山田 太郎", signature_image: VALID_SIGNATURE_IMAGE)
    end

    refute contract.update(title: "改ざんタイトル")
    assert_includes contract.errors[:base], "署名済みの契約書は変更できません"
    assert_equal "業務委託契約書", contract.reload.title

    assert_raises(ActiveRecord::RecordNotSaved) { contract.update!(title: "改ざんタイトル") }
  end

  def test_party_hashes_stringify_blank_fields
    contract = Contract.new(user: @user, party_a_name: "甲社")

    assert_equal({ name: "甲社", address: "", representative: "" }, contract.party_a_hash)
    assert_equal({ name: "", address: "", representative: "", email: "" }, contract.party_b_hash)
  end

  def test_duplicate_for_creates_draft_copy_without_dates_or_signature_and_leaves_original_unchanged
    original = build_contract(
      party_a_name: "甲社", party_a_address: "東京都千代田区1-1", party_a_representative: "代表 太郎",
      party_b_name: "乙社", party_b_address: "大阪府大阪市2-2", party_b_representative: "代表 花子",
      articles: [ { heading: "見出し", body: "本文" } ], special_terms: "特記事項テスト",
      contract_date: Date.new(2026, 9, 1), start_on: Date.new(2026, 9, 1), end_on: Date.new(2027, 8, 31)
    )
    original.issue!(actor: "user:#{@user.id}")
    stub_contract_pdf_renderer do
      original.sign!(signer_name: "元の署名者", signature_image: VALID_SIGNATURE_IMAGE)
    end

    duplicated = original.duplicate_for(@user)

    assert duplicated.persisted?
    assert_equal "draft", duplicated.status
    assert_equal original.title, duplicated.title
    assert_equal original.party_a_hash, duplicated.party_a_hash
    assert_equal original.party_b_hash, duplicated.party_b_hash
    assert_equal original.articles, duplicated.articles
    assert_equal original.special_terms, duplicated.special_terms
    assert_nil duplicated.contract_date
    assert_nil duplicated.start_on
    assert_nil duplicated.end_on
    assert_nil duplicated.signer_name, "署名者情報は複製先に引き継がれない"
    assert_nil duplicated.signature_image
    assert_nil duplicated.content_sha256
    assert_nil duplicated.share_token_digest

    original.reload
    assert_equal "signed", original.status, "複製元の状態は不変"
    assert_equal Date.new(2026, 9, 1), original.contract_date
    assert_equal "元の署名者", original.signer_name
  end

  def test_record_event_persists_audit_log_entry
    contract = build_contract

    contract.record_event("created", actor: "user:#{@user.id}", ip: "127.0.0.1", user_agent: "RSpec")

    event = contract.contract_events.last
    assert_equal "created", event.event
    assert_equal "user:#{@user.id}", event.actor
    assert_equal "127.0.0.1", event.ip
  end

  private

  def build_contract(attrs = {})
    @user.contracts.create!({ party_a_name: "甲社" }.merge(attrs))
  end

  # ContractPdfRenderer#call は Node(Playwright)を起動するため遅い。
  # sign! のビジネスロジックだけを検証したいテストでは、#call を一時的に軽量な
  # スタブへ差し替える(このテストファイル内のみで有効。呼び出し後は必ず元に戻す)。
  def stub_contract_pdf_renderer
    original_call = ContractPdfRenderer.instance_method(:call)
    stub_pdf_path = Rails.root.join("tmp", "contract_test_stub_#{SecureRandom.hex(6)}.pdf").to_s
    File.write(stub_pdf_path, "%PDF-stub")

    ContractPdfRenderer.send(:define_method, :call) { stub_pdf_path }

    yield
  ensure
    ContractPdfRenderer.send(:define_method, :call, original_call) if original_call
    File.delete(stub_pdf_path) if stub_pdf_path && File.exist?(stub_pdf_path)
  end
end
