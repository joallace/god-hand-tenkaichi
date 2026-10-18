extends RefCounted
## Port of the sfxr synthesizer (DrPetter, 2007, public domain): renders an
## SfxrParams set to mono samples exactly like sfxr's "Export .WAV" (44.1 kHz,
## 8x supersampling, same filters/phaser/envelope), so .sfs files sound the
## same here and in sfxr.exe. The only randomness (noise waveform) comes from
## a seeded RNG, so renders are reproducible.

const SfxrParams := preload("res://tools/sfxr/sfxr_params.gd")

const SAMPLE_RATE := 44100
const SUPERSAMPLE := 8
const MASTER_VOL := 0.05
## sfxr's "arbitrary gain to get reasonable output volume" on WAV export.
const EXPORT_GAIN := 4.0
const PHASER_SIZE := 1024
const NOISE_SIZE := 32
## Hard stop for sounds whose envelope never ends (e.g. NaN params).
const MAX_SECONDS := 10.0

var p: SfxrParams
var _rng := RandomNumberGenerator.new()

var _playing := false
var _phase := 0
var _fperiod := 0.0
var _fmaxperiod := 0.0
var _fslide := 0.0
var _fdslide := 0.0
var _period := 0
var _square_duty := 0.0
var _square_slide := 0.0
var _env_stage := 0
var _env_time := 0
var _env_length: Array[int] = [0, 0, 0]
var _env_vol := 0.0
var _fphase := 0.0
var _fdphase := 0.0
var _iphase := 0
var _phaser_buffer := PackedFloat32Array()
var _ipp := 0
var _noise_buffer := PackedFloat32Array()
var _fltp := 0.0
var _fltdp := 0.0
var _fltw := 0.0
var _fltw_d := 0.0
var _fltdmp := 0.0
var _fltphp := 0.0
var _flthp := 0.0
var _flthp_d := 0.0
var _vib_phase := 0.0
var _vib_speed := 0.0
var _vib_amp := 0.0
var _rep_time := 0
var _rep_limit := 0
var _arp_time := 0
var _arp_limit := 0
var _arp_mod := 0.0


## Render `params` to samples in -1..1 (sfxr export levels).
static func render(params: SfxrParams, rng_seed: int = 0) -> PackedFloat32Array:
	var s: RefCounted = (load("res://tools/sfxr/sfxr_synth.gd") as GDScript).new()
	return s._render(params, rng_seed)


## 16-bit mono AudioStreamWAV from samples (scaled by `gain`, clipped).
static func to_stream(samples: PackedFloat32Array, gain: float = 1.0) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i] * gain, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SAMPLE_RATE
	w.stereo = false
	w.data = data
	return w


static func peak(samples: PackedFloat32Array) -> float:
	var m := 0.0
	for v in samples:
		m = maxf(m, absf(v))
	return m


func _render(params: SfxrParams, rng_seed: int) -> PackedFloat32Array:
	p = params
	_rng.seed = rng_seed
	_reset_sample(false)
	_playing = true
	var out := PackedFloat32Array()
	var max_len := int(MAX_SECONDS * SAMPLE_RATE)
	while _playing and out.size() < max_len:
		out.append(_synth_sample())
	return out


func _frnd(range_: float) -> float:
	return _rng.randf() * range_


func _reset_sample(restart: bool) -> void:
	if not restart:
		_phase = 0
	_fperiod = 100.0 / (p.base_freq * p.base_freq + 0.001)
	_period = int(_fperiod)
	_fmaxperiod = 100.0 / (p.freq_limit * p.freq_limit + 0.001)
	_fslide = 1.0 - pow(p.freq_ramp, 3.0) * 0.01
	_fdslide = -pow(p.freq_dramp, 3.0) * 0.000001
	_square_duty = 0.5 - p.duty * 0.5
	_square_slide = -p.duty_ramp * 0.00005
	if p.arp_mod >= 0.0:
		_arp_mod = 1.0 - pow(p.arp_mod, 2.0) * 0.9
	else:
		_arp_mod = 1.0 + pow(p.arp_mod, 2.0) * 10.0
	_arp_time = 0
	_arp_limit = int(pow(1.0 - p.arp_speed, 2.0) * 20000 + 32)
	if p.arp_speed == 1.0:
		_arp_limit = 0
	if restart:
		return
	# filters
	_fltp = 0.0
	_fltdp = 0.0
	_fltw = pow(p.lpf_freq, 3.0) * 0.1
	_fltw_d = 1.0 + p.lpf_ramp * 0.0001
	_fltdmp = minf(5.0 / (1.0 + pow(p.lpf_resonance, 2.0) * 20.0) * (0.01 + _fltw), 0.8)
	_fltphp = 0.0
	_flthp = pow(p.hpf_freq, 2.0) * 0.1
	_flthp_d = 1.0 + p.hpf_ramp * 0.0003
	# vibrato
	_vib_phase = 0.0
	_vib_speed = pow(p.vib_speed, 2.0) * 0.01
	_vib_amp = p.vib_strength * 0.5
	# envelope
	_env_vol = 0.0
	_env_stage = 0
	_env_time = 0
	_env_length = [
		int(p.env_attack * p.env_attack * 100000.0),
		int(p.env_sustain * p.env_sustain * 100000.0),
		int(p.env_decay * p.env_decay * 100000.0),
	]
	# phaser
	_fphase = pow(p.pha_offset, 2.0) * 1020.0
	if p.pha_offset < 0.0:
		_fphase = -_fphase
	_fdphase = pow(p.pha_ramp, 2.0)
	if p.pha_ramp < 0.0:
		_fdphase = -_fdphase
	_iphase = absi(int(_fphase))
	_ipp = 0
	_phaser_buffer.resize(PHASER_SIZE)
	_phaser_buffer.fill(0.0)
	_noise_buffer.resize(NOISE_SIZE)
	_refill_noise()
	# repeat
	_rep_time = 0
	_rep_limit = int(pow(1.0 - p.repeat_speed, 2.0) * 20000 + 32)
	if p.repeat_speed == 0.0:
		_rep_limit = 0


