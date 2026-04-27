# 既存ユーザーの全データを新規ユーザーへ複製する。
# - 識別情報（email/password/provider/uid/display_name/company_name/avatar_url）は移さない
# - has_many / has_one の関連レコードは新 user_id を振り直して全件コピー
# - 副作用なく冪等に呼べるよう、dst にデータが既にあれば何もしない
class UserCloner
  USER_COPY_ATTRS = %w[
    closing_day
    custom_off_days transit_routes commute_days
    default_transit_from default_transit_to default_transit_fee default_transit_line
    postal_code address attendance_schedule_url local_save_dir
    can_issue_orders openai_api_key
  ].freeze

  ASSOCIATIONS = %i[
    work_reports expenses invoice_settings backlog_tasks todos monthly_settings purchase_order_settings
  ].freeze

  def self.copy_all(src:, dst:)
    raise "src/dst が同じ" if src.id == dst.id
    return :skipped if dst_has_any_data?(dst)

    ActiveRecord::Base.transaction do
      copy_user_attributes(src, dst)
      ASSOCIATIONS.each { |name| copy_has_many(src, dst, name) if dst.class.reflect_on_association(name) }
      copy_has_one(src, dst, :backlog_setting) if dst.class.reflect_on_association(:backlog_setting)
    end
    :copied
  end

  def self.dst_has_any_data?(dst)
    ASSOCIATIONS.any? { |name| dst.class.reflect_on_association(name) && dst.public_send(name).any? } ||
      dst.try(:backlog_setting).present?
  end
  private_class_method :dst_has_any_data?

  def self.copy_user_attributes(src, dst)
    payload = USER_COPY_ATTRS.each_with_object({}) do |attr, h|
      next unless dst.respond_to?("#{attr}=")
      h[attr] = src.public_send(attr) if src.respond_to?(attr)
    end
    dst.update!(payload)
  end
  private_class_method :copy_user_attributes

  def self.copy_has_many(src, dst, association_name)
    src.public_send(association_name).find_each do |record|
      attrs = record.attributes.except("id", "user_id", "created_at", "updated_at")
      dst.public_send(association_name).create!(attrs)
    end
  end
  private_class_method :copy_has_many

  def self.copy_has_one(src, dst, association_name)
    record = src.public_send(association_name)
    return unless record
    attrs = record.attributes.except("id", "user_id", "created_at", "updated_at")
    dst.public_send("create_#{association_name}!", attrs)
  end
  private_class_method :copy_has_one
end
