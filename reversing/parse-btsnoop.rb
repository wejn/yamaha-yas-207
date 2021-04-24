#!/usr/bin/env ruby

# Parse btsnoop_hci.log [BTSnoop version 1, HCI UART (H4)] file,
# typically coming from Android.
#
# Author: Michal Jirku
# Link: https://wejn.org/2021/04/yas-207-bluetooth-protocol-first-steps/
# License: GPL2? I don't know.
#
# ============================================================================
# WARNING:
#
# This is not a production-ready code. By running it you risk that it will:
#
# - crash your brand spanking new Tesla
# - eat your cat
# - spend all your credit card balance on a new iPhone 17XXL
# - sell all your NFTs and give the proceeds to Gates foundation
#
# Use wireshark (tshark) instead. Seriously. See the link above.
# ============================================================================

f = File.open(ARGV.first)
# header is 8B string, 4B version, 4B type
raise "unsupported file format" unless f.read(8) == "btsnoop\0"
raise "only v1 supported" unless 1 == f.read(4).unpack('N').first
raise "only HCI UART (H4) supported" unless 1002 == f.read(4).unpack('N').first


STATUSES = {
	0 => [:sent, :data],
	1 => [:rcvd, :data],
	2 => [:sent, :cmd],
	3 => [:rcvd, :evt],
}
def parse_flags(pf)
	STATUSES[pf] || [:invalid]
end

def next_record(f, ots)
	# record is: original_length/4B, included_length/4B, packet_flags/4B, cumulative_drops/4B, timestamp/8B, data/?B
	header = f.read(4+4+4+4+8)
	return nil if header.nil?
	raise "encountered packet too short" if header.size != 24
	ol, il, pf, _, ts = header.unpack('NNNNQ>')
	[ots||ts, [ts-(ots||ts), parse_flags(pf), f.read(il)]]
end

ts = nil
num = 1
active_rfcomm = {}
$active_pkt = nil

def flush_pkts
	if $active_pkt
		puts "#{$active_pkt[0]} #{$active_pkt[1].to_s.capitalize} #{$active_pkt[2][0..-2].scan(/./m).map { |x| "%02x" % x.ord }.join}"
		$active_pkt = nil
	end
	nil
end

def add_pkt(num, dir, payload, ch)
	if $active_pkt
		if $active_pkt[3] == ch
			$active_pkt[0] = num
			$active_pkt[2] = $active_pkt[2] + payload
		else
			flush_pkts
		end
	else
		$active_pkt = [num, dir, payload, ch]
	end
	nil
end

loop do
	ts, r = next_record(f, ts)
	break if ts.nil?
	if r[2][0].ord == 2 # HCI ACL data
		_hci_meta = r[2][1,2].unpack('S<').first
		hci_bc = _hci_meta >> 14
		hci_pb = (_hci_meta >> 12) & 0x3
		hci_ch = _hci_meta & 0b111111111111
		#p [num, "%04x" % hci_meta, "%016b" % hci_meta, hci_pb, hci_bc, "%04x" % hci_ch]
		if (hci_pb & 1).zero? # first in line -> not a fragment
			flush_pkts
			hci_acl_len = r[2][3,2].unpack('S<').first
			l2cap_len = r[2][5,2].unpack('S<').first
			l2cap_cid = r[2][7,2].unpack('S<').first
			if l2cap_cid == 1
				sig_code = r[2][9].ord
				case sig_code
				when 2 # connection request
					cr_ident = r[2][10].ord
					cr_psm = r[2][13,2].unpack('S<').first
					cr_cid = r[2][15,2].unpack('S<').first
					if cr_psm == 3
						p [num, :rfcomm_conn, "%04x" % cr_cid] if $VERBOSE
						active_rfcomm[cr_cid] = true
					end
				when 3 # connection response
					cr_ident = r[2][10].ord
					cr_dst = r[2][13,2].unpack('S<').first
					cr_src = r[2][15,2].unpack('S<').first
					if active_rfcomm[cr_src]
						active_rfcomm[cr_dst] = true
						p [num, :rfcomm_conn_resp, "%04x" % cr_dst, "%04x" % cr_src] if $VERBOSE
					end
				when 6 # disconnection request
					cr_ident = r[2][10].ord
					cr_dst = r[2][13,2].unpack('S<').first
					cr_src = r[2][15,2].unpack('S<').first
					if active_rfcomm[cr_dst]
						p [num, :rfcomm_disconn, "%04x" % cr_dst] if $VERBOSE
						active_rfcomm.delete(cr_src)
						active_rfcomm.delete(cr_dst)
					end
				end
			end
			cft = r[2][10].ord
			if r[2].size > 10 && [0xff, 0xef].include?(cft) # UIH
				chan = (r[2][9].ord >> 3)
				if !chan.zero? && active_rfcomm[l2cap_cid] # not zero chan, and active channel
					if r[2][11].ord > 1 # payload > 1 (because one byte crc)
						dir = r[1].include?(:sent) ? :sent : :rcvd
						pload = r[2][(cft == 0xff ? 13 : 12)..-1]
						add_pkt(num, dir, pload, hci_ch)
					end
				end
			end
		else
			add_pkt(num, dir, r[2][5..-1], hci_ch) if $active_pkt
		end
	end
	# and now do something with the data... wireshark can help.
	num += 1
end
flush_pkts
