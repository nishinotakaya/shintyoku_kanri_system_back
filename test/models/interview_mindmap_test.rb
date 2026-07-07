require "test_helper"

# InterviewMindmap#as_payload に kanpe_script(生成したカンペ本文)が含まれることの回帰テスト。
class InterviewMindmapTest < Minitest::Test
  def setup
    @user = User.create!(
      email: "mindmap_owner_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      display_name: "マインドマップ所有者"
    )
  end

  def teardown
    @user&.destroy
  end

  # 4. kanpe_script を保存すると as_payload の値に反映される
  def test_as_payload_includes_saved_kanpe_script
    mindmap = InterviewMindmap.create!(user: @user, mode: "interview", title: "テスト用マインドマップ", kanpe_script: "【挨拶】こんにちは、元テスターの太郎です。")

    payload = mindmap.as_payload

    assert payload.key?(:kanpe_script), "as_payload に kanpe_script キーが含まれていない"
    assert_equal "【挨拶】こんにちは、元テスターの太郎です。", payload[:kanpe_script]
  ensure
    mindmap&.destroy
  end

  # 4(edge). kanpe_script 未生成(nil)の場合も as_payload はキー自体は返す(nil値)
  def test_as_payload_includes_kanpe_script_key_as_nil_when_not_generated
    mindmap = InterviewMindmap.create!(user: @user, mode: "interview", title: "未生成マインドマップ")

    payload = mindmap.as_payload

    assert payload.key?(:kanpe_script), "as_payload に kanpe_script キーが含まれていない"
    assert_nil payload[:kanpe_script]
  ensure
    mindmap&.destroy
  end
end
