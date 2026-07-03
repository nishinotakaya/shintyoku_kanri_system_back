require "google/apis/sheets_v4"

# 面談質問バンク(Googleスプレッドシート)から「質問・模範回答・深掘り・言い方」を読み込む。
# 列: A=空 / B=質問 / C=模範回答 / D=★ / E=深掘り質問 / F=言い方の注意。
# 質問行だけに絞る（見出し・コーディングテスト・コード断片・空行は除外）。
class InterviewBankImporter
  SHEET_ID = "1l4-WyRfd3bi-kQRO39bnUDOc9QHN2olUuowXdMCPfak".freeze
  # 除外: セクション見出し/区切り/コーディングテスト/コード断片/「回答」単独
  SKIP_RE = /↓|-{3,}|コーディングテスト|生澤|FizzBuzz|【要件】|\A\(|\A回答\z|\Adef\b|each do/
  # 質問らしさ(これらを含む行のみ採用)
  QUESTION_RE = /[？?]|ですか|ください|経験|理由|レベル|長所|短所|魅力|デメリット|何|どう|説明|違い|ありますか|使って|どれくらい/

  def initialize(user:)
    @user = user
  end

  SHORTEN_SYS = <<~SYS.freeze
    各回答を、意味と事実を保ったまま「端的」に短くしてください。多くて2行・最大80字程度・前置きや言い訳は削る。
    教科書的でなく、人が面接で実際に話すような自然な話し言葉(です/ます)にする。盛らない・創作しない。
    入力は [{ "i": 番号, "a": "元の回答" }]。次の JSON で返す: { "answers": [{ "i": 番号, "short": "短くした回答" }] }
  SYS

  def call
    svc = Google::Apis::SheetsV4::SheetsService.new
    svc.authorization = GoogleAuth.build_with_fallback(@user)
    title = svc.get_spreadsheet(SHEET_ID).sheets.first.properties.title
    rows = svc.get_spreadsheet_values(SHEET_ID, "#{title}!A1:F120").values || []
    parsed = rows.filter_map do |r|
      q = r[1].to_s.strip
      next if q.empty? || q.length > 160
      next if q.match?(SKIP_RE)
      next unless q.match?(QUESTION_RE)
      { question: q, answer: r[2].to_s.strip, followup: r[4].to_s.strip, note: r[5].to_s.strip }
    end
    shorten_answers!(parsed)
    parsed
  end

  private

  # 模範回答(answer)を AI で一括で端的に短縮する（1リクエスト）。失敗時は元のまま。
  def shorten_answers!(rows)
    items = rows.each_with_index.filter_map { |r, i| { i: i, a: r[:answer] } if r[:answer].present? }
    return if items.empty?
    data = OpenaiJson.chat_json(
      system: SHORTEN_SYS, user: items.to_json,
      api_key: OpenaiClient.api_key_for(@user), temperature: 0.3
    )
    Array(data["answers"]).each do |x|
      idx = x["i"].to_i
      short = x["short"].to_s.strip
      rows[idx][:answer] = short if rows[idx] && short.present?
    end
  rescue => e
    Rails.logger.warn("[InterviewBankImporter] 回答短縮に失敗: #{e.message}")
  end
end
