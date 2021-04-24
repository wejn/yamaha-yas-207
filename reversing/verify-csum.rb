#!/usr/bin/env ruby

=begin
Based on observation (every time there's a change in the string, the last byte changes) it looks like the general packet structure is:

<0xcc 0xaa><payload length (1 byte)><payload (N bytes)><checksum>

That makes a lot of sense -- you need to sync to the start of frame somehow, hence the ccaa prefix.
And then you need to know how long the packet is.

Question is, how is the checksum generated.

Now based on these samples (I captures from btsnoop and parsed using annotate-commlog.rb):

{ccaa031200[0a->0b][e1->e0]}
{ccaa0d0500010500[09->0b]10202000000320[6c->6a]}
{ccaa031200[0b->0c][e0->df]}
{ccaa0d0500010500[0b->0c]10202000000320[6a->69]}
{ccaa031200[0c->0d][df->de]}
{ccaa05150000[03->0d]20[c3->b9]}
{ccaa05150000[0d->0a]20[b9->bc]}
{ccaa051500[00->01][0a->00]20[bc->c5]}
{ccaa051500[01->00][00->03]20[c5->c3]}
{ccaa05150000[03->08]20[c3->be]}
{ccaa05150000[08->09]20[be->bd]}
{ccaa05150000[09->0c]20[bd->ba]}
{ccaa05150000[0c->0a]20[ba->bc]}
{ccaa0d050001[00->05]000c10202000000a20[67->62]}

It's clear that the checksum isn't CRC, because 1-bit change results in corresponding 1-bit change in the checksum.

What's more, based solely on this:

{ccaa051500[01->00][00->03]20[c5->c3]}

it looks like the payload changed by -1+3=+2 and the csum changed by -2.

So perhaps it's a simple sum, but inverted?

irb(main):001:0> "%x" % (-"ccaa051500010020c5"[0..-3].scan(/../).map { |x| x.to_i(16) }.sum)
=> "..fe4f"

... nope. Maybe without the sync header?

irb(main):002:0> "%x" % (-"ccaa051500010020c5"[4..-3].scan(/../).map { |x| x.to_i(16) }.sum)
=> "..fc5"

... hey, that looks a lot like "c5", but I need to trim it to one byte.

irb(main):003:0> "%02x" % (-"ccaa051500010020c5"[4..-3].scan(/../).map { |x| x.to_i(16) }.sum & 0xff)
=> "c5"

Bingo!

So I'm going to write this script to parse commlog and recompute checksum, to verify there are no nasty little hobbitses. (surprises)

Use thusly:

$ diff -u commlog <(ruby verify-csum.rb < commlog)

Spoiler alert: no surprises, it worked a treat.
=end

def calc_csum(pd)
	"%02x" % (-pd.scan(/../).map { |x| x.to_i(16) }.sum & 0xff)
end

STDIN.each do |ln|
	pkt, dir, pd, _ = ln.strip.split(/\s+/)
	if pd =~ /^ccaa[0-9a-f]+$/
		puts ln.gsub(pd, pd[0..-3] + calc_csum(pd[4..-3]))
	else
		puts ln
	end
end
