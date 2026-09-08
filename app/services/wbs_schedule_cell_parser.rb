# 受領Excel(xlsm)「プロジェクトのスケジュール」シートの E〜H列(進捗率・工数・開始日・終了日)の
# セル文字列(数値文字列・Excelシリアル値・日付文字列)を Ruby の値へ変換し、同値判定も行う共通処理。
# NotionWbsExcelImporter(取込)・WbsTemplateValuesReader(テンプレ読取)・NotionTask(赤塗り判定)の
# 3箇所でパース規則を重複実装しないために切り出す。
module WbsScheduleCellParser
  EXCEL_EPOCH       = Date.new(1899, 12, 30) # Excel のシリアル値起点(1900年うるう年バグ込み)
  DATE_TEXT_PATTERN = /\A\d{4}[-\/]\d{1,2}[-\/]\d{1,2}\z/

  module_function

  # kind: :rate/:number は Float、:date は Date に変換する。空・不正な値は nil。
  def parse_cell_value(kind, text)
    case kind
    when :rate, :number
      Float(text, exception: false)
    when :date
      parse_date_cell(text)
    end
  end

  def parse_date_cell(text)
    return nil if text.blank?

    serial = Float(text, exception: false)
    return EXCEL_EPOCH + serial.to_i if serial

    stripped = text.to_s.strip
    return nil unless stripped.match?(DATE_TEXT_PATTERN)

    Date.parse(stripped)
  rescue ArgumentError
    nil
  end

  # kind に応じた同値判定(:rate/:number は to_f 同士。進捗率は小数第4位で丸めて比較。:date は Date 同士)。
  # nil 同士は「同じ」、片方だけ nil は「異なる」として扱う。
  def values_equal?(kind, left_value, right_value)
    return true if left_value.nil? && right_value.nil?
    return false if left_value.nil? || right_value.nil?

    case kind
    when :rate
      left_value.to_f.round(4) == right_value.to_f.round(4)
    when :number
      left_value.to_f == right_value.to_f
    when :date
      left_value == right_value
    end
  end
end
