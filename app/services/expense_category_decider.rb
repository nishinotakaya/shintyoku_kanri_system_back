# 経費の勘定科目を決める唯一の入口。
#   ① 摘要ルール(MerchantCategoryGuesser) … 実データで検証済みなので最優先。AI 呼び出しも節約できる
#   ② AI(TransactionCategorizer)          … ルールに無い店・海外SaaS・摘要だけでは分かりにくいもの
#   ③ 呼び出し側が持つ予備の科目           … ①②が決められなかったときだけ(freee の推奨科目など)
#
# freee の推奨科目を③に置いているのは、Peatix/LINE/Amazon を「交際費」にするなど当てにならず、
# 海外SaaS(Anthropic/OpenAI等)ではそもそも空だから。AI に決めさせる方が当たる。
#
# AI 呼び出しはルールで決まらなかった行だけを 1 リクエストにまとめる。
class ExpenseCategoryDecider
  # AI の確信度がこれ未満なら、科目は入れるが「要確認」にして人の目に掛ける
  CONFIDENT_THRESHOLD = 70

  Decision = Struct.new(:account_category, :confidence, :source, keyword_init: true) do
    def decided? = account_category.present?

    # 科目が決まらなかった / 決め手が弱かった行は要確認に回す
    def needs_review? = !decided? || confidence.to_i < CONFIDENT_THRESHOLD

    def by_ai? = source == "ai"
  end

  # rows: [{ date:, description:, amount:, fallback_category: (省略可) }]
  # 戻り値: rows と同じ順・同じ件数の Decision 配列
  def self.call(rows)
    new(rows).call
  end

  def initialize(rows)
    @rows = Array(rows)
  end

  def call
    decisions = @rows.map { |row| rule_decision(row[:description]) }
    pending = decisions.each_index.reject { |index| decisions[index].decided? }
    apply_ai(decisions, pending) if pending.any?
    pending.each { |index| decisions[index] = fallback_decision(@rows[index]) unless decisions[index].decided? }
    decisions
  end

  private

  def rule_decision(description)
    category = MerchantCategoryGuesser.call(description)
    Decision.new(account_category: category, confidence: category ? 100 : 0, source: category && "rule")
  end

  # AI が落ちても登録自体は通したいので、例外はログに残して「決まらなかった」扱いにする。
  def apply_ai(decisions, pending)
    rows = pending.map { |index| @rows[index].slice(:date, :description, :amount) }
    results = TransactionCategorizer.call(rows)
    pending.each_with_index do |index, position|
      result = results[position] || {}
      category = known_category(result[:account_category])
      next if category.nil?
      decisions[index] = Decision.new(account_category: category, confidence: result[:confidence].to_i, source: "ai")
    end
  rescue => e
    Rails.logger.warn("[ExpenseCategoryDecider] AI分類に失敗したため要確認で残します: #{e.class}: #{e.message}")
  end

  def fallback_decision(row)
    category = known_category(row[:fallback_category])
    Decision.new(account_category: category, confidence: 0, source: category && "fallback")
  end

  def known_category(name)
    BusinessExpense::ACCOUNT_CATEGORIES.include?(name.to_s) ? name.to_s : nil
  end
end
