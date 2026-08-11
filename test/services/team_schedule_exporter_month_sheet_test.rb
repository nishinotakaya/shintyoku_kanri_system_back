require "test_helper"

# 新規月シート作成時の日付スケルトン([日, 曜, 空ステータス] × 31行)の生成。
class TeamScheduleExporterMonthSheetTest < ActiveSupport::TestCase
  def setup
    @admin = User.create!(email: "admin_#{SecureRandom.hex(4)}@example.com",
                          password: "password123", display_name: "西野 鷹也", closing_day: 25)
    @exporter = TeamScheduleExporter.new(user: @admin, year: 2027, month: 1)
  end

  def teardown
    @admin&.destroy
  end

  def test_month_day_rows_for_january_2027
    rows = @exporter.send(:month_day_rows, 2027, 1)

    assert_equal 31, rows.size
    assert_equal [ 1, "金", "" ], rows.first, "2027-01-01 は金曜"
    assert_equal [ 31, "日", "" ], rows.last
  end

  def test_month_day_rows_pads_short_months_with_blanks
    rows = @exporter.send(:month_day_rows, 2027, 2)

    assert_equal 31, rows.size
    assert_equal [ 28, "日", "" ], rows[27], "2027-02-28 は日曜"
    assert_equal [ [ "", "", "" ] ] * 3, rows[28..30], "29〜31日の行は空にする"
  end

  def test_latest_month_sheet_before_picks_nearest_earlier_sheet
    sheets = %w[202611 202612 202502].map { |title|
      Google::Apis::SheetsV4::Sheet.new(
        properties: Google::Apis::SheetsV4::SheetProperties.new(title: title, sheet_id: title.to_i)
      )
    }
    spreadsheet = Google::Apis::SheetsV4::Spreadsheet.new(sheets: sheets)

    template = @exporter.send(:latest_month_sheet_before, spreadsheet, "202701")

    assert_equal "202612", template.properties.title
  end
end
