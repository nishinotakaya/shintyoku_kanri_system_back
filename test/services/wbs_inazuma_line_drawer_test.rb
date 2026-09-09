require "test_helper"
require "zip"
require "stringio"

# WbsInazumaLineDrawer: 「プロジェクトのスケジュール」のガント上のイナズマ線を、
# VBA(DrawInazumaLine)と同じ点の決定ロジックで描画パーツ(drawing1.xml)に引き直す。
# フィクスチャの日付行は K5=46244(2026-08-10) から 1 日刻み。データ行は 8〜12 行目(13 行目は空)。
class WbsInazumaLineDrawerTest < Minitest::Test
  TEMPLATE_PATH = Rails.root.join("test/fixtures/files/wbs_schedule_template.xlsm")
  DRAWING_PATH  = "xl/drawings/drawing1.xml".freeze
  XDR_NS = { "xdr" => "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing",
             "a" => "http://schemas.openxmlformats.org/drawingml/2006/main" }.freeze
  GANTT_COLUMN_HALF_WIDTH_EMU = (2.42578125 * 7.0 * 12_700 / 2).round # 列幅 2.42578125 文字 → 半分
  ROW_HALF_HEIGHT_EMU = 30 * 12_700 / 2                                 # 行高 30pt → 半分

  def setup
    @document = WbsExcelDocument.new(File.binread(TEMPLATE_PATH))
  end

  # 基準日 2026-09-09(シリアル 46274)。行ごとの点:
  #   8行目 設計(日付なし)            → ① 基準日        → 46274 = K+30 → 41列目
  #   9行目 1.1 (0.5, 46266〜46275)   → ⑤ 46270.5      → 46271 = K+27 → 38列目
  #  10行目 1.2 (1.0, 終了 46272<基準) → ② 基準日        → 41列目
  #  11行目 開発(日付なし)            → ① 基準日        → 41列目
  #  12行目 2.1.1 (0, 開始 46280>基準) → ④ 基準日        → 41列目
  def test_draws_segments_between_consecutive_task_rows
    segment_count = WbsInazumaLineDrawer.new(document: @document, base_date: Date.new(2026, 9, 9)).call
    anchors = line_anchors

    assert_equal 4, segment_count
    assert_equal 4, anchors.size

    first = anchor_geometry(anchors[0])
    assert_equal({ from_col: 37, from_row: 7, to_col: 40, to_row: 8, flip_h: true }, first.slice(:from_col, :from_row, :to_col, :to_row, :flip_h))
    assert_equal GANTT_COLUMN_HALF_WIDTH_EMU, first[:from_col_off]
    assert_equal ROW_HALF_HEIGHT_EMU, first[:from_row_off]

    second = anchor_geometry(anchors[1])
    assert_equal({ from_col: 37, from_row: 8, to_col: 40, to_row: 9, flip_h: false }, second.slice(:from_col, :from_row, :to_col, :to_row, :flip_h))

    vertical = anchor_geometry(anchors[2])
    assert_equal({ from_col: 40, from_row: 9, to_col: 40, to_row: 10, flip_h: false }, vertical.slice(:from_col, :from_row, :to_col, :to_row, :flip_h))
  end

  # テンプレに残っていた古い線(174本)は消し、ガント領域外の図形(CSV取込ボタン)は残す
  def test_replaces_old_lines_and_keeps_other_shapes
    assert_equal 174, line_anchors.size

    WbsInazumaLineDrawer.new(document: @document, base_date: Date.new(2026, 9, 9)).call

    assert_equal 4, line_anchors.size
    button = drawing_document.at_xpath("//xdr:sp//xdr:cNvPr[@name='Button 1']", XDR_NS)
    refute_nil button
    ids = drawing_document.xpath("//xdr:cNvPr/@id", XDR_NS).map(&:value)
    assert_equal ids.uniq.size, ids.size, "図形 ID が重複している"
  end

  # 線の色・太さは VBA と同じ(赤 RGB(255,0,0)・2pt = 25400 EMU)
  def test_line_style_matches_macro
    WbsInazumaLineDrawer.new(document: @document, base_date: Date.new(2026, 9, 9)).call
    line = line_anchors.first.at_xpath(".//a:ln", XDR_NS)

    assert_equal "25400", line["w"]
    assert_equal "FF0000", line.at_xpath("a:solidFill/a:srgbClr", XDR_NS)["val"]
  end

  # 基準日がガント終端より後でも、日付行に該当列が無い点はガント開始列(K)に置く(VBA と同じフォールバック)
  def test_falls_back_to_gantt_start_column_when_date_is_beyond_header
    WbsInazumaLineDrawer.new(document: @document, base_date: Date.new(2030, 1, 1)).call
    first = anchor_geometry(line_anchors[0])

    assert_equal 10, first[:from_col] # 8行目(設計)の点 = K列(0始まりで 10)
  end

  # 描画パーツを持たないシートでは何もしない
  def test_noop_without_drawing_part
    @document.entries.delete("xl/worksheets/_rels/sheet2.xml.rels")

    assert_equal 0, WbsInazumaLineDrawer.new(document: @document, base_date: Date.new(2026, 9, 9)).call
  end

  private

  def drawing_document
    Nokogiri::XML(@document.entries.fetch(DRAWING_PATH))
  end

  def line_anchors
    drawing_document.xpath("//xdr:twoCellAnchor[xdr:cxnSp]", XDR_NS)
  end

  def anchor_geometry(anchor)
    from = anchor.at_xpath("xdr:from", XDR_NS)
    to   = anchor.at_xpath("xdr:to", XDR_NS)
    {
      from_col: from.at_xpath("xdr:col", XDR_NS).text.to_i, from_col_off: from.at_xpath("xdr:colOff", XDR_NS).text.to_i,
      from_row: from.at_xpath("xdr:row", XDR_NS).text.to_i, from_row_off: from.at_xpath("xdr:rowOff", XDR_NS).text.to_i,
      to_col: to.at_xpath("xdr:col", XDR_NS).text.to_i, to_row: to.at_xpath("xdr:row", XDR_NS).text.to_i,
      flip_h: anchor.at_xpath(".//a:xfrm", XDR_NS)["flipH"] == "1"
    }
  end
end