func _refill_noise() -> void:
	for i in NOISE_SIZE:
		_noise_buffer[i] = _frnd(2.0) - 1.0


func _synth_sample() -> float:
	_rep_time += 1
	if _rep_limit != 0 and _rep_time >= _rep_limit:
		_rep_time = 0
		_reset_sample(true)

	# frequency envelopes / arpeggio
	_arp_time += 1
	if _arp_limit != 0 and _arp_time >= _arp_limit:
		_arp_limit = 0
		_fperiod *= _arp_mod
	_fslide += _fdslide
	_fperiod *= _fslide
	if _fperiod > _fmaxperiod:
		_fperiod = _fmaxperiod
		if p.freq_limit > 0.0:
			_playing = false
	var rfperiod := _fperiod
	if _vib_amp > 0.0:
		_vib_phase += _vib_speed
		rfperiod = _fperiod * (1.0 + sin(_vib_phase) * _vib_amp)
	_period = maxi(int(rfperiod), 8)
	_square_duty = clampf(_square_duty + _square_slide, 0.0, 0.5)

	# volume envelope (lengths guarded: sfxr divides by zero here)
	_env_time += 1
	if _env_time > _env_length[_env_stage]:
		_env_time = 0
		_env_stage += 1
		if _env_stage == 3:
			_playing = false
			return 0.0
	var len_ := maxi(_env_length[_env_stage], 1)
	match _env_stage:
		0: _env_vol = float(_env_time) / len_
		1: _env_vol = 1.0 + (1.0 - float(_env_time) / len_) * 2.0 * p.env_punch
		2: _env_vol = 1.0 - float(_env_time) / len_

	# phaser step
	_fphase += _fdphase
	_iphase = mini(absi(int(_fphase)), PHASER_SIZE - 1)
	if _flthp_d != 0.0:
		_flthp = clampf(_flthp * _flthp_d, 0.00001, 0.1)

	var ssample := 0.0
	for _si in SUPERSAMPLE:
		var sample := 0.0
		_phase += 1
		if _phase >= _period:
			_phase %= _period
			if p.wave_type == SfxrParams.Wave.NOISE:
				_refill_noise()
		var fp := float(_phase) / _period
		match p.wave_type:
			SfxrParams.Wave.SQUARE: sample = 0.5 if fp < _square_duty else -0.5
			SfxrParams.Wave.SAWTOOTH: sample = 1.0 - fp * 2.0
			SfxrParams.Wave.SINE: sample = sin(fp * TAU)
			SfxrParams.Wave.NOISE: sample = _noise_buffer[_phase * NOISE_SIZE / _period]
		# low-pass filter
		var pp := _fltp
		_fltw = clampf(_fltw * _fltw_d, 0.0, 0.1)
		if p.lpf_freq != 1.0:
			_fltdp += (sample - _fltp) * _fltw
			_fltdp -= _fltdp * _fltdmp
		else:
			_fltp = sample
			_fltdp = 0.0
		_fltp += _fltdp
		# high-pass filter
		_fltphp += _fltp - pp
		_fltphp -= _fltphp * _flthp
		sample = _fltphp
		# phaser
		_phaser_buffer[_ipp & (PHASER_SIZE - 1)] = sample
		sample += _phaser_buffer[(_ipp - _iphase + PHASER_SIZE) & (PHASER_SIZE - 1)]
		_ipp = (_ipp + 1) & (PHASER_SIZE - 1)
		ssample += sample * _env_vol

	ssample = ssample / SUPERSAMPLE * MASTER_VOL
	ssample *= 2.0 * p.sound_vol
	ssample *= EXPORT_GAIN
	return clampf(ssample, -1.0, 1.0)
