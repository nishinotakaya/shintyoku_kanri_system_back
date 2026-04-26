require "fileutils"

# 生成した PDF/Excel をローカルの指定フォルダに保存する。
# このアプリはローカル運用なので、Rails から直接ユーザーの書類ディレクトリへ書き出す。
class LocalFileSaver
  BASE = ENV.fetch("LOCAL_SAVE_BASE_DIR", File.join(Dir.home, "請求書類")).freeze

  CATEGORY_FOLDER = {
    "wings" => "TAMA",
    "living" => "Living",
    "techleaders" => "テックリーダーズ",
    "resystems" => "REシステムズ"
  }.freeze

  class << self
    def save(type:, src_path:, filename:, category: nil, year: nil, month: nil, user: nil)
      folder = build_folder(type: type, category: category, year: year, month: month, user: user)
      FileUtils.mkdir_p(folder)
      dest = File.join(folder, filename)
      FileUtils.cp(src_path, dest)
      dest
    end

    # ユーザーの local_save_dir が設定されていれば優先（{year}/{month}/{cat}/{name} 展開可、末尾に {month}月 自動付与）
    # 例: "/Users/.../{year}年/川村さん/{cat}/業務報告書:請求書"
    #     → "/Users/.../2026年/川村さん/TAMA/業務報告書:請求書/4月"
    def build_folder(type:, category:, year:, month:, user: nil)
      cat_folder = CATEGORY_FOLDER[category.to_s] || "TAMA"
      y = year || Date.current.year
      m = month || Date.current.month

      if user&.local_save_dir.present? && type.to_sym != :purchase_order
        base = expand_template(user.local_save_dir, year: y, month: m, cat: cat_folder, user: user)
        # 末尾に {month}月 が含まれていなければ自動で付与
        return base.include?("#{m}月") ? base : File.join(base, "#{m}月")
      end

      case type.to_sym
      when :purchase_order
        "#{BASE}/#{y}年/川村さん/#{cat_folder}/注文書"
      when :invoice, :work_report, :expense
        "#{BASE}/#{y}年/#{cat_folder}/請求書/#{m}月"
      else
        raise "unknown type: #{type}"
      end
    end

    def expand_template(tpl, year:, month:, cat:, user:)
      tpl.to_s
         .gsub("{year}", year.to_s)
         .gsub("{month}", month.to_s)
         .gsub("{cat}", cat.to_s)
         .gsub("{name}", user&.display_name.to_s)
    end
  end
end
