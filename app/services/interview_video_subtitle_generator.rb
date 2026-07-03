# 台本を「テロップ(字幕)」に分割し、強調すべき語句をマークして AI 生成する。
# 返り値: [{ text:, emphasis: (強調する部分文字列 or nil) }, ...]
# タイミング(start/end)は動画の総尺が分かった時点で文字数比例で後付けする(assign_timings)。
class InterviewVideoSubtitleGenerator
  def initialize(user:, script:)
    @user = user
    @script = script.to_s
  end

  def call
    return [] if @script.strip.empty?
    api_key = OpenaiClient.api_key_for(@user)
    data = OpenaiJson.chat_json(system: SYS, user: @script, api_key: api_key, model: "gpt-4o", temperature: 0.3)
    Array(data["segments"]).map do |seg|
      text = seg["text"].to_s.strip
      next if text.empty?
      { "text" => text, "emphasis" => seg["emphasis"].to_s.strip.presence }
    end.compact
  end

  # 総尺(秒)を文字数比例で各セグメントに割り当てる
  def self.assign_timings(segments, total_duration)
    total_chars = segments.sum { |s| s["text"].to_s.length }
    return segments if total_chars.zero? || total_duration.to_f <= 0
    elapsed = 0.0
    segments.map do |seg|
      span = total_duration.to_f * seg["text"].to_s.length / total_chars
      start_at = elapsed.round(2)
      elapsed += span
      seg.merge("start" => start_at, "end" => elapsed.round(2))
    end
  end

  SYS = <<~SYS.freeze
    あなたは動画のテロップ(字幕)編集者です。与えられた台本を、画面に出すテロップ単位に分割します。
    次の JSON で返してください:
    { "segments": [ { "text": "テロップ1行(画面に出す短い文)", "emphasis": "その中で強調する語句(無ければ空文字)" }, ... ] }
    【ルール】
    - 1テロップは読みやすい短さ(目安15〜25文字)。長い文は意味の切れ目で分ける。
    - 台本の文言を変えない。順序も変えない。テロップを全部つなげると元の台本になること。
    - emphasis は各テロップの中で視聴者に一番刺さるキーワードを1つ。
      **「！」が付いている語句・フレーズは必ず emphasis にする**(！は強調の合図)。
      ！が無い場合は数字・成果・転機などのキーワードを emphasis に。無ければ空文字。
    - 句読点はテロップとして自然なら残す。記号の追加はしない。
  SYS
end
