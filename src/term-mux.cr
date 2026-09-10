# src/term-mux.cr
require "socket"
require "file_utils"
require "term-seq"

require "./mux/protocol"
require "./mux/pty"
require "./mux/client"
require "./mux/server"
require "./mux/middleman"

module Term::Mux
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
