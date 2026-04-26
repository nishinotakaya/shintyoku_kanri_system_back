class WorkReportCommandParser
  SCHEMA = {
    type: "object",
    properties: {
      ops: {
        type: "array",
        items: {
          type: "object",
          properties: {
            from:    { type: "string", description: "ISO date YYYY-MM-DD" },
            to:      { type: "string", description: "ISO date YYYY-MM-DD" },
            hours:   { type: ["number", "null"] },
            content: { type: ["string", "null"], description: "作業内容。SAP-XXXX(時間) 形式は大文字" }
          },
          required: ["from", "to", "hours", "content"],
          additionalProperties: false
        }
      }
    },
    required: ["ops"],
    additionalProperties: false
  }.freeze

  def initialize(text:, user: nil, base_date: Date.current, selected_range: nil)
    @text = text.to_s
    @user = user
    @base_date = base_date
    @selected_range = selected_range
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    raise "OpenAI API key 未設定。設定画面から登録してください。" unless api_key.present?

    res = OpenaiClient.client(@user).chat(parameters: {
      model: OpenaiClient.chat_model,
      messages: [
        { role: "system", content: system_prompt },
        { role: "user", content: @text }
      ],
      response_format: {
        type: "json_schema",
        json_schema: { name: "work_report_ops", schema: SCHEMA, strict: true }
      }
    })
    json = res.dig("choices", 0, "message", "content")
    parsed = JSON.parse(json, symbolize_names: true)
    parsed[:ops] = (parsed[:ops] || []).map(&:compact)
    parsed
  end

  private

  def system_prompt
    <<~PROMPT
      あなたは勤怠アプリの自然言語コマンドを構造化JSONに変換するアシスタントです。
      今日の日付: #{@base_date.iso8601}
      現在の選択範囲: #{@selected_range || "なし"}

      ルール:
      - 「3日〜6日」など月省略は今日の年・月を補完する
      - 「sap-3333で2時間」 → content="SAP-3333(2)", hours=2
      - 「sap-3333(8)」     → content="SAP-3333(8)", hours=8
      - チケット名は大文字化、括弧は半角
      - 範囲が明示されない場合は selected_range を使う。それも無ければ from=to=今日
      - 工数指定がなければ hours は null、業務内容指定がなければ content は null
      - 「全て」「すべて」は範囲全日への一括適用を意味する
    PROMPT
  end
end
