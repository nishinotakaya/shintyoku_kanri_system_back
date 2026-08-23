# カード・口座明細の摘要（店名）から勘定科目を推定する。
#
# freee の suggested_account_item は海外サービス(Anthropic/OpenAI 等)ではほぼ空で、
# 付いていても Peatix・LINE・Amazon が「交際費」になるなど当てにならない。
# そのため摘要のパターンで判定し、freee の推奨よりこちらを優先する。
#
# 摘要は口座により全角(ＡＮＴＨＲＯＰＩＣ)・半角・空白混じりで来るため、
# NFKC 正規化 + 空白除去 + 大文字化してから判定する。
#
# 私的支出の可能性があるもの(ゴルフ・美容室など)や借入返済は、
# 誤って経費にしないためあえて判定しない（科目なし＝要確認のまま残す）。
class MerchantCategoryGuesser
  RULES = [
    # 勉強会・セミナー・オンライン講座
    [ /PEATIX|CONNPASS|TECHPLAY|DOORKEEPER|EVENTBRITE|UDEMY|STREETACADEMY|ストアカ|セミナー|勉強会/, "研修費" ],
    # AI・開発ツール・SaaS・通信キャリア
    [ /ANTHROPIC|CLAUDE|OPENAI|CHATGPT|CURSOR|GITHUB|COPILOT|VERCEL|FLY\.IO|HEROKU|AWS|AMAZONWEBSERVICE|
       ZOOM|SLACK|NOTION|FIGMA|CANVA|VREW|ADOBE|GOOGLEONE|GOOGLEWORKSPACE|GOOGLEGSUITE|MICROSOFT|
       XCORP|TWITTER|LINECALLS|LINEMO|KDDI|UQMOBILE|NTTDOCOMO|ドコモ|ソフトバンク|SAKURA|さくらインターネット|
       XSERVER|エックスサーバ|CLOUDFLARE|OPENROUTER/x, "通信費" ],
    # 物販
    [ /AMAZON(?!WEBSERVICE)|ヨドバシ|ビックカメラ|ヤマダデンキ|アスクル|ASKUL|MONOTARO/, "消耗品費" ],
    # 交通
    [ /JR東日本|JR東海|ＪＲ|SUICA|PASMO|ETC|タイムズ|TIMES24|NEXCO|新幹線|航空|ANA|JAL|
       BOOKING\.COM|ブッキング|じゃらん|楽天トラベル/x, "旅費交通費" ],
    # 光熱
    [ /電力|東京ガス|大阪ガス|水道局/, "水道光熱費" ]
  ].freeze

  # description から勘定科目名を返す。判定できなければ nil。
  # ACCOUNT_CATEGORIES に無い名前は返さない。
  def self.call(description)
    text = normalize(description)
    return nil if text.blank?

    _, category = RULES.find { |pattern, _| pattern.match?(text) }
    return nil if category.nil?

    BusinessExpense::ACCOUNT_CATEGORIES.include?(category) ? category : nil
  end

  # 全角英数→半角、空白・記号の除去、大文字化。「ＡＮＴＨＲＯＰＩＣ＊　ＣＬＡＵＤＥ」→「ANTHROPIC*CLAUDE」
  def self.normalize(description)
    description.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, "").upcase
  end
end
