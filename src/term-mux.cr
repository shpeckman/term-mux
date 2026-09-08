# src/term-mux.cr
require "socket"
require "file_utils"

require "./mux/protocol"
require "./mux/pty"
require "./mux/client"
require "./mux/server"

module Term::Mux
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
