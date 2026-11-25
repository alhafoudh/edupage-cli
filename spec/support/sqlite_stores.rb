# Windows cannot delete a file that is still open, so every SQLite store an example
# opens has to be closed before the per-example temp directory is removed.
module SqliteStores
  def self.open = (@open ||= [])

  def self.close_all!
    open.each(&:close)
    open.clear
  end

  def initialize(...)
    super
    SqliteStores.open << self
  end
end

Edupage::Server::Public::Store.prepend(SqliteStores)
