# TaxFormTlfLayouts の座標定義から Thinreports レイアウト(.tlf)を生成する。
# 実行: bin/rails runner script/build_tax_form_tlfs.rb
# 出力: app/reports/tax_forms/tlf/*.tlf （白紙様式PNGを背景に埋め込み済み）
#
# 生成後は Thinreports Editor で開いて位置を手調整できる。
# ただし再実行すると Editor での調整は上書きされる。
require "base64"
require "json"

A4_PORTRAIT  = [ 595.28, 841.89 ].freeze # pt
PX_TO_PT     = 0.75                      # overlay px (96dpi基準) → pt

forms_dir = Rails.root.join("app/reports/tax_forms")
out_dir   = forms_dir.join("tlf")
FileUtils.mkdir_p(out_dir)

TaxFormTlfLayouts.pages.each do |key, page|
  landscape = page[:orientation] == "landscape"
  page_w, page_h = landscape ? A4_PORTRAIT.reverse : A4_PORTRAIT

  items = []
  items << {
    "id" => "", "type" => "image", "display" => true, "description" => "",
    "x" => 0.0, "y" => 0.0, "width" => page_w, "height" => page_h,
    "data" => {
      "mime-type" => "image/png",
      "base64" => Base64.strict_encode64(File.binread(forms_dir.join(page[:image])))
    }
  }

  page[:fields].each do |field|
    size_pt = (field[:size] * PX_TO_PT).round(1)
    items << {
      "id" => field[:id].to_s, "type" => "text-block", "display" => true, "description" => "",
      "x" => (field[:x] / 100.0 * page_w).round(1),
      # HTML overlay の y はラインボックス上端(ハーフレディング込み)で較正済みのため、
      # グリフ上端から描く Prawn では size×0.18 だけ下げて揃える
      "y" => (field[:y] / 100.0 * page_h + size_pt * 0.18).round(1),
      "width" => (field[:w] / 100.0 * page_w).round(1),
      "height" => (size_pt * 1.45).round(1),
      "style" => {
        "font-family" => [ field[:ja] ? "IPAMincho" : "Helvetica" ],
        "font-size" => size_pt, "color" => "#000000",
        "text-align" => (field[:align] || :left).to_s, "vertical-align" => "top",
        "line-height" => "", "line-height-ratio" => "", "letter-spacing" => "",
        "font-style" => [], "overflow" => "truncate", "word-wrap" => "none"
      },
      "reference-id" => "", "value" => "", "multiple-line" => false,
      "format" => { "base" => "", "type" => "" }
    }
  end

  tlf = {
    "version" => "0.12.0",
    "items" => items,
    "state" => { "layout-guides" => [] },
    "title" => key.to_s,
    "report" => {
      "paper-type" => "A4",
      "orientation" => page[:orientation],
      "margin" => [ 0, 0, 0, 0 ]
    }
  }
  path = out_dir.join("#{key}.tlf")
  File.write(path, JSON.pretty_generate(tlf))
  puts "wrote #{path} (#{page[:fields].size} fields)"
end
