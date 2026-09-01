require "test_helper"

# Api::V1::ContractsController: 発行者(甲)側のCRUD + issue/duplicate/void/pdf。
# - feature `contracts` を持たない一般ユーザーは403、adminはフラグ無しでも使える。
# - IDOR防止: 他人の契約書は show/update/pdf/duplicate で404(current_user.contractsスコープ)。
#
# PDFを実際に生成する(Node/Playwrightを起動する)テストは1本(test_pdf_action_returns_generated_pdf_for_draft_contract)
# に絞る。「署名済み」の状態が必要な他のテストは、状態遷移そのものが検証対象でない限り
# update_columns で直接状態を作る(状態遷移ロジックは test/models/contract_test.rb 側で検証済み)。
class Api::V1::ContractsControllerTest < ActionDispatch::IntegrationTest
  VALID_SIGNATURE_IMAGE =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=".freeze

  def setup
    @owner = User.create!(email: "contracts_owner_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "契約 太郎", closing_day: 25,
                          feature_flags: { "contracts" => true })
    @stranger = User.create!(email: "contracts_stranger_#{SecureRandom.hex(4)}@example.com",
                             password: "password123", display_name: "他人 花子", closing_day: 25,
                             feature_flags: { "contracts" => true })
    @no_feature_user = User.create!(email: "contracts_nofeature_#{SecureRandom.hex(4)}@example.com",
                                    password: "password123", display_name: "権限無 次郎", closing_day: 25)
    @admin = User.create!(email: "contracts_admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
  end

  def teardown
    [ @owner, @stranger, @no_feature_user, @admin ].compact.each(&:destroy)
  end

  # --- feature ゲート ---

  def test_regular_user_without_feature_flag_gets_forbidden
    get "/api/v1/contracts", headers: auth_headers(@no_feature_user)

    assert_response :forbidden
    assert response.parsed_body["error"].present?
  end

  def test_admin_can_use_contracts_without_feature_flag
    get "/api/v1/contracts", headers: auth_headers(@admin)

    assert_response :success
  end

  # --- index ---

  def test_index_returns_only_own_contracts_for_regular_user
    own_contract = create_contract(@owner, title: "自分の契約書")
    create_contract(@stranger, title: "他人の契約書")

    get "/api/v1/contracts", headers: auth_headers(@owner)

    assert_response :success
    ids = response.parsed_body.map { |contract_json| contract_json["id"] }
    assert_includes ids, own_contract.id
    assert_equal 1, response.parsed_body.size
  end

  def test_admin_index_includes_all_users_contracts_with_user_name
    owner_contract = create_contract(@owner, title: "西野以外が作った契約書")

    get "/api/v1/contracts", headers: auth_headers(@admin)

    assert_response :success
    entry = response.parsed_body.find { |contract_json| contract_json["id"] == owner_contract.id }
    assert entry.present?, "adminは全員分の契約書が見える"
    assert_equal @owner.display_name, entry["user_name"]
  end

  # --- create の既定値 ---

  def test_create_applies_default_title_articles_and_party_a_name
    post "/api/v1/contracts", params: { contract: {} }, headers: auth_headers(@owner), as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal "業務委託契約書", body["title"]
    assert_equal @owner.display_name, body["party_a"]["name"]
    assert_equal 15, body["articles"].size
    # page_break_before は改ページ位置(紙の原本の再現用)。標準テンプレートは全条文 false。
    expected_articles = Contract::DefaultArticles::LIST.map do |article|
      { "heading" => article[:heading], "body" => article[:body], "page_break_before" => false }
    end
    assert_equal expected_articles, body["articles"]
  end

  def test_create_with_transport_template_uses_haukur_articles_with_page_breaks
    post "/api/v1/contracts", params: { template: "transport", contract: {} },
         headers: auth_headers(@owner), as: :json

    assert_response :created
    body = response.parsed_body
    assert_equal 29, body["articles"].size
    assert_equal "第1条（目的）", body["articles"].first["heading"]
    # 紙の原本は6ページ。1ページ目以外の先頭(第7/14/20/24/27条)で改ページする。
    page_break_headings = body["articles"].select { |article| article["page_break_before"] }.map { |article| article["heading"] }
    assert_equal ["第7条（運送事業委託の開始）", "第14条（規律）", "第20条（通信機保持義務）",
                  "第24条（直接または間接取引の禁止）", "第27条（損害賠償）"], page_break_headings
  end

  def test_create_default_party_a_inherits_previous_contract
    post "/api/v1/contracts",
         params: { contract: { party_a_name: "西野商店", party_a_address: "東京都渋谷区1-1-1",
                               party_a_representative: "西野鷹也" } },
         headers: auth_headers(@owner), as: :json
    assert_response :created

    post "/api/v1/contracts", params: { contract: {} }, headers: auth_headers(@owner), as: :json

    assert_response :created
    party_a = response.parsed_body["party_a"]
    assert_equal "西野商店", party_a["name"]
    assert_equal "東京都渋谷区1-1-1", party_a["address"]
    assert_equal "西野鷹也", party_a["representative"]
  end

  # --- show / IDOR ---

  def test_show_returns_own_contract
    contract = create_contract(@owner)

    get "/api/v1/contracts/#{contract.id}", headers: auth_headers(@owner)

    assert_response :success
    assert_equal contract.id, response.parsed_body["id"]
  end

  def test_show_of_other_users_contract_is_not_found
    other_contract = create_contract(@owner)

    get "/api/v1/contracts/#{other_contract.id}", headers: auth_headers(@stranger)

    assert_response :not_found
  end

  def test_update_of_other_users_contract_is_not_found_and_does_not_change_data
    other_contract = create_contract(@owner, title: "元のタイトル")

    patch "/api/v1/contracts/#{other_contract.id}", params: { contract: { title: "乗っ取りタイトル" } },
          headers: auth_headers(@stranger), as: :json

    assert_response :not_found
    assert_equal "元のタイトル", other_contract.reload.title
  end

  def test_pdf_of_other_users_contract_is_not_found
    other_contract = create_contract(@owner)

    get "/api/v1/contracts/#{other_contract.id}/pdf", headers: auth_headers(@stranger)

    assert_response :not_found
  end

  # --- update ---

  def test_update_persists_changes_and_records_updated_event
    contract = create_contract(@owner, title: "旧タイトル")

    patch "/api/v1/contracts/#{contract.id}",
          params: { contract: { title: "新タイトル", special_terms: "追記した特記事項" } },
          headers: auth_headers(@owner), as: :json

    assert_response :success
    assert_equal "新タイトル", response.parsed_body["title"]
    assert_equal "新タイトル", contract.reload.title
    assert_equal "updated", contract.contract_events.order(:created_at).last.event
  end

  def test_update_on_signed_contract_is_rejected_with_422
    contract = create_contract(@owner, title: "署名済みタイトル")
    contract.update_columns(status: "signed")

    patch "/api/v1/contracts/#{contract.id}", params: { contract: { title: "書き換え試行" } },
          headers: auth_headers(@owner), as: :json

    assert_response :unprocessable_entity
    assert_equal "署名済みの契約書は変更できません", response.parsed_body["error"]
    assert_equal "署名済みタイトル", contract.reload.title
  end

  # --- destroy ---

  def test_destroy_removes_draft_contract
    contract = create_contract(@owner)

    delete "/api/v1/contracts/#{contract.id}", headers: auth_headers(@owner)

    assert_response :no_content
    refute Contract.exists?(contract.id)
  end

  def test_destroy_rejects_non_draft_contract
    contract = create_contract(@owner)
    contract.issue!(actor: "user:#{@owner.id}")

    delete "/api/v1/contracts/#{contract.id}", headers: auth_headers(@owner)

    assert_response :unprocessable_entity
    assert_equal "下書きの契約書のみ削除できます", response.parsed_body["error"]
    assert Contract.exists?(contract.id)
  end

  # --- issue ---

  def test_issue_creates_share_link_with_thirty_day_expiry
    contract = create_contract(@owner)

    post "/api/v1/contracts/#{contract.id}/issue", headers: auth_headers(@owner)

    assert_response :success
    body = response.parsed_body
    assert_equal "sent", body["status"]
    assert body["share_url"].present?
    assert_includes body["share_url"], "/sign/contracts/"
    assert body["share_expires_at"].present?

    raw_token = body["share_url"].split("/sign/contracts/").last
    found = Contract.find_by_share_token(raw_token)
    assert_equal contract.id, found&.id
    refute contract.reload.share_token_digest.blank?
  end

  def test_reissue_changes_share_token_and_invalidates_previous_one
    contract = create_contract(@owner)

    post "/api/v1/contracts/#{contract.id}/issue", headers: auth_headers(@owner)
    first_token = response.parsed_body["share_url"].split("/sign/contracts/").last

    post "/api/v1/contracts/#{contract.id}/issue", headers: auth_headers(@owner)
    second_token = response.parsed_body["share_url"].split("/sign/contracts/").last

    refute_equal first_token, second_token
    assert_nil Contract.find_by_share_token(first_token), "再発行後は旧トークンで見つからない"
    assert_equal contract.id, Contract.find_by_share_token(second_token)&.id
  end

  # --- duplicate ---

  def test_duplicate_creates_new_draft_without_dates_or_signature
    original = create_contract(@owner,
      title: "運送業務委託契約書", party_a_name: "西野商店", party_b_name: "取引先株式会社",
      contract_date: Date.new(2026, 9, 1), start_on: Date.new(2026, 9, 1), end_on: Date.new(2027, 8, 31))
    original.issue!(actor: "user:#{@owner.id}")
    sign_contract_with_stub!(original, signer_name: "取引先 太郎")

    post "/api/v1/contracts/#{original.id}/duplicate", headers: auth_headers(@owner)

    assert_response :created
    body = response.parsed_body
    assert_equal "draft", body["status"]
    assert_equal "運送業務委託契約書", body["title"]
    assert_equal "西野商店", body["party_a"]["name"]
    assert_equal "取引先株式会社", body["party_b"]["name"]
    assert_nil body["contract_date"]
    assert_nil body["start_on"]
    assert_nil body["end_on"]
    assert_nil body["signer_name"], "複製先には署名者情報が引き継がれない"
    refute body["has_signed_pdf"]

    duplicated_contract = Contract.find(body["id"])
    duplicated_event = duplicated_contract.contract_events.find_by(event: "duplicated")
    assert_equal original.id, duplicated_event.detail["source_contract_id"]
    assert_equal "signed", original.reload.status, "複製元の状態は不変"
  end

  def test_duplicate_of_other_users_contract_is_not_found
    other_contract = create_contract(@owner)

    post "/api/v1/contracts/#{other_contract.id}/duplicate", headers: auth_headers(@stranger)

    assert_response :not_found
  end

  # --- void ---

  def test_void_transitions_sent_contract_to_void_and_records_event
    contract = create_contract(@owner)
    contract.issue!(actor: "user:#{@owner.id}")

    post "/api/v1/contracts/#{contract.id}/void", headers: auth_headers(@owner)

    assert_response :success
    assert_equal "void", response.parsed_body["status"]
    assert_equal "void", contract.reload.status
    assert_equal "voided", contract.contract_events.order(:created_at).last.event
  end

  def test_void_rejects_contract_that_is_not_sent
    contract = create_contract(@owner) # draft のまま

    post "/api/v1/contracts/#{contract.id}/void", headers: auth_headers(@owner)

    assert_response :unprocessable_entity
    assert_equal "送付済みの契約書のみ無効にできます", response.parsed_body["error"]
    assert_equal "draft", contract.reload.status
  end

  # --- pdf ---

  # PDFを実際に生成する(Node/Playwrightを起動する)ケース。認証あり側のpdfアクションで1本のみ。
  def test_pdf_action_returns_generated_pdf_for_draft_contract
    contract = create_contract(@owner)

    get "/api/v1/contracts/#{contract.id}/pdf", headers: auth_headers(@owner)

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match(/inline/, response.headers["Content-Disposition"].to_s)
    assert_equal "%PDF", response.body.byteslice(0, 4)
  end

  def test_pdf_action_returns_stored_signed_pdf_without_regenerating
    contract = create_contract(@owner)
    contract.issue!(actor: "user:#{@owner.id}")
    contract.update_columns(status: "signed", signed_pdf: "%PDF-stored-signed-blob".b)

    get "/api/v1/contracts/#{contract.id}/pdf", headers: auth_headers(@owner)

    assert_response :success
    assert_equal "%PDF-stored-signed-blob", response.body
  end

  private

  def auth_headers(user)
    token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
    { "Authorization" => "Bearer #{token}" }
  end

  def create_contract(user, attrs = {})
    user.contracts.create!({ party_a_name: "甲社" }.merge(attrs))
  end

  # ContractPdfRenderer#call は Node(Playwright)を起動するため遅い。
  # sign! 自体の状態遷移を経由させたいが実PDFは不要なテストで使う一時スタブ。
  def sign_contract_with_stub!(contract, signer_name: "署名者")
    original_call = ContractPdfRenderer.instance_method(:call)
    stub_pdf_path = Rails.root.join("tmp", "contract_controller_test_stub_#{SecureRandom.hex(6)}.pdf").to_s
    File.write(stub_pdf_path, "%PDF-stub")

    ContractPdfRenderer.send(:define_method, :call) { stub_pdf_path }
    contract.sign!(signer_name: signer_name, signature_image: VALID_SIGNATURE_IMAGE)
  ensure
    ContractPdfRenderer.send(:define_method, :call, original_call) if original_call
    File.delete(stub_pdf_path) if stub_pdf_path && File.exist?(stub_pdf_path)
  end
end
