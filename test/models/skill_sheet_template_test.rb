require "test_helper"

# スキルシートの書き出しテンプレート(engineer / creator)。
# 以前は画面から選べず DB を直接書き換えるしかなかったため、
# API で保存でき、値が payload に出ることを固定する。
class SkillSheetTemplateTest < Minitest::Test
  def setup
    @user = User.create!(email: "tmpl_#{SecureRandom.hex(4)}@example.com",
                         password: "password123", display_name: "テンプレテスト")
  end

  def teardown
    SkillSheet.where(user_id: @user.id).destroy_all
    @user.destroy
  end

  def build_sheet(**attrs)
    SkillSheet.create!({ user: @user, engineer_name: "テスト" }.merge(attrs))
  end

  # 1. 既定はエンジニア用
  def test_defaults_to_engineer
    assert_equal "engineer", build_sheet.template_type
  end

  # 2. クリエイター用に切り替えられる
  def test_can_be_set_to_creator
    sheet = build_sheet(template_type: "creator", export_gid: "123456")
    assert_equal "creator", sheet.template_type
    assert_equal "123456", sheet.export_gid
  end

  # 3. 想定外の値は弾く(タイプミスで書き出しが黙って engineer に落ちるのを防ぐ)
  def test_rejects_unknown_template_type
    assert_raises(ActiveRecord::RecordInvalid) { build_sheet(template_type: "designer") }
  end

  # 4. 画面が読む payload に含まれる
  def test_payload_exposes_template_fields
    payload = build_sheet(template_type: "creator", export_gid: "999").as_payload

    assert_equal "creator", payload[:template_type]
    assert_equal "999", payload[:export_gid]
  end

  # 5. 書き出しに使うクラスが template_type で切り替わる
  def test_exporter_class_switches_by_template_type
    engineer = build_sheet
    creator = build_sheet(template_type: "creator")

    assert_equal SkillSheetExporter, exporter_for(engineer)
    assert_equal CreatorSkillSheetExporter, exporter_for(creator)
  end

  # controller と同じ選び方(ここがズレると画面の選択が効かなくなる)
  def exporter_for(sheet)
    sheet.template_type == "creator" ? CreatorSkillSheetExporter : SkillSheetExporter
  end
end
