require "test_helper"

# シートヘッダからの人物列の動的検出。
# 人物(大隅/川村/土倉/西野)は拾い、凡例列(タマ/5月)や連番でない数値列は弾くこと。
class TeamScheduleSheetPersonsTest < ActiveSupport::TestCase
  include TeamScheduleSheetPersons

  HEADER_COLUMNS = { 1 => "大隅", 4 => "川村", 7 => "土倉", 10 => "西野", 13 => "タマ", 16 => "5月" }.freeze

  def build_rows
    header = []
    HEADER_COLUMNS.each { |column_index, name| header[column_index] = name }
    rows = [ [], header ]
    (1..31).each do |day|
      row = []
      HEADER_COLUMNS.each_key { |column_index| row[column_index] = day.to_s }
      rows << row
    end
    rows << [ "T合計" ]
    rows
  end

  test "人物列を検出し、タマ・N月の凡例列は除外する" do
    columns = detect_person_columns(build_rows)

    assert_equal %w[大隅 川村 土倉 西野], columns.keys
    assert_equal 3, columns["大隅"], "ステータス列は人名列+2"
    assert_equal 9, columns["土倉"]
  end

  test "日番号が連番でない列は人物とみなさない" do
    rows = build_rows
    rows[1][19] = "稼働時間"
    (2..32).each { |row_index| rows[row_index][19] = "8" }

    columns = detect_person_columns(rows)

    refute_includes columns.keys, "稼働時間"
  end

  test "日番号が無い空列は人物とみなさない" do
    rows = build_rows
    rows[1][19] = "備考"

    columns = detect_person_columns(rows)

    refute_includes columns.keys, "備考"
  end

  test "全角数字の月ラベル(５月)も除外する" do
    rows = build_rows
    rows[1][16] = "５月"

    columns = detect_person_columns(rows)

    refute_includes columns.keys, "５月"
  end

  test "日番号が月途中(15日分)までのシートでも人物を検出できる" do
    header = []
    header[1] = "西野"
    rows = [ [], header ]
    (1..15).each do |day|
      row = []
      row[1] = day.to_s
      rows << row
    end

    columns = detect_person_columns(rows)

    assert_equal({ "西野" => 3 }, columns)
  end
end
