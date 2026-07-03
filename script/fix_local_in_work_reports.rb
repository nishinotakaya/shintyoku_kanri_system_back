# work_reports.content 内の LOCAL-XXX(時間) を実タスク名(時間) に置換するワンショット。
# 本番ではマシン上で実行:
#   fly ssh console -a shintyoku-app -C "/rails/bin/rails runner /rails/script/fix_local_in_work_reports.rb"

updated = 0
total_replaced = 0

WorkReport.where("content LIKE ?", "%LOCAL-%").find_each do |report|
  original = report.content.to_s
  next if original.empty?

  new_content = original.gsub(/LOCAL-[A-Z0-9]+/) do |match|
    local_task = BacklogTask.find_by(issue_key: match)
    if local_task&.summary.present?
      total_replaced += 1
      local_task.summary.gsub(%r{[/()]}, " ").squish[0..30]
    else
      match
    end
  end

  if new_content != original
    report.update_columns(content: new_content)
    updated += 1
    puts "  #{report.id} (#{report.work_date}): #{original} → #{new_content}"
  end
end

puts "Done: #{updated} rows updated, #{total_replaced} LOCAL-keys replaced"
