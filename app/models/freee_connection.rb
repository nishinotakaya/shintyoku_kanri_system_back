class FreeeConnection < ApplicationRecord
  belongs_to :user

  # Rails 7+ の Active Record Encryption。
  # cookie / password は平文保存しない。
  encrypts :session_cookie
  encrypts :password_encrypted

  scope :connected, -> { where(status: "connected") }

  def connected?
    status == "connected" && session_cookie.present?
  end
end
