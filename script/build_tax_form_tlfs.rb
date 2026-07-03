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

  text_block = lambda do |id, x_pt, y_pt, w_pt, size_pt, align, ja|
    {
      "id" => id, "type" => "text-block", "display" => true, "description" => "",
      "x" => x_pt.round(1), "y" => y_pt.round(1),
      "width" => w_pt.round(1), "height" => (size_pt * 1.45).round(1),
      "style" => {
        "font-family" => [ ja ? "IPAMincho" : "Helvetica" ],
        "font-size" => size_pt, "color" => "#000000",
        "text-align" => align.to_s, "vertical-align" => "top",
        "line-height" => "", "line-height-ratio" => "", "letter-spacing" => "",
        "font-style" => [], "overflow" => "truncate", "word-wrap" => "none"
      },
      "reference-id" => "", "value" => "", "multiple-line" => false,
      "format" => { "base" => "", "type" => "" }
    }
  end

  page[:fields].each do |field|
    size_pt = (field[:size] * PX_TO_PT).round(1)
    # HTML overlay の y はラインボックス上端(ハーフレディング込み)で較正済みのため、
    # グリフ上端から描く Prawn では size×0.18 だけ下げて揃える
    items << text_block.call(
      field[:id].to_s,
      field[:x] / 100.0 * page_w,
      field[:y] / 100.0 * page_h + size_pt * 0.18,
      field[:w] / 100.0 * page_w,
      size_pt, field[:align] || :left, field[:ja]
    )
  end

  # コーム欄: マスごとに1桁の text-block を生成する。
  # id は "#{id}_d0"(右端の記入可能マス) 〜、あふれた上位桁用に "#{id}_ov"(幅広マス)。
  # y はマス中心 % → グリフがマスの中心にくるように上端を逆算する。
  # 係数 0.384 = グリフ上端オフセット0.048 + 数字グリフ高さ0.672/2（150dpiレンダ実測値）
  (page[:combs] || []).each do |comb|
    size_pt = (comb[:size] * PX_TO_PT).round(1)
    pitch_pt = comb[:pitch] / 100.0 * page_w
    y_pt = comb[:y] / 100.0 * page_h - size_pt * 0.384
    fillable = comb[:cells] - comb.fetch(:skip, 0)
    fillable.times do |i|
      center_x = (comb[:x_right] - (comb.fetch(:skip, 0) + i) * comb[:pitch]) / 100.0 * page_w
      items << text_block.call("#{comb[:id]}_d#{i}", center_x - pitch_pt / 2, y_pt, pitch_pt, size_pt, :center, false)
    end
    if (overflow = comb[:overflow])
      w_pt = overflow[:w] / 100.0 * page_w
      x_pt = overflow[:x] / 100.0 * page_w - w_pt / 2
      items << text_block.call("#{comb[:id]}_ov", x_pt, y_pt, w_pt, size_pt, :center, false)
    end
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
