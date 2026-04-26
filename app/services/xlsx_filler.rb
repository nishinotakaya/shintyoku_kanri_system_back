require "json"
require "open3"
require "fileutils"

# Python (openpyxl) を呼んで既存テンプレートのセル値だけ差し替える。
# rubyXL のスタイル再書き出しを避け、テンプレート完全保持を保証する。
class XlsxFiller
  SCRIPT = Rails.root.join("lib/exporters/fill_xlsx.py")

  def self.call(template:, output:, sheet: 0, cells: [], sheet_name: nil, header_date: nil)
    FileUtils.mkdir_p(File.dirname(output))
    payload = { sheet: sheet, cells: cells }
    payload[:sheet_name] = sheet_name if sheet_name
    payload[:header_date] = header_date if header_date
    out, err, status = Open3.capture3("python3", SCRIPT.to_s, template.to_s, output.to_s, payload.to_json)
    raise "fill_xlsx.py failed: #{err}" unless status.success?
    output
  end
end
