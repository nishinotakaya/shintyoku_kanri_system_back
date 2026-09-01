# 「勤怠/カレンダー」の 1 フラグを 勤怠(attendance) と カレンダー(calendar) の 2 フラグに分けた。
# 分離を機に今まで見えていたカレンダーを失わないよう、attendance の値をそのまま calendar に写す。
# admin はキーが無ければ ON 扱い(User#can_use?)なので、明示が要るのは attendance を持つ人だけ。
class SplitCalendarFeatureFlag < ActiveRecord::Migration[8.0]
  def up
    User.find_each do |user|
      feature_flags = user.feature_flags.to_h
      next unless feature_flags.key?("attendance")
      next if feature_flags.key?("calendar")

      user.update_column(:feature_flags, feature_flags.merge("calendar" => feature_flags["attendance"]))
      say("#{user.display_name}: カレンダー=#{feature_flags['attendance']}（勤怠から引き継ぎ）")
    end
  end

  def down
    User.find_each do |user|
      feature_flags = user.feature_flags.to_h
      next unless feature_flags.key?("calendar")

      user.update_column(:feature_flags, feature_flags.except("calendar"))
    end
  end
end
