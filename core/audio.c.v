module core

#include "@VROOT/core/blip_buf.c"

[heap]
struct C.blip_t {}

fn C.blip_new(int) &C.blip_t

fn C.blip_add_delta(&C.blip_t, u32, int)

const (
	wave_pattern = [[i32(-1),-1,-1,-1,1,-1,-1,-1]!,[i32(-1),-1,-1,-1,1,1,-1,-1]!,[i32(-1),-1,1,1,1,1,-1,-1]!,[i32(1),1,1,1,-1,-1,1,1]!]!
	clocks_per_second  = u32(1 << 22)
	clocks_per_frame = u32(clocks_per_second / 512)
	output_sample_count = usize(2000)
	sweep_delay_zero_period = u8(8)

	wave_initial_delay = u32(4)
)

struct VolumeEnvelope {
pub mut:
	period u8
    goes_up bool
    delay u8
    initial_volume u8
    volume u8
}

pub fn new_volume_envelope() &VolumeEnvelope {
	return &VolumeEnvelope {
        period: 0
        goes_up: false
        delay: 0
        initial_volume: 0
        volume: 0
    }
}

pub fn (self &VolumeEnvelope) get(a u16) u8 {
	if (a == 0xFF12) || (a == 0xFF17) || (a == 0xFF2) {
		return u8(((self.initial_volume & 0xF) << 4) | (if self.goes_up { 0x08 } else { 0 }) | (self.period & 0x7))
	} else {
		return 0
	}
}

pub fn (mut self VolumeEnvelope) set(a u16, v u8) {
	if (a == 0xFF12) || (a == 0xFF17) || (a == 0xFF21) {
		self.period = v & 0x7
        self.goes_up = v & 0x8 == 0x8
        self.initial_volume = v >> 4
        self.volume = self.initial_volume
	} else if ((a == 0xFF14) || (a == 0xFF19) || (a == 0xFF23)) && (v & 0x80 == 0x80) {
		self.delay = self.period
        self.volume = self.initial_volume
	}
}

pub fn (mut self VolumeEnvelope) tick() {
	if self.delay > 1 {
		self.delay -= 1
	} else if self.delay == 1 {
		self.delay = self.period
		if self.goes_up && self.volume < 15 {
			self.volume += 1
		} else if !self.goes_up && self.volume > 0 {
			self.volume -= 1
		}
	}
}

struct LengthCounter {
pub mut:
    enabled bool
    value u16
    max u16
}

pub fn new_length_counter(max u16) &LengthCounter {
	return &LengthCounter {
        enabled: false
        value: 0
        max: max
    }
}

fn (self &LengthCounter) is_active() bool {
	return self.value > 0
}

fn (self &LengthCounter) extra_step(frame_step u8) bool {
	return frame_step % 2 == 1
}

fn (mut self LengthCounter) enable(enable bool, frame_step u8) {
	was_enabled := self.enabled
	self.enabled = enable
	if !was_enabled && self.extra_step(frame_step) {
		self.step()
	}
}

fn (mut self LengthCounter) set(minus_value u8) {
	self.value = self.max - minus_value as u16
}

fn (mut self LengthCounter) trigger(frame_step u8) {
	if self.value == 0 {
		self.value = self.max
		if self.extra_step(frame_step) {
			self.step()
		}
	}
}

fn (mut self LengthCounter) step() {
	if self.enabled && self.value > 0 {
		self.value -= 1
	}
}

struct SquareChannel {
pub mut:
    active bool
    dac_enabled bool
    duty u8
    phase u8
    length &LengthCounter
    frequency u16
    period u32
    last_amp i32
    delay u32
    has_sweep bool
    sweep_enabled bool
    sweep_frequency u16
    sweep_delay u8
    sweep_period u8
    sweep_shift u8
    sweep_negate bool
    sweep_did_negate bool
    volume_envelope &VolumeEnvelope
    blip &C.blip_t
}

