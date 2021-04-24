#!/usr/bin/env ruby

# Author: Michal Jirku (wejn.org)
# License: GNU Affero General Public License v3.0

# Packet codec -- codes and decodes the Yamaha YAS-207 packets.
#
# @example Run streaming decoder
#   ypc = YamahaPacketCodec.new { |r| p [:received_packet, r] }
#   ypc.streaming_decode("ccaa0340784afb".scan(/../).map { |x| x.to_i(16).chr }.join)
#   # ^^ outputs: [:received_packet, [64, 120, 74]]
# @example Encode packet
#   YamahaPacketCodec.encode([3, 5]) # => "\xCC\xAA\x02\x03\x05\xF6"
class YamahaPacketCodec
	# Initialize the codec.
	#
	# @param ingest_cb [Proc] callback is invoked every time a valid packet is received.
	def initialize(&ingest_cb)
		# State transitions:
		# :desync in:  0xcc -> :sync_cc, _ -> :desync
		# :sync_cc in: 0xaa -> :synced, 0xcc -> :sync_cc, _ -> :desync
		# :synced in:  1byte -> [mark payload length] length > 0 ? :reading : :csum
		# :reading in: 1byte -> [remember] collected bytes \lt length :reading || :csum
		# :csum    in: 1byte -> [verify checksum, process pkt] :desync
		@state = :desync
		@pload = []
		@length = 0
		@ingest_cb = ingest_cb
	end

	# Perform streaming decode of incoming data, calling the ingest_cb
	# with valid packets as needed.
	#
	# @param data [String] incoming data
	# @return [YamahaPacketCodec] self
	def streaming_decode(data)
		data.each_byte do |b|
			case @state
			when :desync
				if b.ord == 0xcc
					@state = :sync_cc
				end
			when :sync_cc
				case b.ord
				when 0xaa
					@state = :synced
				when 0xcc
					@state = :sync_cc
				else
					@state = :desync
				end
			when :synced
				@pload = []
				@length = b.ord
				if @length > 0
					@state = :reading
				else
					@state = :csum
				end
			when :reading
				@pload << b
				if @pload.size == @length
					@state = :csum
				end
			when :csum
				dbug_out = proc do |msg|
					if $VERBOSE || $DEBUG
						STDERR.puts "YamahaPacketCodec#streaming_decode: #{msg}"
					end
				end
				pload_hex = @pload.map { |x| "%02x" % x.ord }.join
				if valid_csum?(b.ord)
					dbug_out["Received valid: #{pload_hex}"]
					@ingest_cb.call(@pload) if @ingest_cb
				else
					dbug_out["Received invalid csum (#{b}): #{pload_hex}"]
				end
				@pload = []
				@length = 0
				@state = :desync
			end
			self
		end
		self
	end

	# Compute checksum for payload.
	#
	# @param len [Integer] length of the payload
	# @param pload [Array<Integer>, String] payload to checksum
	# @return [Byte] one byte checksum (Integer in the range of 0..255)
	def self.csum(len, pload)
		-(len + pload.sum) & 0xff
	end

	# Is this a valid checksum for the payload we have?
	#
	# @param csum [Byte] checksum to verify against
	def valid_csum?(csum)
		self.class.csum(@length, @pload) == csum
	end
	private :valid_csum?

	# Encode given packet.
	#
	# Can come either as fully formed (`ccaa020305f6`),
	# as a simple hex encoded payload (`0305`),
	# or as a byte array (`[3, 5]`).
	#
	# In the fully formed case the format isn't validated,
	# so you can shoot yourself in the foot by sending invalid
	# packet and de-syncing the receiver.
	#
	# @param packet [Array<Integer>, String] packet to encode, see above for format.
	# @return [String] encoded packet
	def self.encode(packet)
		if packet.kind_of?(String)
			if /^ccaa([0-9a-f]{2})+$/i =~ packet
				packet.scan(/../).map {|x| x.to_i(16).chr }.join
			elsif /^([0-9a-f]{2})+$/i =~ packet
				pload = packet.scan(/../).map {|x| x.to_i(16) }
				csum = csum(pload.size, pload)
				[0xcc, 0xaa, pload.size, *pload, csum].map(&:chr).join
			else
				raise ArgumentError, "either array of numbers (bytes), or hexa string, please"
			end
		else
			pload = Array(packet)
			csum = csum(pload.size, pload)
			[0xcc, 0xaa, pload.size, *pload, csum].map(&:chr).join
		end
	end
end

# Serial interface input worker -- intended as a processing thread.
class YamahaSerialInputWorker
	# Run the worker (within a thread).
	#
	# @param device [String] the serial device to run on
	# @param remote_instance [Object] the processor of the incoming packets (and supplier of outgoing)
	# @param heartbeat_interval [Integer] how often to send heratbeat messages (in seconds)
	# @return [nil] Never returns (intended to get killed). Retries Errno::EIO, but other
	#   exceptions kill it.
	def self.as_thread(device, remote_instance, heartbeat_interval = 5)
		begin
			SerialPort.open(device, {baud: 115200}) do |sp|
				sp.set_encoding('ASCII-8BIT')
				sp.flow_control = SerialPort::HARD
				sp.sync = true
				sp.read_timeout = -1 # all data, no wait

				remote_instance.handle_received(:reset)

				ypc = YamahaPacketCodec.new do |pkt|
					STDERR.puts "YamahaSerialInputWorker: Incoming packet: #{pkt.map { |x| "%02x" % x }.join}" if $DEBUG || $VERBOSE
					remote_instance.handle_received(pkt)
				end

				last_heartbeat_at = Time.now # no hartbeat initially
				loop do
					wait = true
					data=sp.read
					if data.nil? || data.empty?
						# nothing
					else
						ypc.streaming_decode(data)
						wait = false
					end
					if last_heartbeat_at + heartbeat_interval < Time.now
						remote_instance.handle_received(:heartbeat)
						last_heartbeat_at = Time.now
					end
					if cmd = remote_instance.pop
						wait = false
						STDERR.puts "YamahaSerialInputWorker: Sending: #{cmd.bytes.map { |x| "%02x" % x }.join}" if $DEBUG || $VERBOSE
						sp.write(cmd)
					end
					sleep 0.05 if wait
				end
			end
		rescue Errno::EIO
			STDERR.puts "YamahaSerialInputWorker: Got Errno::EIO: #$!"
			retry
		end
	end
end
