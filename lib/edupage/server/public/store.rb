require "fileutils"
require "json"

module Edupage
  module Server
    module Public
      # SQLite persistence for the public server: registered clients, grants and the
      # hashes of their tokens. Nothing in here can be decrypted without a live token;
      # see Grants and Crypto.
      class Store
        SQLITE_MISSING = "edupage server --public needs the sqlite3 gem (gem install sqlite3)".freeze

        SCHEMA = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS clients (
            id TEXT PRIMARY KEY, metadata TEXT NOT NULL, created_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS grants (
            id TEXT PRIMARY KEY, client_id TEXT NOT NULL, sealed_credentials TEXT NOT NULL,
            created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS tokens (
            id TEXT PRIMARY KEY,
            grant_id TEXT NOT NULL REFERENCES grants(id) ON DELETE CASCADE,
            kind TEXT NOT NULL, secret_hash TEXT NOT NULL, wrapped_key TEXT,
            expires_at INTEGER NOT NULL, used_at INTEGER, extra TEXT);
          CREATE INDEX IF NOT EXISTS tokens_grant ON tokens(grant_id);
        SQL

        # sqlite3 is a soft dependency: only this mode needs it.
        def self.require_sqlite!
          require "sqlite3"
        rescue LoadError
          raise Error, SQLITE_MISSING
        end

        def initialize(path)
          self.class.require_sqlite!
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, File::RDWR | File::CREAT, 0o600) { nil }
          File.chmod(0o600, path)

          @db = SQLite3::Database.new(path)
          @db.results_as_hash = true
          @db.busy_timeout = 5000
          @db.execute("PRAGMA journal_mode=WAL")
          @db.execute("PRAGMA foreign_keys=ON")
          @db.execute_batch(SCHEMA)
          @lock = Monitor.new
        end

        def transaction(&block)
          @lock.synchronize do
            return block.call if @db.transaction_active?

            @db.transaction { block.call }
          end
        end

        # --- clients ---------------------------------------------------------------

        def insert_client(id, metadata)
          exec("INSERT INTO clients (id, metadata, created_at) VALUES (?, ?, ?)",
               id, JSON.generate(metadata), Time.now.to_i)
        end

        def find_client(id)
          row = first("SELECT id, metadata FROM clients WHERE id = ?", id)
          row && { id: row["id"], metadata: JSON.parse(row["metadata"]) }
        end

        # --- grants ----------------------------------------------------------------

        def insert_grant(row)
          exec("INSERT INTO grants (id, client_id, sealed_credentials, created_at, last_used_at) " \
               "VALUES (?, ?, ?, ?, ?)",
               row[:id], row[:client_id], row[:sealed_credentials], row[:created_at], row[:last_used_at])
        end

        def find_grant(id)
          row = first("SELECT * FROM grants WHERE id = ?", id)
          row && symbolize(row)
        end

        def update_grant_credentials(id, sealed)
          exec("UPDATE grants SET sealed_credentials = ? WHERE id = ?", sealed, id)
        end

        def touch_grant(id, at)
          exec("UPDATE grants SET last_used_at = ? WHERE id = ?", at, id)
        end

        def delete_grant(id)
          exec("DELETE FROM grants WHERE id = ?", id)
        end

        def expired_grant_ids(before)
          rows("SELECT id FROM grants WHERE last_used_at < ? ORDER BY id", before).map { |r| r["id"] }
        end

        # --- tokens ----------------------------------------------------------------

        def insert_token(row)
          exec("INSERT INTO tokens (id, grant_id, kind, secret_hash, wrapped_key, expires_at, used_at, extra) " \
               "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
               row[:id], row[:grant_id], row[:kind], row[:secret_hash], row[:wrapped_key],
               row[:expires_at], row[:used_at], row[:extra] && JSON.generate(row[:extra]))
        end

        def find_token(id)
          row = first("SELECT * FROM tokens WHERE id = ?", id)
          return nil unless row

          symbolize(row).merge(extra: row["extra"] && JSON.parse(row["extra"]))
        end

        # A used token keeps only its hash, for replay detection; its wrapping of the
        # grant key goes, so an old token leaking later unlocks nothing.
        def mark_token_used(id, at)
          exec("UPDATE tokens SET used_at = ?, wrapped_key = NULL WHERE id = ?", at, id)
        end

        def delete_tokens(grant_id, kind:)
          exec("DELETE FROM tokens WHERE grant_id = ? AND kind = ?", grant_id, kind)
        end

        def delete_expired_tokens(now)
          exec("DELETE FROM tokens WHERE expires_at < ?", now)
        end

        def inspect = "#<#{self.class.name}>"

        private

        def exec(sql, *binds)
          @lock.synchronize { @db.execute(sql, binds) }
          nil
        end

        def rows(sql, *binds) = @lock.synchronize { @db.execute(sql, binds) }

        def first(sql, *binds) = rows(sql, *binds).first

        def symbolize(row)
          row.to_h { |key, value| [key.to_sym, value] }
        end
      end
    end
  end
end
