# 受領Excel(xlsm)「プロジェクトのスケジュール」シートのヘッダ情報を読み取る。
#   B1 = プロジェクト名 / B2 = 会社名 / G3 = プロジェクト開始日(Excelシリアル値)
# zip/XML の読み取りは WbsExcelDocument を共有する(NotionWbsExcelUpdater と重複実装しない)。
# 読めない場合は各項目 nil を返す(エクスポート時に G3 自体を書き換えることはない)。
class WbsScheduleHeaderReader
  EXCEL_EPOCH       = Date.new(1899, 12, 30) # Excel のシリアル値起点(1900年うるう年バグ込み)
  MIN_VALID_SERIAL  = 1
  MAX_VALID_SERIAL  = 2_958_465 # Excel が扱える最大の日付(9999-12-31)のシリアル値

  def initialize(bytes)
    @bytes = bytes
  end

  def call
    @document = WbsExcelDocument.new(@bytes)
    { project_title: text_at("B1"), company_name: text_at("B2"), project_start: date_at("G3") }
  rescue StandardError
    { project_title: nil, company_name: nil, project_start: nil }
  end

  private

  def text_at(cell_reference)
    @document.cell_text_value(@document.cell_at(cell_reference)).presence
  end

  def date_at(cell_reference)
    text = @document.cell_text_value(@document.cell_at(cell_reference))
    serial = Float(text, exception: false)
    return nil if serial.nil? || !serial.between?(MIN_VALID_SERIAL, MAX_VALID_SERIAL)

    (EXCEL_EPOCH + serial.to_i).to_s
  end
end
