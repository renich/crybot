require "../spec_helper"
require "../../src/auth/token_store"

describe Crybot::Auth::TokenStore do
  # Clean up before each test
  Spec.before_each do
    if File.exists?("/tmp/crybot_test/accounts.json")
      File.delete("/tmp/crybot_test/accounts.json")
    end
    # Reset internal state if possible, but class variables are hard to reset.
    # We can rely on the file reload logic.
  end

  it "can add and retrieve an account" do
    account = Crybot::Auth::Account.new(
      email: "test@example.com",
      refresh_token: "refresh_123",
      project_id: "test-project"
    )

    Crybot::Auth::TokenStore.add_account(account)

    accounts = Crybot::Auth::TokenStore.list
    accounts.size.should eq(1)
    accounts.first.email.should eq("test@example.com")
    accounts.first.project_id.should eq("test-project")
  end

  it "updates existing account" do
    account1 = Crybot::Auth::Account.new(
      email: "test@example.com",
      refresh_token: "refresh_123",
      project_id: "test-project"
    )
    Crybot::Auth::TokenStore.add_account(account1)

    account2 = Crybot::Auth::Account.new(
      email: "test@example.com",
      refresh_token: "refresh_456", # Changed
      project_id: "test-project"
    )
    Crybot::Auth::TokenStore.add_account(account2)

    accounts = Crybot::Auth::TokenStore.list
    accounts.size.should eq(1)
    accounts.first.refresh_token.should eq("refresh_456")
  end

  it "persists accounts to file" do
    account = Crybot::Auth::Account.new(
      email: "persist@example.com",
      refresh_token: "persist_token",
      project_id: "persist-project"
    )
    Crybot::Auth::TokenStore.add_account(account)

    # Check file content
    content = File.read("/tmp/crybot_test/accounts.json")
    content.should contain("persist@example.com")
  end
end
