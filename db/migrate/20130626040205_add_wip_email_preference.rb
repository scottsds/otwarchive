class AddWipEmailPreference < ActiveRecord::Migration
  def self.up
    add_column :subscriptions, :notify_when_complete, :boolean, :null => false, :default => false
  end

  def self.down
    remove_column :subscriptions, :notify_when_complete
  end
end
