require "spec_helper"

module Switchman
  describe DatabaseServer do
    describe "shareable?" do
      it "should be true for mysql" do
        db = DatabaseServer.new(nil, adapter: 'mysql')
        expect(db.shareable?).to eq true

        db = DatabaseServer.new(nil, adapter: 'mysql2')
        expect(db.shareable?).to eq true
      end

      it "should be true for postgres with a non-variable username" do
        db = DatabaseServer.new(nil, adapter: 'postgresql')
        expect(db.shareable?).to eq true
      end

      it "should be false for postgres with variable username" do
        db = DatabaseServer.new(nil, adapter: 'postgresql', username: '%{schema_search_path}')
        expect(db.shareable?).to eq false
      end

      it "should depend on the database environment" do
        db = DatabaseServer.new(nil, adapter: 'postgresql', username: '%{schema_search_path}', deploy: { username: 'deploy' })
        expect(db.shareable?).to eq false
        expect(::GuardRail.activate(:deploy) { db.shareable? }).to eq true
      end

      it "should handle string keys" do
        db = DatabaseServer.new(nil, adapter: 'postgresql', username: '%{schema_search_path}', deploy: { 'username' => 'deploy' })
        expect(db.shareable?).to eq false
        expect(::GuardRail.activate(:deploy) { db.shareable? }).to eq true
      end
    end

    describe "#create_new_shard" do
      include RSpecHelper

      def maybe_activate(shard)
        shard.activate { yield } if shard
        yield unless shard
      end

      adapter = ::ActiveRecord::Base.connection.adapter_name
      def create_shard(server)
        new_shard = server.create_new_shard
        expect(new_shard).not_to be_new_record
        expect(new_shard.name).to match /shard_\d+/
        # They should share a connection pool
        if server == Shard.default.database_server
          expect(User.connection_pool.current_pool).to eq new_shard.activate { User.connection_pool.current_pool }
          expect(User.connection_pool.current_pool).to eq Shard.connection_pool.current_pool
        else
          expect(User.connection_pool.current_pool).not_to eq new_shard.activate { User.connection_pool.current_pool }
        end
        # The tables should be created, ready to use
        new_shard.activate {
          a = User.create!
          expect(a).not_to be_new_record
        }
      ensure
        if new_shard
          new_shard.drop_database
          new_shard.destroy
        end
      end

      it "should be able to create a new shard from a db server that doesn't have any shards" do
        # So, it's really the same server, but we want separate connections
        db = DatabaseServer.create(Shard.default.database_server.config)
        begin
          create_shard(db)
        ensure
          db.destroy
        end
      end

      class MyException < Exception; end
      it "should not use a temp name" do
        db = DatabaseServer.new(nil, adapter: 'postgresql')
        Shard.expects(:create!).with { |hash|
          hash[:name] == "new_shard" &&
            hash[:database_server] == db &&
            !hash[:id].nil?
        }.raises(MyException.new)
        expect { db.create_new_shard(name: "new_shard") }.to raise_error(MyException)
      end
    end

    describe "#config" do
      it "should return subenvs" do
        base_config = { database: 'db',
                        secondary: [nil, { database: 'secondary' }],
                        deploy: { username: 'deploy' }}
        ds = DatabaseServer.new(nil, base_config)
        expect(ds.config).to eq base_config
        expect(ds.config(:secondary)).to eq [{ database: 'db', deploy: base_config[:deploy] },
                                     { database: 'secondary', deploy: base_config[:deploy] }]
        expect(ds.config(:deploy)).to eq({ database: 'db', username: 'deploy', secondary: base_config[:secondary], deploy: base_config[:deploy] })
      end
    end

    describe "#guard_rail_environment" do
      it "should inherit from GuardRail.environment" do
        ds = DatabaseServer.new
        expect(ds.guard_rail_environment).to eq :primary
        ::GuardRail.activate(:secondary) do
          expect(ds.guard_rail_environment).to eq :secondary
        end
      end

      it "should override GuardRail.environment when explicitly set" do
        ds = DatabaseServer.new
        ds.guard!
        expect(ds.guard_rail_environment).to eq :secondary
        ds.unguard do
          expect(ds.guard_rail_environment).to eq :primary
        end
        expect(ds.guard_rail_environment).to eq :secondary
        ::GuardRail.activate(:secondary) do
          expect(ds.guard_rail_environment).to eq :secondary
          ds.unguard do
            expect(ds.guard_rail_environment).to eq :secondary
          end
          expect(ds.guard_rail_environment).to eq :secondary
        end
        expect(ds.guard_rail_environment).to eq :secondary
      end
    end

    describe "#cache_store" do
      before do
        @db = DatabaseServer.new
        @default_store = ::ActiveSupport::Cache.lookup_store(:null_store)
        @db_store = ::ActiveSupport::Cache.lookup_store(:memory_store)
        @original_map = Switchman.config[:cache_map]
        Switchman.config[:cache_map] = { ::Rails.env => @default_store, @db.id => @db_store }
      end

      after do
        Switchman.config[:cache_map] = @original_map
      end

      it "should prefer the cache specific to the database" do
        expect(@db.cache_store.object_id).to eq @db_store.object_id
      end

      it "should fallback to Rails.cache_without_sharding if no specific cache" do
        Switchman.config[:cache_map].delete(@db.id)
        expect(@db.cache_store.object_id).to eq @default_store.object_id
      end
    end

    describe ".server_for_new_shard" do
      before(:all) do
        @db1 = DatabaseServer.find(nil)
        @old_open = @db1.config.delete(:open)
        @old_servers = DatabaseServer.all
        @old_servers.delete(@db1)
        @old_servers.each do |db|
          db.destroy unless db == @db1
        end
      end

      before do
        @db1.config.delete(:open)
      end

      after do
        @db2&.destroy
      end

      after(:all) do
        @db1.config[:open] = @old_open
        @old_servers.each do |db|
          DatabaseServer.create(db.config.merge(id: db.id))
        end
      end

      it "should return the default server if that's the only one around" do
        expect(DatabaseServer.server_for_new_shard).to eq @db1
      end

      it "should return on open server" do
        @db1.config[:open] = true
        expect(DatabaseServer.server_for_new_shard).to eq @db1
      end

      it "should return another server if it's the only one open" do
        @db2 = DatabaseServer.create(open: true)
        4.times { expect(DatabaseServer.server_for_new_shard).to eq @db2 }
        @db2.config.delete(:open)
        @db1.config[:open] = true
        4.times { expect(DatabaseServer.server_for_new_shard).to eq @db1 }
      end

      it "should return multiple open servers" do
        @db2 = DatabaseServer.create(open: true)
        @db1.config[:open] = true
        dbs = []
        20.times do
          dbs << DatabaseServer.server_for_new_shard
        end
        expect(dbs).to include(@db1)
        expect(dbs).to include(@db2)
      end
    end

    describe "#primary_shard" do
      it "works even without a shards table" do
        expect(Shard.default).to be_a(DefaultShard)
        Shard.default.database_server.expects(:shards).never
        expect(Shard.default.database_server.primary_shard).to eq Shard.default
      end
    end
  end
end