fn new_square_channel(blip &C.blip_t, with_sweep bool) &SquareChannel {
	return &SquareChannel {
		active: false
		dac_enabled: false
		duty: 1
		phase: 1
		length: new_length_counter(64)
		frequency: 0
		period: 2048
		last_amp: 0
		delay: 0
		has_sweep: with_sweep
		sweep_enabled: false
		sweep_frequency: 0
		sweep_delay: 0
		sweep_period: 0
		sweep_shift: 0
		sweep_negate: false
		sweep_did_negate: false
		volume_envelope: new_volume_envelope()
		blip: blip
	}
}

fn (self &SquareChannel) on() bool {
    return self.active
}

fn (self &SquareChannel) get(a u16) u8 {
    match true {
		a == 0xFF10 {
			return u8(0x80 | ((self.sweep_period & 0x7) << 4) | (if self.sweep_negate { 0x8 } else { 0 }) | (self.sweep_shift & 0x7))
		}
		a == 0xFF11 || a == 0xFF16 {
			return ((self.duty & 3) << 6) | 0x3F
		}
		a == 0xFF12 || a == 0xFF17 {
			return self.volume_envelope.get(a)
		}
		a == 0xFF13 || a == 0xFF18 {
			return 0xff
		}
		a == 0xFF14 || a == 0xFF19 {
			return u8(0x80 | (if self.length.enabled { 0x40 } else { 0 }) | 0x3F)
		}
		else {
			return 0
		}
	}
}

fn (mut self SquareChannel) set(a u16, v u8, frame_step u8) {
	match true {
		a == 0xFF10 {
			self.sweep_period = (v >> 4) & 0x7
			self.sweep_shift = v & 0x7
			old_sweep_negate := self.sweep_negate
			self.sweep_negate = v & 0x8 == 0x8
			if old_sweep_negate && !self.sweep_negate && self.sweep_did_negate {
				self.active = false
			}
			self.sweep_did_negate = false
		}
		a == 0xFF11 || a == 0xFF16 {
			self.duty = v >> 6
			self.length.set(v & 0x3F)
		}
		a == 0xFF12 || a == 0xFF17 {
			self.dac_enabled = v & 0xF8 != 0
			self.active = self.active && self.dac_enabled
		}
		a == 0xFF13 || a == 0xFF18 {
			self.frequency = (self.frequency & 0x0700) | u16(v)
			self.calculate_period()
		}
		a == 0xFF14 || a == 0xFF19 {
			self.frequency = (self.frequency & 0x00FF) | (u16(v & 0b0000_0111) << 8)
			self.calculate_period()

			self.length.enable(v & 0x40 == 0x40, frame_step)
			self.active = self.length.is_active()

			if v & 0x80 == 0x80 {
				if self.dac_enabled {
					self.active = true
				}

				self.length.trigger(frame_step)

				if self.has_sweep {
					self.sweep_frequency = self.frequency
					self.sweep_delay = if self.sweep_period != 0 { self.sweep_period } else { sweep_delay_zero_period }

					self.sweep_enabled = self.sweep_period > 0 || self.sweep_shift > 0
					if self.sweep_shift > 0 {
						self.sweep_calculate_frequency()
					}
				}
			}
		}
		else {}
	}
	self.volume_envelope.set(a, v)
}

fn (mut self SquareChannel) calculate_period() {
	if self.frequency > 2047 { self.period = 0 } else { self.period = (2048 - u32(self.frequency)) * 4 }
}

fn (mut self SquareChannel) run(start_time u32, end_time u32) {
	if !self.active || self.period == 0 {
		if self.last_amp != 0 {
			C.blip_add_delta(self.blip, start_time, -self.last_amp)
			self.last_amp = 0
			self.delay = 0
		}
	}
	else {
		mut time := start_time + self.delay
		pattern := wave_pattern[self.duty]
		vol := i32(self.volume_envelope.volume)

		for time < end_time {
			amp := vol * pattern[self.phase]
			if amp != self.last_amp {
				C.blip_add_delta(self.blip, time, amp - self.last_amp)
				self.last_amp = amp
			}
			time += self.period
			self.phase = (self.phase + 1) % 8
		}

		self.delay = time - end_time
	}
}

fn (mut self SquareChannel) step_length() {
	self.length.step()
	self.active = self.length.is_active()
}

