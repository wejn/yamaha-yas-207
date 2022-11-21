# Yamaha YAS-207

This repository hosts (some of) the code to remotely control
a Yamaha YAS-207 soundbar.

It's part of a multi-weekend project to build an [AirPlay speaker
using the YAS-207 and Raspberry Pi](https://wejn.org/2021/04/multi-weekend-project-reversing-yamaha-yas-207-remote-control/).

## Contents / usage

For contents of the `reversing` directory see [Yamaha YAS-207's Bluetooth protocol
reversed](https://wejn.org/2021/04/yas-207-bluetooth-protocol-reversed/).

For usage instructions of the `control` directory please see [Yamaha YAS-207's
Minimal Client (and a Soundbar Fake)](http://wejn.org/2021/04/yas-207-minimal-client-and-a-soundbar-fake/).

## Minimal viable control

@jmiskovic mentioned in [Issue #1](https://github.com/wejn/yamaha-yas-207/issues/1)
that there's an easy way to get started with just shell:

``` sh
# Valid for YAS-107 (& also YAS-207)
sudo -s
bt-device -l | grep YAS                # find out the device address
rfcomm bind rfcomm0 C8:84:xx:xx:xx:xx  # bind bluetooth device to /dev/rfcomm0 serial

echo -en "\xCC\xAA\x03\x40\x78\x4A\xFB" > /dev/rfcomm0   # change the input to HDMI
echo -en "\xCC\xAA\x03\x40\x78\xD1\x74" > /dev/rfcomm0   # change the input to ANALOG
echo -en "\xCC\xAA\x03\x40\x78\x29\x1C" > /dev/rfcomm0   # change the input to BLUETOOTH
echo -en "\xCC\xAA\x03\x40\x78\xDF\x66" > /dev/rfcomm0   # change the input to TV
echo -en "\xCC\xAA\x03\x40\x78\x1E\x27" > /dev/rfcomm0   # volume +
echo -en "\xCC\xAA\x03\x40\x78\x1F\x26" > /dev/rfcomm0   # volume -
echo -en "\xCC\xAA\x03\x40\x78\x7F\xC6" > /dev/rfcomm0   # power off
```

For more commands you can look at the commands in `control.rb`, but you'll have to come
up with the checksum. So maybe:

``` sh
$ cd control/
$ f(){ ruby -e '$:<<"."; require "common.rb"' \
  -e 'print YamahaPacketCodec.encode(ARGV.map { |x| x.to_i(16) })' "$@"; }
$ f 40 78 4a | xxd
00000000: ccaa 0340 784a fb                        ...@xJ.
```

## Credits

* Author: Michal Jirku (wejn.org)
* License: GNU Affero General Public License v3.0
