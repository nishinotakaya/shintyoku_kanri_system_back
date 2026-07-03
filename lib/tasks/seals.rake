require "base64"

# 既存の public/hanko_* と新規アップロード分を、各ユーザーの users.seal_image(data URL) に取り込む。
# 既に seal_image が入っているユーザーは上書きしない(設定で各自が変えた分を壊さない)。
# 再実行可能。 使い方: bin/rails seals:import
namespace :seals do
  desc "public/hanko_* を各ユーザーの seal_image(data URL) に取り込む"
  task import: :environment do
    mapping = {
      "西野" => "hanko_nishino.png",
      "川村" => "hanko_kawamura.svg",
      "須崎" => "hanko_susaki.png"
    }
    mapping.each do |surname, file|
      path = Rails.root.join("public", file)
      unless File.exist?(path)
        puts "skip #{surname}: file not found #{file}"
        next
      end
      user = User.where("display_name LIKE ?", "#{surname}%").order(:id).first
      unless user
        puts "skip #{surname}: user not found"
        next
      end
      if user.seal_image.present?
        puts "skip #{user.display_name}(##{user.id}): already has seal_image"
        next
      end
      mime = file.end_with?(".svg") ? "image/svg+xml" : "image/png"
      data_url = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
      user.update!(seal_image: data_url)
      puts "set seal for #{user.display_name}(##{user.id}) from #{file} (#{data_url.length} bytes)"
    end
  end
end