fn (mut self SquareChannel) sweep_calculate_frequency() u16 {
	offset := self.sweep_frequency >> self.sweep_shift

	newfreq := if self.sweep_negate {
		self.sweep_did_negate = true
		u16(self.sweep_frequency - offset)
	}
	else {
		u16(self.sweep_frequency + offset)
	}

	if newfreq > 2047 {
		self.active = false
	}
	return newfreq
}

fn (mut self SquareChannel) step_sweep() {
	if self.sweep_delay > 1 {
		self.sweep_delay -= 1
	}
	else {
		if self.sweep_period == 0 {
			self.sweep_delay = sweep_delay_zero_period
		}
		else {
			self.sweep_delay = self.sweep_period
			if self.sweep_enabled {
				newfreq := self.sweep_calculate_frequency()
				if newfreq <= 2047 {
					if self.sweep_shift != 0 {
						self.sweep_frequency = newfreq
						self.frequency = newfreq
						self.calculate_period()
					}
					self.sweep_calculate_frequency()
				}
			}
		}
	}
}

struct WaveChannel {
pub mut:
    active bool
    dac_enabled bool
    length &LengthCounter
    frequency u16
    period u32
    last_amp i32
    delay u32
    volume_shift u8
    waveram [16]u8
    current_wave u8
    dmg_mode bool
    sample_recently_accessed bool
    blip &C.blip_t
}

fn new_wave_channel(blip &C.blip_t, dmg_mode bool) &WaveChannel {
	return &WaveChannel {
		active: false
		dac_enabled: false
		length: new_length_counter(256)
		frequency: 0
		period: 2048
		last_amp: 0
		delay: 0
		volume_shift: 0
		waveram: [16]u8{init: 0}
		current_wave: 0
		dmg_mode: dmg_mode
		sample_recently_accessed: false
		blip: blip
	}
}

fn (self &WaveChannel) get(a u16) u8 {
	match a {
		0xFF1A {
			return u8((if self.dac_enabled { 0x80 } else { 0 }) | 0x7F)
		}
		0xFF1B { return 0xFF }
		0xFF1C {
			return u8(0x80 | ((self.volume_shift & 0b11) << 5) | 0x1F)
		}
		0xFF1D { return 0xFF }
		0xFF1E {
			return u8(0x80 | if self.length.enabled { 0x40 } else { 0 } | 0x3F)
		}
		else {
			if a >= 0xff30 && a <= 0xff3f {
				if !self.active {
					return self.waveram[a - 0xFF30]
				} else {
					if !self.dmg_mode || self.sample_recently_accessed {
						return self.waveram[usize(self.current_wave) >> 1]
					} else {
						return 0xFF
					}
				}
			}
			return 0
		}
	}
}

fn (mut self WaveChannel) set(a u16, v u8, frame_step u8) {
	match a {
		0xFF1A {
			self.dac_enabled = (v & 0x80) == 0x80
            self.active = self.active && self.dac_enabled
		}
		0xFF1B { self.length.set(v) }
		0xFF1C {
			self.volume_shift = (v >> 5) & 0b11
		}
		0xFF1D {
			self.frequency = (self.frequency & 0x0700) | u16(v)
            self.calculate_period()
		}
		0xFF1E {
			self.frequency = (self.frequency & 0x00FF) | (u16(v & 0b111) << 8)
			self.calculate_period()

			self.length.enable(v & 0x40 == 0x40, frame_step)
			self.active = self.length.is_active()

			if v & 0x80 == 0x80 {
				self.dmg_maybe_corrupt_waveram()

				self.length.trigger(frame_step)

				self.current_wave = 0
				self.delay = self.period + wave_initial_delay

				if self.dac_enabled {
					self.active = true
				}
			}
		}
		else {
			if a >= 0xff30 && a <= 0xff3f {
				if !self.active {
                    self.waveram[usize(a) - 0xFF30] = v
                } else {
                    if !self.dmg_mode || self.sample_recently_accessed {
                        self.waveram[usize(self.current_wave) >> 1] = v
                    }
                }
			}
		}
	}
}

