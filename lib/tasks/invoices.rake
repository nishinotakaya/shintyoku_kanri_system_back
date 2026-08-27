namespace :invoices do
  desc "請求書の月次自動運転(当月分の作成・勤怠反映・締め後の統合PDF発行)。毎日1回 cron から実行する"
  task auto_generate: :environment do
    result = InvoiceAutoGenerator.run
    puts "作成: #{result.created.size}件"
    result.created.each { |r| puts "  ##{r.id} #{r.user.display_name} #{r.year}/#{r.month} #{r.category}" }
    puts "勤怠反映: #{result.refreshed.size}件"
    result.refreshed.each { |r| puts "  ##{r.id} #{r.user.display_name} #{r.category} → #{r.total_override}円" }
    puts "承認: #{result.approved.size}件"
    puts "統合PDF: #{result.pdfs.size}件"
    result.pdfs.each { |pdf| puts "  ##{pdf[:id]} #{pdf[:filename]} #{pdf[:total]}円" }
  end
end
