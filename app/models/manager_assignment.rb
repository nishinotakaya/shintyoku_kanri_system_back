class ManagerAssignment < ApplicationRecord
  belongs_to :manager, class_name: "User"
  belongs_to :managee, class_name: "User"

  validates :managee_id, uniqueness: { scope: :manager_id }
end
