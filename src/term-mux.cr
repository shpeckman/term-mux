# src/term-mux.cr
require "socket"
require "file_utils"

require "./mux/protocol"
require "./mux/pty"
require "./mux/buffer"
require "./mux/sequence"
require "./mux/emitter"
require "./mux/filter"
require "./mux/client"
require "./mux/server"
require "./mux/middleman"

module Term::Mux
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
