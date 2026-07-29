# 設定画面の「ペルソナ・事業内容(video_script_context)」を AI プロンプトへ載せる形に整える。
#
# 実運用ではこの欄に過去の YouTube 台本が丸ごと貼られていることがある。
# それを「最重要。これを軸に語らせる」というラベルで渡すと、AI は動画タイトルより貼られた台本を優先し、
# 過去台本のテーマをほぼ複製したカンペを返す
# (例: タイトル「【元介護士】スキルも学歴もゼロから、月収70万エンジニアへ変わった」に対し、
#  企画コールが「独学でエンジニアになれない理由5選」になる事故が発生した)。
# そのため過去台本と判定したときはラベルを「トーンと事実の出典」に格下げし、テーマ流用を明示的に禁止する。
class PersonaContext
  # 西野式テンプレートの見出し。ペルソナ説明文には普通現れないので、台本判定のマーカーに使う。
  SCRIPT_MARKERS = [
    "企画コール", "要点内容", "LINE誘導", "アウトプット誘導",
    "最悪の未来", "ターゲット指定", "大きな問題定義", "要点まとめ", "台本"
  ].freeze
  # 3 つ以上一致したら「これはプロフィールではなく台本」とみなす。
  PAST_SCRIPT_THRESHOLD = 3

  def initialize(text)
    @text = text.to_s
  end

  def present? = @text.strip.present?

  def past_script?
    SCRIPT_MARKERS.count { |marker| @text.include?(marker) } >= PAST_SCRIPT_THRESHOLD
  end

  # プロンプトに差し込む1ブロック。内容が無ければ nil。
  def prompt_block
    return nil unless present?

    past_script? ? past_script_block : persona_block
  end

  private

  def persona_block
    "【ペルソナ・プロフィール・事業内容(最重要。これを軸に語らせる)】\n#{@text}"
  end

  def past_script_block
    <<~BLOCK
      【参考資料: 本人の過去動画の台本(今回とは別テーマ)】
      ※使ってよいのは次の2つだけ: (1) 本人の話し方・言い回しのトーン (2) 経歴・数字・実績などの事実。
      ※流用は禁止: この台本のテーマ・企画名・要点(お題)・具体例・最終まとめ・無料プレゼント名。
      　今回話すテーマは【動画タイトル/テーマ】に書かれた内容だけです。過去台本のテーマに寄せたら失敗とみなします。
      #{@text}
    BLOCK
  end
end
