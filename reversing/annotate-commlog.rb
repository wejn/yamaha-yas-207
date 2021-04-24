#!/usr/bin/env ruby

# this reads whatever parse-btsnoop.* spits out and annotates known messages

known = {
	"ccaa0340784afb" => "set input hdmi",
	"ccaa034078d174" => "set input analog",
	"ccaa034078291c" => "set input bluetooth",
	"ccaa034078df66" => "set input tv",
	"ccaa020311ea" => "input followup",

	"ccaa034078c97c" => "set 3d surround",
	"ccaa03407ef14e" => "set tvprogram",
	"ccaa03407850f5" => "set stereo",
	"ccaa034078d96c" => "set movie",
	"ccaa034078da6b" => "set music",
	"ccaa034078db6a" => "set sports",
	"ccaa034078dc69" => "set game",
	"ccaa03407e80bf" => "set clearvoice",
	"ccaa03407e82bd" => "unset clearvoice",
	"ccaa0340786fd6" => "unset bass ext",
	"ccaa0340786ed7" => "set bass ext",
	"ccaa020315e6" => "surround followup",

	"ccaa0340784cf9" => "sw up",
	"ccaa0340784df8" => "sw down",
	"ccaa020313e8" => "subwoofer followup",

	"ccaa090148545320436f6e7453" => "init",
	"ccaa03020001fa" => "init followup",

	"ccaa03407ea29d" => "mute on",
	"ccaa03407ea39c" => "mute off",
	"ccaa0340781e27" => "volume up",
	"ccaa0340781f26" => "volume down",
	"ccaa020312e9" => "volume/mute followup",

	"ccaa0340787fc6" => "turn off",
	"ccaa020305f6" => "status req",

	# inferred
	"ccaa080400013219020a009c" => "rx device id",
	"ccaa03000200fb" => "rx init fu reply",
}

def diff(fst, snd)
	if fst == snd
		"{}"
	else
		"{" + fst.scan(/../).zip(snd.scan(/../)).map { |(x,y)| x == y ? x : "[#{x}→#{y}]" }.join + "}"
	end
end

def diff_factory(field)
	lambda { |state, msg| out = if state[field] then diff(state[field], msg) else "" end; state[field] = msg; out }
end

becv = lambda { |f| out = []; out << "bassext" unless (f&0x20).zero?; out << "clearvoice" unless (f&0x4).zero?; out.join('+') }
#                                          ccaa++0500++  ++  ++++  ++  202000  ++++  ++  ++
#                                          .... <-- sync header
#                                              .. <-- payload length
#                                                .. <-- very likely response id
#                                                  .. <-- no clue
#                                                    .. <-- powered on? (01 = yes, 00 = no)
#                                                                      ...... <-- no clue
#                                                                                        .. <-- payload csum; see verify-csum.rb
#                                          missing: backlight intensity, bluetooth standby
status_parser = lambda { |_, msg| msg =~ /(ccaa0d05..)(..)(..)(..)(..)(..)(......)(....)(..)(..)/ ? "<pwr:#{$2.to_i.zero? ? false : true},inp:#$3,muted:#{$4.to_i.zero? ? false : true},vol:#$5,sw:#$6,srd:#$8,becv:#{becv.call($9.to_i(16))}>" : "<?>" }
# becv: 20 bass ext on, 4 clear voice on

prefix_action = {
	"ccaa0d05" => [diff_factory(:status), status_parser],
	"ccaa0211" => diff_factory(:input),
	"ccaa0312" => diff_factory(:vol),
	"ccaa0213" => diff_factory(:woofer),
	"ccaa0515" => diff_factory(:surround),
	#^^^^-- sync header
	#    ^^-- seems to indicate length of the payload
	#      ^^-- seems to indicate id of the payload
}

def beautify_payload(pkt)
	if pkt =~ /^(ccaa)(..)(.*)(..)$/
		"#{pkt} ((#$3))"
	else
		pkt
	end
end

state = {}

STDIN.sync = true
STDOUT.sync = true
STDIN.each do |ln|
	pkt, dir, pd, _ = ln.strip.split(/\s+/)
	if known[pd]
		puts "#{pkt} #{dir} #{beautify_payload(pd)} [#{known[pd]}]"
	else
		annot = ""
		for pfx, action in prefix_action
			if pd.start_with?(pfx)
				annot = Array(action).map { |a| a.call(state, pd) }.join(' ')
				break
			end
		end
		puts "#{pkt} #{dir} #{beautify_payload(pd)}#{annot.empty? ? "" : " " + annot}"
	end
end
