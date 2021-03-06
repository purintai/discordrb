require 'discordrb/voice/encoder'
require 'discordrb/voice/network'

# Voice support
module Discordrb::Voice
  # How long one packet should ideally be (20 ms as defined by Discord)
  IDEAL_LENGTH = 20.0

  # How many bytes of data to read (1920 bytes * 2 channels)
  DATA_LENGTH = 1920 * 2

  # A voice connection consisting of a UDP socket and a websocket client
  class VoiceBot
    attr_reader :stream_time, :encoder
    attr_accessor :adjust_interval, :adjust_offset, :adjust_average

    def initialize(channel, bot, token, session, endpoint)
      @bot = bot
      @ws = VoiceWS.new(channel, bot, token, session, endpoint)
      @udp = @ws.udp

      @sequence = @time = 0

      @adjust_interval = 100
      @adjust_offset = 10
      @adjust_average = false

      @encoder = Encoder.new
      @ws.connect
    end

    # Set the volume. Only applies to future playbacks
    def volume=(value)
      @encoder.volume = value
    end

    def volume
      @encoder.volume
    end

    # Pause playback
    def pause
      @paused = true
    end

    # Continue playback
    def continue
      @paused = false
    end

    def speaking=(value)
      @playing = value
      @ws.send_speaking(value)
    end

    def stop_playing
      @was_playing_before = @playing
      @speaking = false
      @io.close if @io
      @io = nil
      sleep IDEAL_LENGTH / 1000.0 if @was_playing_before
    end

    def destroy
      stop_playing
      @ws.destroy
      @encoder.destroy
    end

    def play(encoded_io)
      stop_playing if @playing
      @io = encoded_io
      play_internal
    end

    def play_file(file)
      play @encoder.encode_file(file)
    end

    def play_io(io)
      play @encoder.encode_io(io)
    end

    alias_method :play_stream, :play_io

    private

    # Plays the data from the @io stream as Discord requires it
    def play_internal
      count = 0
      @playing = true
      @retry_attempts = 3

      # Default play length (ms), will be adjusted later
      @length = IDEAL_LENGTH

      self.speaking = true
      loop do
        if count % @adjust_interval == @adjust_offset
          # Starting from the tenth packet, perform length adjustment every 100 packets (2 seconds)
          @length_adjust = Time.now.nsec
        end

        break unless @playing
        break unless @io

        # Read some data from the buffer
        buf = nil
        begin
          buf = @io.readpartial(DATA_LENGTH) if @io
        rescue EOFError
          @bot.debug('EOF while reading, breaking immediately')
          break
        end

        # Check whether the buffer has enough data
        if !buf || buf.length != DATA_LENGTH
          @bot.debug("No data is available! Retrying #{@retry_attempts} more times")
          if @retry_attempts == 0
            break
          else
            @retry_attempts -= 1
            next
          end
        end

        # Track packet count, sequence and time (Discord requires this)
        count += 1
        (@sequence + 10 < 65_535) ? @sequence += 1 : @sequence = 0
        (@time + 9600 < 4_294_967_295) ? @time += 960 : @time = 0

        # Encode the packet and send it
        @udp.send_audio(@encoder.encode(buf), @sequence, @time)

        # Set the stream time (for tracking how long we've been playing)
        @stream_time = count * @length / 1000

        # Perform length adjustment
        if @length_adjust
          # Difference between length_adjust and now in ms
          ms_diff = (Time.now.nsec - @length_adjust) / 1_000_000.0
          if ms_diff >= 0
            if @adjust_average
              @length = (IDEAL_LENGTH - ms_diff + @length) / 2.0
            else
              @length = IDEAL_LENGTH - ms_diff
            end

            @bot.debug("Length adjustment: new length #{@length}")
          end
          @length_adjust = nil
        end

        # If paused, wait
        sleep 0.1 while @paused

        # Wait `length` ms, then send the next packet
        sleep @length / 1000.0
      end

      @bot.debug('Performing final cleanup after stream ended')

      # Final cleanup
      stop_playing
    end
  end
end
