# onclass のリサーチ結果(高再生タイトルの傾向)＋出演者のペルソナ/スキルシートから、
# クリックしたくなる YouTube 動画タイトル案を複数生成する。
# 返り値: ["タイトル案1", "タイトル案2", ...]
class YoutubeTitleSuggester
  SYS = <<~SYS.freeze
    あなたはIT/プログラミング系YouTubeチャンネルの企画・タイトル設計のプロです。
    出演者本人が語るインタビュー/解説動画の「クリックされるタイトル案」を複数作ります。
    次の JSON で返してください: { "titles": ["タイトル案1", "タイトル案2", ...] }  ※8個。

    【最重要】与えられる「高再生タイトルの傾向(自チャンネル/競合)」の"型"を学び、それを応用する。
    - 伸びている型の例: 「数字＋衝撃(9割が消える等)」「AI時代/未経験の不安に刺さる」「◯つのポイント/ロードマップ」
      「ぶっちゃけ/本当の理由/現実」など、視聴者の悩み・本音に刺さる言葉。
    - ただし丸パクリはしない。出演者本人の事実(スキルシート/ペルソナ)に沿った内容にする。
    【ルール】
    - 事実に無い経歴・数字・肩書きを創作しない。盛らない。
    - 1本ずつ切り口を変える(不安訴求 / ノウハウ / 体験談 / ロードマップ / ぶっちゃけ本音 など)。
    - 日本語で、全角32字以内を目安に端的に。過度な煽り・誇大表現・釣りだけの中身なしは避ける。
    - IT副業/プログラミング学習/エンジニア転職の文脈を外さない。
  SYS

  # user: OpenAI キー解決 & ペルソナ / theme: 任意の切り口・キーワード
  def initialize(user:, persona_user: nil, theme: nil)
    @user = user
    @persona_user = persona_user || user
    @theme = theme.to_s.strip
    @sheet = @persona_user.skill_sheet || user.skill_sheet
  end

  def call
    api_key = OpenaiClient.api_key_for(@user)
    data = OpenaiJson.chat_json(system: SYS, user: prompt, api_key: api_key, model: "gpt-4o", temperature: 0.85)
    Array(data["titles"]).map { |t| t.to_s.strip }.reject(&:empty?).first(8)
  end

  private

  def prompt
    parts = []
    parts << "【出演者】#{@persona_user.display_name}"
    parts << "【動画の切り口・キーワード(任意)】#{@theme}" if @theme.present?
    if @persona_user.respond_to?(:video_script_context) && @persona_user.video_script_context.present?
      parts << "【ペルソナ・事業内容(最重要。これを軸に)】\n#{@persona_user.video_script_context}"
    end
    parts << "【スキルシート(事実の出典)】\n#{sheet_summary}"
    research = YoutubeResearchReader.cached_summary
    parts << "【高再生タイトルの傾向(参考にする実データ)】\n#{research}" if research.present?
    parts << "\n上記をふまえ、この出演者が語る動画としてクリックされるタイトル案を8個作ってください。"
    parts.join("\n")
  end

  def sheet_summary
    return "（スキルシート情報なし）" unless @sheet
    lines = []
    lines << "得意技術: #{@sheet.skills}" if @sheet.skills.present?
    lines << "得意分野: #{@sheet.specialties}" if @sheet.respond_to?(:specialties) && @sheet.specialties.present?
    lines << "自己PR: #{(@sheet.youtube_self_pr.presence || @sheet.self_pr).to_s.slice(0, 500)}" if (@sheet.respond_to?(:youtube_self_pr) && @sheet.youtube_self_pr.present?) || @sheet.self_pr.present?
    lines.join("\n").presence || "（スキルシート情報なし）"
  end
end
