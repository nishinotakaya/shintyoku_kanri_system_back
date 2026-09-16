# マイナンバー(個人番号)の正規化・検証を行う値オブジェクト。
# 個人番号そのものは users.my_number(暗号化)にしか持たせず、保存前の整形と
# 桁数・チェックデジットの検証をここに一本化する(表記ゆれ・誤読の混入を防ぐ)。
module MyNumber
  DIGIT_COUNT = 12

  # 全角数字→半角に揃え、数字以外を除去した文字列を返す。
  # 空になった場合は nil (12桁ちょうどかどうかは valid? 側で判定する)。
  def self.normalize(raw)
    return nil if raw.blank?
    cleaned = raw.to_s.tr("０-９", "0-9").gsub(/[^0-9]/, "")
    cleaned.presence
  end

  # 12桁かつチェックデジットが一致するか。
  # チェックデジットは番号法施行令の式に基づく:
  #   上位11桁を P1..P11(左から) とし、右からの位置 n(=1..11。P11がn=1) の重みを
  #   Q_n = n+1 (n<=6) / n-5 (n>=7) として remainder = Σ(P_n × Q_n) mod 11 を求める。
  #   check = remainder <= 1 ? 0 : 11 - remainder が12桁目と一致すれば有効。
  def self.valid?(digits)
    return false if digits.blank?
    return false unless digits.match?(/\A\d{#{DIGIT_COUNT}}\z/)

    digits[-1].to_i == check_digit_for(digits[0, 11])
  end

  # 末尾4桁(表示・ログ用)。個人番号全体は表示・ログに出さないためこちらを使う。
  def self.last4(digits)
    return nil if digits.blank?
    digits.to_s[-4, 4]
  end

  def self.check_digit_for(first_eleven_digits)
    # chars.reverse で P11, P10, ..., P1 の順に並ぶ = index 0 が n=1 の重みを掛ける対象
    remainder = first_eleven_digits.chars.reverse.each_with_index.sum do |digit_char, index|
      n = index + 1
      weight = n <= 6 ? n + 1 : n - 5
      digit_char.to_i * weight
    end % 11

    remainder <= 1 ? 0 : 11 - remainder
  end
  private_class_method :check_digit_for
end