fn (mut self WaveChannel) calculate_period() {
	if self.frequency > 2048 { self.period = 0 } else { self.period = (2048 - u32(self.frequency)) * 2 }
}

fn (mut self WaveChannel) run(start_time u32, end_time u32) {
	self.sample_recently_accessed = false
	if !self.active || self.period == 0 {
		if self.last_amp != 0 {
			C.blip_add_delta(self.blip, start_time, -self.last_amp)
			self.last_amp = 0
			self.delay = 0
		}
	} else {
		mut time := start_time + self.delay
		volshift := match self.volume_shift {
			0 { 4 + 2 }
			1 { 0 }
			2 { 1 }
			3 { 2 }
			else {panic("")}
		}

		for time < end_time {
			wavebyte := self.waveram[usize(self.current_wave) >> 1]
			sample := if self.current_wave % 2 == 0 { wavebyte >> 4 } else { wavebyte & 0xF }

			 amp := i32((sample << 2) >> volshift)

			if amp != self.last_amp {
				C.blip_add_delta(self.blip, time, amp - self.last_amp)
				self.last_amp = amp
			}

			if time >= end_time - 2 {
				self.sample_recently_accessed = true
			}
			time += self.period
			self.current_wave = (self.current_wave + 1) % 32
		}

		self.delay = time - end_time
	}
}

fn (mut self WaveChannel) step_length() {
	self.length.step()
	self.active = self.length.is_active()
}

fn (mut self WaveChannel) dmg_maybe_corrupt_waveram() {
	if !self.dmg_mode || !self.active || self.delay != 0 {
		return
	}

	byteindex := usize((self.current_wave + 1) % 32) >> 1

	if byteindex < 4 {
		self.waveram[0] = self.waveram[byteindex]
	}
	else {
		blockstart := byteindex & 0b1100
		self.waveram[0] = self.waveram[blockstart]
		self.waveram[1] = self.waveram[blockstart + 1]
		self.waveram[2] = self.waveram[blockstart + 2]
		self.waveram[3] = self.waveram[blockstart + 3]
	}	
}

struct NoiseChannel {
pub mut:
    active bool
    dac_enabled bool
    reg_ff22 u8
    length &LengthCounter
    volume_envelope &VolumeEnvelope
    period u32
    shift_width u8
    state u16
    delay u32
    last_amp i32
    blip &C.blip_t
}

pub fn new(blip &C.blip_t) &NoiseChannel {
	return &NoiseChannel {
		active: false
		dac_enabled: false
		reg_ff22: 0
		length: new_length_counter(64)
		volume_envelope: new_volume_envelope()
		period: 2048
		shift_width: 14
		state: 1
		delay: 0
		last_amp: 0
		blip: blip
	}
}

fn (self &NoiseChannel) get(a u16) u8 {
	match a {
		0xFF20 { return 0xFF }
		0xFF21 { return self.volume_envelope.get(a) }
		0xFF22 {
			return self.reg_ff22
		}
		0xFF23 {
			return u8(0x80 | if self.length.enabled { 0x40 } else { 0 } | 0x3F)
		}
		else { return 0 }
	}
}

fn (mut self NoiseChannel) set(a u16, v u8, frame_step u8) {
	match a {
		0xFF20 { self.length.set(v & 0x3F) }
		0xFF21 {
			self.dac_enabled = v & 0xF8 != 0
			self.active = self.active && self.dac_enabled
		}
		0xFF22 {
			self.reg_ff22 = v
			self.shift_width = u8(if v & 8 == 8 { 6 } else { 14 })
			freq_div := match v & 7 {
				0 { 8 }
				else { (u32(v & 7) + 1) * 16 }
			}
			self.period = u32(freq_div) << (v >> 4)
		}
		0xFF23 {
			self.length.enable(v & 0x40 == 0x40, frame_step)
			self.active = self.length.is_active()

			if v & 0x80 == 0x80 {
				self.length.trigger(frame_step)

				self.state = 0xFF
				self.delay = 0

				if self.dac_enabled {
					self.active = true
				}
			}
		}
		else {}
	}
	self.volume_envelope.set(a, v)
}

fn (self &NoiseChannel) on() bool {
    return self.active
}