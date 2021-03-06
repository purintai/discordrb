module Discordrb
  # Logs debug messages
  class Logger
    attr_writer :debug

    def debug(message, important = false)
      puts "[DEBUG : #{Thread.current[:discordrb_name]} @ #{Time.now}] #{message}" if @debug || important
    end

    def log_exception(e, important = true)
      debug("Exception: #{e.inspect}", important)
      e.backtrace.each { |line| debug(line, important) }
    end
  end
end
