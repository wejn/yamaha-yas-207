#!/usr/bin/env ruby

# Author: Michal Jirku (wejn.org)
# License: GNU Affero General Public License v3.0

begin
	require 'serialport'
rescue LoadError
	STDERR.puts "Missing serialport gem: #$!."
	exit 1
end
begin
	require_relative 'common'
rescue LoadError
	STDERR.puts "Missing common lib: #$!."
	exit 1
end
require 'thread'
require 'digest/sha1'

# Fake implementation of the YAS-207 soundbar.
#
# Intended to sit on the other side of a serial port
# and respond to commands (as if the client spoke to
# real hardware).
class YamahaSoundbarFake
	def initialize
		@queue = Queue.new
		@power = true
		@input = 0x5
		@muted = false
		@volume = 10
		@subwoofer = 16
		@surround = 0xa
		@bassext = true
		@clearvoice = false
	end

	# Handle packet received via serial.
	#
	# @param packet [Array<Integer>, :reset, :heartbeat] incoming packet
	def handle_received(packet)
		return if packet == :reset || packet == :heartbeat
		case packet.first
		when 0x1 # client handshake
			if packet == [1, 72, 84, 83, 32, 67, 111, 110, 116]
				# if we're doing a handshake, we might as well pretend to be just init'd.
				# meaning: power on, input BT
				@power, @input = true, 0x5
				#
				enqueue("0400013219020a00")
			end
		when 0x2 # client post handshake followup
			enqueue([0, 2, 0])
		when 0x3 # get status
			case packet[1]
			when 0x5
				enqueue([
					0x5, 0,
					@power ? 1 : 0,
					@input,
					@muted ? 1 : 0,
					@volume,
					@subwoofer,
					0x20, 0x20, 0,
					(@surround >> 8) & 0xff, @surround & 0xff,
					(@bassext ? 0x20 : 0) + (@clearvoice ? 0x4 : 0)])
			when 0x10
				enqueue([0x10, @power ? 1 : 0])
			when 0x11
				enqueue([0x11, @input])
			when 0x12
				enqueue([0x12, @muted ? 1 : 0, @volume])
			when 0x13
				enqueue([0x13, @subwoofer])
			when 0x15
				enqueue([
					0x15,
					0,
					(@surround >> 8) & 0xff,
					@surround & 0xff,
					(@bassext ? 0x20 : 0) + (@clearvoice ? 0x4 : 0)])
			else
				enqueue("000301")
			end
		when 0x40 # command
			if @power
				case (packet[1]<<8) + packet[2]
				when 0x78cc # power_toggle
					@power = !@power
				when 0x787e # power_on
					@power = true
				when 0x787f # power_off
					@power = false
					@muted = false
				when 0x784a # set_input_hdmi
					@input = 0x0
				when 0x78d1 # set_input_analog
					@input = 0xc
				when 0x7829 # set_input_bluetooth
					@input = 0x5
				when 0x78df # set_input_tv
					@input = 0x7
				when 0x78c9 # set_3d_surround
					@surround = 0x0d
				when 0x7ef1 # set_tvprogram
					@surround = 0x0a
				when 0x7850 # set_stereo
					@surround = 0x0100
				when 0x78d9 # set_movie
					@surround = 0x03
				when 0x78da # set_music
					@surround = 0x08
				when 0x78db # set_sports
					@surround = 0x09
				when 0x78dc # set_game
					@surround = 0x0c
				when 0x78b4 # surround_toggle
					if @surround == 0x3
						@surround = 0xd
					else
						@surround = 0x3
					end
				when 0x785c # clearvoice_toggle
					@clearvoice = !@clearvoice
				when 0x7e80 # clearvoice_on
					@clearvoice = true
				when 0x7e82 # clearvoice_off
					@clearvoice = false
				when 0x786e # bass_ext_toggle
					@bassext = !@bassext
				when 0x786e # bass_ext_on
					@bassext = true
				when 0x786f # bass_ext_off
					@bassext = false
				when 0x784c # subwoofer_up
					@subwoofer += 4 if @subwoofer <= (0x20 - 4)
				when 0x784d # subwoofer_down
					@subwoofer -= 4 if @subwoofer >= (0 + 4)
				when 0x789c # mute_toggle
					@muted = !@muted
				when 0x7ea2 # mute_on
					@muted = true
				when 0x7ea3 # mute_off
					@muted = false
				when 0x781e # volume_up
					@volume += 1 if @volume < 0x32
					@muted = false
				when 0x781f # volume_down
					@volume -= 1 if @volume > 0
					@muted = false
				else
					puts "! Invalid command: #{packet.inspect}."
				end
			else
				case (packet[1]<<8) + packet[2]
				when 0x787e # power_on
					@power = true
				when 0x787f # power_off
					@power = false
					@muted = false
				else
					puts "! Ignored command (when powered off): #{packet.inspect}."
				end
			end
		else
			puts "! Invalid packet: #{packet.inspect}."
		end
	end

	private def enqueue(command)
		cmd = YamahaPacketCodec.encode(command)
		@queue.push([Time.now, cmd])
		cmd
	end

	# Fetch next packet to be sent to device -- called by comm handler.
	#
	# @return [String, nil] packet that was enqueued, or `nil` when none
	def pop
		ts, payload = @queue.pop(true)
		if $DEBUG || $VERBOSE
			STDERR.puts "~ Dequeued #{payload.inspect} after #{"%.02f" % (Time.now - ts)}s."
		end
		payload
	rescue ThreadError
		nil
	end
end

if __FILE__ == $0
	STDOUT.sync = true

	ysf = YamahaSoundbarFake.new
	threads = []

	devices = [
		'/tmp/ttyS0-' + Digest::SHA1.hexdigest(File.open('/dev/urandom').read(8)),
		'/tmp/ttyS1-' + Digest::SHA1.hexdigest(File.open('/dev/urandom').read(8))]

	threads << Thread.new do
		print "+ Spawning devices via socat...\n"
		system("socat",
			   "pty,raw,echo=0,link=#{devices.first}",
			   "pty,raw,echo=0,link=#{devices.last}")
		system("kill", "-INT", Process.pid.to_s)
	end

	threads << Thread.new do
		sleep 1 # AMAZING synchronization technique. Mama would be proud.
		YamahaSerialInputWorker.as_thread(devices.last, ysf)
	end

	puts "@ Connect at: #{devices.first}"

	begin
		threads.map(&:join)
	rescue Interrupt
		threads.map(&:kill)
	end
end
