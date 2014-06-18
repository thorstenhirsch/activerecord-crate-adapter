require_relative '../spec_helper'

describe "Post#array" do

  before(:all) do
    ActiveRecord::Migration.class_eval do
      create_table :posts do |t|
        t.string :title
        t.integer :comment_count
        t.string :tags, array: true
        t.integer :votes, array: true
      end
    end
    Post.reset_column_information
  end

  after(:all) do
    ActiveRecord::Migration.class_eval do
      drop_table :posts
    end
  end


  describe "#array column type" do
    let(:array) {%w(hot fresh)}
    let(:votes) {[9,8,7]}
    let(:post) {Post.create!(title: 'Arrays are awesome', tags: array, votes: votes)}

    it 'should store and return an array' do
      p = Post.find(post.id)
      p.tags.should be_a Array
      p.votes.should be_a Array
      p.tags.should eq array
      p.votes.should eq votes
    end

    it 'should find the post by array value' do
      post = Post.create!(title: 'Arrays are awesome', tags: array, votes: votes)
      refresh_posts
      Post.where("'fresh' = ANY (tags)").should include(post)
    end

  end

end