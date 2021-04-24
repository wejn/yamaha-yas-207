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
require 'webrick'
require 'json'

# YAS-207 remote.
#
# Provides higher-level abstraction (stateful management) on top of the soundbar.
#
# Also implements interface used by `YamahaSerialInputWorker`.
class YamahaSoundbarRemote
	# Init string sent to YAS-207
	INIT_STRING = "0148545320436f6e74"

	# Init-followup command sent to YAS-207 (that is sent after the response to init string)
	INIT_FOLLOWUP = "020001"

	# Commands accepted by the YAS-207 (that I know of)
	COMMANDS = {
		# power management
		power_toggle: "4078cc",
		power_on: "40787e",
		power_off: "40787f",

		# input management
		set_input_hdmi: "40784a",
		set_input_analog: "4078d1",
		set_input_bluetooth: "407829",
		set_input_tv: "4078df",

		# surround management
		set_surround_3d: "4078c9", # -- 3d surround
		set_surround_tv: "407ef1", # -- tv program
		set_surround_stereo: "407850",
		set_surround_movie: "4078d9",
		set_surround_music: "4078da",
		set_surround_sports: "4078db",
		set_surround_game: "4078dc",
		surround_toggle: "4078b4", # -- sets surround to `:movie` (or `:"3d"` if already `:movie`)
		clearvoice_toggle: "40785c",
		clearvoice_on: "407e80",
		clearvoice_off: "407e82",
		bass_ext_toggle: "40788b",
		bass_ext_on: "40786e",
		bass_ext_off: "40786f",

		# volume management
		subwoofer_up: "40784c",
		subwoofer_down: "40784d",
		mute_toggle: "40789c",
		mute_on: "407ea2",
		mute_off: "407ea3",
		volume_up: "40781e",
		volume_down: "40781f",

		# extra -- IR -- don't use?
		bluetooth_standby_toggle: "407834",
		dimmer: "4078ba",

		# status report (query, soundbar returns a message)
		report_status: "0305"
	}.freeze

	# Mapping of input values to names
	INPUT_NAMES = {
		0x0 => :hdmi,
		0xc => :analog,
		0x5 => :bluetooth,
		0x7 => :tv,
	}.freeze

	# Mapping of surround values to names
	SURROUND_NAMES = {
		0x0d => :"3d",
		0x0a => :tv,
		0x0100 => :stereo,
		0x03 => :movie,
		0x08 => :music,
		0x09 => :sports,
		0x0c => :game,
	}.freeze

	# How long to wait for sync before retrying.
	SYNC_TIMEOUT = 15

	# How often to refresh status.
	STATUS_REFRESH = 30

	# Volume range accepted by the device
	VOLUME_RANGE = (0..0x32)

	# Domain (range) valid for the device
	SUBWOOFER_DOMAIN = 0.step(0x20, 4).to_a

	# Initial intent enforced at the first sync (more in `handle_received`, tho)
	INITIAL_INTENT = {
		subwoofer: 16,
		surround: :tv,
		bass_ext: true,
		clearvoice: false,
	}.freeze

	def initialize
		@device_state = {}
		@queue = Queue.new
		@state = :initial
		@intent = {}
	end
	attr_reader :device_state

	# Handle packet received via serial.
	#
	# @param packet [Array<Integer>, :reset, :heartbeat] incoming packet
	def handle_received(packet)
		if packet == :reset
			@state = :initial
			@queue.clear # no use pushing anything when the comm broke
			@reset_at = Time.now
			enqueue(INIT_STRING)
		elsif packet == :heartbeat
			if @state == :synced
				if @last_status_at + STATUS_REFRESH < Time.now
					@last_status_at = Time.now
					enqueue(COMMANDS[:report_status])
				end
			else
				if @reset_at + SYNC_TIMEOUT < Time.now
					STDERR.puts "! Couldn't sync, retrying by :reset."
					handle_received(:reset)
				end
			end
		else
			# handle packet -- XXX: we might get stray packet regardless of status
			case packet.first
			when 0x04 # received device id (in response to init?)
				if @state == :initial
					@state = :init_followup
					enqueue(INIT_FOLLOWUP)
				else
					STDERR.puts "! Received out of sequence did packet: #{packet.inspect}"
				end
			when 0x00 # response to init followup?
				if @state == :init_followup
					@state = :synced
					@last_status_at = Time.now
					add_intent({initial: true})
					if packet != [0, 2, 0]
						STDERR.puts "? Received unexpected init_followup packet: #{packet.inspect}"
					end
				else
					puts "? Received: #{packet.inspect}" # FIXME
				end
			when 0x05 # device status reply
				params = parse_device_status(packet)
				puts "+ DS: #{params.map { |k,v| "#{k}:#{v}" }.join(',')}"
				@device_state = params
				if @intent[:initial]
					# We have initial intent, but we also can have some other
					# intent already in from the user. So let's use our initial
					# with an update from the user as the final thing.
					intent = INITIAL_INTENT.dup
					if @device_state[:power] && @device_state[:input] == :bluetooth
						# we probably just woke up the device → put it back to sleep @ HDMI
						intent.update({input: :hdmi, power: false})
					end
					rest_of_intent = @intent.dup
					rest_of_intent.delete(:initial)
					intent.update(rest_of_intent)
					@intent = intent
				end
				# and now enforce it
				unless @intent.empty?
					@intent = enforce_intent(@intent)
				end
			else
				puts "? Received: #{packet.inspect}" # FIXME
			end
		end
	end

	private def parse_device_status(pkt)
		params = {}
		params[:power] = !pkt[2].zero?
		params[:input] = INPUT_NAMES[pkt[3]] || pkt[3]
		params[:mute] = !pkt[4].zero?
		params[:volume] = pkt[5]
		params[:subwoofer] = pkt[6]
		srd = (pkt[10] << 8) + pkt[11]
		params[:surround] = SURROUND_NAMES[srd] || srd
		params[:bass_ext] = !(pkt[12] & 0x20).zero?
		params[:clearvoice] = !(pkt[12] & 0x4).zero?
		params
	end

	private def enqueue(command)
		cmd = YamahaPacketCodec.encode(command)
		@queue.push([Time.now, cmd])
		cmd
	end

	# Add given intent
	private def add_intent(intent)
		@intent.update(intent)
		enqueue(COMMANDS[:report_status])
		@intent.dup
	end

	# Enforce given intent and return whatever couldn't have been enforced.
	private def enforce_intent(intent)
		intent = intent.dup
		retried = intent.delete(:enforce_retried)
		device_state = @device_state.dup

		delta_keys = intent.keys.reduce([]) { |m, x| m << x unless device_state[x] == intent[x]; m }

		return {} if delta_keys.empty? # zero diff → stable state reached
		# also zero diff (mute doesn't work when powered off) >>
		return {} if delta_keys == [:mute] && device_state[:power] == false

		# pathological case: power_off and non-empty list of commands
		if !device_state[:power] && !(delta_keys - [:power]).empty?
			enqueue(COMMANDS[:power_on]) # turn on
			device_state[:power] = true # mark it's on
			delta_keys << :power unless delta_keys.include?(:power)
			intent[:power] ||= false # force off (unless intended otherwise)
		end

		# first power on (if needed)
		if intent[:power] && !device_state[:power]
			enqueue(COMMANDS[:power_on])
		end

		# enforce individual keys
		keys_to_enforce = [
			:input, :mute, :volume, :subwoofer, :surround, :bass_ext,
			:clearvoice, :power]
		(keys_to_enforce & delta_keys).each do |k|
			case k
			when :input
				enqueue(COMMANDS[('set_input_' + intent[k].to_s).to_sym])
			when :volume
				delta = intent[:volume] - device_state[:volume]
				delta.abs.times {
					enqueue(COMMANDS[delta < 0 ? :volume_down : :volume_up]) }
			when :subwoofer
				delta = intent[:subwoofer] - device_state[:subwoofer]
				(delta.abs / 4).times {
					enqueue(
						COMMANDS[delta < 0 ? :subwoofer_down : :subwoofer_up]) }
			when :surround
				enqueue(COMMANDS[('set_surround_' + intent[k].to_s).to_sym])
			when :mute, :bass_ext, :clearvoice, :power
				enqueue(COMMANDS[(k.to_s + (intent[k] ? '_on' : '_off')).to_sym])
			else
				STERR.puts "! enforce_intent for unimplemented key: #{k}"
			end
		end

		if retried
			STDERR.puts "~ enforce_intent: loop breaker: #{intent.inspect} on #{device_state}, delta: #{delta_keys}" if $VERBOSE || $DEBUG
			{}
		else
			# had a diff, let's have another round after this one
			enqueue(COMMANDS[:report_status])
			intent.update({enforce_retried: true}) # avoid endless looping
		end
	end

	# Send raw command to device -- called by end users (if they speak raw).
	#
	# @param command [Array<Integer>, String] command understood by `YamahaPacketCodec.encode()`.
	# @raise [RuntimeError] when device not ready
	def send_raw(command)
		if @state == :synced
			enqueue(command)
		else
			raise RuntimeError, "device not ready"
		end
	end

	# Send a command to device -- called by end users.
	#
	# @param command [Symbol, String] name of the command to send.
	# @raise [RuntimeError] when device not ready
	# @raise [ArgumentError] when the command is wrong
	def send(command)
		if @state == :synced
			if c = COMMANDS[command.to_sym]
				enqueue(c)
				command.to_sym
			else
				raise ArgumentError, "unknown command: #{command}"
			end
		else
			raise RuntimeError, "device not ready"
		end
	end

	# Send a given intent to device -- called by end users.
	#
	# @param intent [Hash<String, Object>] intent to send.
	# @raise [RuntimeError] when device not ready
	# @raise [ArgumentError] when the intent is wrong
	def send_intent(intent)
		if @state == :synced
			validated_intent = {}
			is_bool = proc { |x|
				unless x === true || x === false
					raise ArgumentError, "must be bool"
				else
					x
				end
			}
			valid_keys = {
				power: is_bool,
				mute: is_bool,
				bass_ext: is_bool,
				clearvoice: is_bool,
				input: proc { |x|
					if INPUT_NAMES.values.include?(x.to_sym)
						x.to_sym
					else
						raise ArgumentError, "must be one of: #{INPUT_NAMES.values.inspect}"
					end
				},
				volume: proc { |x|
					if VOLUME_RANGE.include?(Integer(x))
						Integer(x)
					else
						raise ArgumentError, "must be integer in: #{VOLUME_RANGE}"
					end
				},
				subwoofer: proc { |x|
					if SUBWOOFER_DOMAIN.include?(Integer(x))
						Integer(x)
					else
						raise ArgumentError, "must be integer in: #{SUBWOOFER_DOMAIN}"
					end

				},
				surround: proc { |x|
					if SURROUND_NAMES.values.include?(x.to_sym)
						x.to_sym
					else
						raise ArgumentError, "must be one of: #{SURROUND_NAMES.values.inspect}"
					end
				},
			}
			validated_intent = intent.map { |k, v|
				raise ArgumentError, "invalid key: #{k}" unless valid_keys[k.to_sym]
				begin
					[k.to_sym, valid_keys[k.to_sym][v]]
				rescue
					raise ArgumentError, "#{k} #$!"
				end
			}.to_h
			add_intent(validated_intent)
		else
			raise RuntimeError, "device not ready"
		end
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

	ysr = YamahaSoundbarRemote.new
	threads = []

	threads << Thread.new do
		print "+ BT handler init...\n"  # $10 to the first person explaining why not `puts`
		YamahaSerialInputWorker.as_thread(ENV['CONTROL_DEVICE'] || '/dev/rfcomm0', ysr)
	end

	threads << Thread.new do
		print "+ Webserver...\n"
		s = WEBrick::HTTPServer.new({
			:Port => 8000,
			:BindAddress => "127.0.0.1",
			:Logger => WEBrick::Log.new('/dev/null'),
			:AccessLog => [ [$stdout, "> %h %U %b"] ],
			:DoNotReverseLookup => true,
		})

		s.mount_proc("/send") do |req, res|
			q = req.query
			res['Content-Type'] = 'text/plain; charset=utf-8'
			if q["data"]
				out = []
				for code in q["data"].split(/,/)
					begin
						sent = ysr.send_raw(code)
						out << "sent #{sent.scan(/./m).map{|x| "%02x" % x.ord}.join}.\n"
					rescue
						out << "failed to send #{q["data"].inspect}: #{$!}.\n"
						break
					end
				end
				res.body = out.join
			elsif q["commands"]
				out = []
				for command in q["commands"].split(/,/)
					begin
						sent = ysr.send(command)
						out << "sent #{sent}.\n"
					rescue
						out << "failed to send #{q["command"].inspect}: #{$!}.\n"
						break
					end
				end
				res.body = out.join
			elsif q["intent"]
				out = []
				begin
					sent = ysr.send_intent(JSON.parse(q['intent']))
					out << "send intent: #{sent}.\n"
				rescue
					out << "failed to send intent #{q["intent"].inspect}: #{$!}.\n"
				end
				res.body = out.join
			else
				res.body = "nope (missing params: either data or commands).\n"
			end
		end

		s.mount_proc("/") do |req, res|
			out = []
			if req.query['json'] || req.accept.include?("application/json")
				res['Content-Type'] = 'application/json; charset=utf-8'
				out << JSON.pretty_generate(ysr.device_state)
			else
				res['Content-Type'] = 'text/html; charset=utf-8'
				out << <<-EOF
<!DOCTYPE html>
<html lang="en">
<head>      
<meta charset="UTF-8">
<title>YAS-207 control</title>
<meta name="viewport" content="width=device-width">
</head>
<body>
				EOF
				out.last.strip!

				out << "<h1>YAS-207 control</h1>"
				out << "<pre>" + ysr.device_state.inspect + "</pre>"
				out << "</body>\n</html>"
			end
			res.body = out.join("\n")
			res
		end

		s.start 
	end

	begin
		threads.map(&:join)
	rescue Interrupt
		threads.map(&:kill)
	end
end
