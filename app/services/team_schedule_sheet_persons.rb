# 勤怠スケジュールシートの2行目ヘッダから「人物」列を動的に検出する共通処理。
# 取込(TeamScheduleImporter)と書き戻し(TeamScheduleExporter)で同じ判定を使う。
#
# シートには「タマ」(全体予定の空列)や「5月」(祝日凡例)のような人物でない列も
# 同じ3列組(日/曜/ステータス)で並んでいるため、
#   1) 名前の除外パターン(タマ・N月)で弾く
#   2) ヘッダ直下(3行目以降)に日番号が 1 から連番で並ぶ列だけを人物列とみなす
# の2段で判定する。人物がシートに追加されたら、コード変更なしで取込対象になる。
module TeamScheduleSheetPersons
  # 「タマ」(全体予定) と「5月」「５月」等の月ラベル(全角数字含む)は人物ではない
  NON_PERSON_HEADER = /\A(タマ|[0-9０-９]{1,2}月)\z/

  # rows: シート全体の値(1行目=タイトル, 2行目=人名ヘッダ, 3行目以降=日別データ)
  # 返り値: { 人名 => ステータス列(0-indexed) } ※人名列 +2 がステータス列
  def detect_person_columns(rows)
    header = rows[1] || []
    header.each_with_index.filter_map { |cell, column_index|
      person_name = cell.to_s.strip
      next if person_name.empty? || person_name.match?(NON_PERSON_HEADER)
      next unless day_number_column?(rows, column_index)
      [ person_name, column_index + 2 ]
    }.to_h
  end

  private

  # ヘッダ直下(3行目以降)に日番号が 1 から連番で並ぶ列か。
  # 月途中までしか日番号が入っていないシートも拾えるよう 15 日分あれば良しとし、
  # 集計行(T合計等)より下に紛れた数値に引きずられないよう、先頭15個の連番だけ確認する
  MIN_DAY_NUMBERS = 15

  def day_number_column?(rows, column_index)
    day_numbers = (2...rows.size).filter_map { |row_index|
      value = (rows[row_index] || [])[column_index].to_s.strip
      value.to_i if value.match?(/\A\d{1,2}\z/)
    }
    return false if day_numbers.size < MIN_DAY_NUMBERS || day_numbers.first != 1
    day_numbers.first(MIN_DAY_NUMBERS).each_cons(2).all? { |previous_day, next_day| next_day == previous_day + 1 }
  end
end
