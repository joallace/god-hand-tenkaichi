class_name CombatSystem
extends RefCounted
## Runs once per sim tick after every entity ticked:
##   1. body separation (fighters can't overlap) + arena clamp
##   2. gather all live hitboxes (fighters in slot order, then entities in
##      spawn order) and test them against every other fighter's hurtbox
##      using the pre-resolution state (simultaneous hits trade); the
##      attacker's teammates are skipped unless MatchConfig.friendly_fire
##   3. apply contacts in that same deterministic order: the victim decides
##      the outcome (perfect dodge / invuln / block / hit), the source is told,
##      and hitstop is requested for the attacker, the victim and the hitting
##      entity only (bystanders keep simulating).
## Runs every tick the world isn't frozen. A source in its own hitstop makes
## no new contacts (it's mid-impact); a frozen victim can still be hit by a
## source that isn't frozen.
## Stateless: one-hit-per-victim per activation (or one hit at all for
## single-target hitboxes) is tracked by each CombatEntity. Several victims
## hit by one activation the same tick all apply; hitstop takes the max.

var director: MatchDirector


func _init(p_director: MatchDirector) -> void:
	director = p_director


func resolve(_tick: int) -> void:
	_separate_fighters()
	var radius := director.arena_radius
	for f in director.fighters:
		_clamp_to_arena(f, radius - f.tuning.body_radius)

	var sources: Array[CombatEntity] = []
	for f in director.fighters:
		sources.append(f)
	for e in director.entities:
		if e is CombatEntity and not e.sim_dead:
			sources.append(e)

	var contacts: Array = []  # [Hitbox, Fighter]
	for src in sources:
		if src.hitstop > 0:
			continue
		for hb in src.get_active_hitboxes():
			if src.has_contacted(hb):
				continue
			for victim in director.fighters:
				if victim == hb.attacker or _is_friendly(hb, victim) or src.has_contacted(hb, victim):
					continue
				var hurt := victim.get_hurtbox()
				if hurt.is_empty():
					continue
				if capsules_overlap(hb.a, hb.b, hb.radius, hurt[0], hurt[1], hurt[2]):
					contacts.append([hb, victim])

	for c: Array in contacts:
		var hb: Hitbox = c[0]
		var victim: Fighter = c[1]
		if hb.source.has_contacted(hb, victim):
			continue
		var outcome := victim.receive_hit(hb)
		if outcome == CombatEntity.Contact.NONE:
			continue
		hb.source.on_hitbox_contact(hb, victim, outcome)
		director.request_hitstop([hb.attacker, victim, hb.source], _hitstop_for(hb, victim, outcome))


## Same-team contact, skipped unless MatchConfig.friendly_fire.
func _is_friendly(hb: Hitbox, victim: Fighter) -> bool:
	if hb.attacker == null or hb.attacker.team != victim.team:
		return false
	return director.config == null or not director.config.friendly_fire


func _hitstop_for(hb: Hitbox, victim: Fighter, outcome: CombatEntity.Contact) -> int:
	var t := victim.tuning
	match outcome:
		CombatEntity.Contact.PERFECT_DODGE:
			return t.perfect_dodge_hitstop
		CombatEntity.Contact.BLOCKED:
			return mini(hb.move.hitstop_frames(t), t.hitstop_light)
		CombatEntity.Contact.THROW:
			return 0
	return hb.move.hitstop_frames(t)


## Push overlapping fighters apart equally (horizontal only). Vanished
## fighters are intangible; bodies at very different heights pass.
func _separate_fighters() -> void:
	var fs := director.fighters
	for i in fs.size():
		for j in range(i + 1, fs.size()):
			var a := fs[i]
			var b := fs[j]
			if a.is_vanished() or b.is_vanished():
				continue
			if absf(a.global_position.y - b.global_position.y) >= a.tuning.body_height:
				continue
			var d := b.global_position - a.global_position
			d.y = 0.0
			var min_d := a.tuning.body_radius + b.tuning.body_radius
			var dist := d.length()
			if dist >= min_d:
				continue
			var n := d / dist if dist > 0.0001 else Vector3.RIGHT
			var push := n * ((min_d - dist) * 0.5)
			a.global_position -= push
			b.global_position += push


static func _clamp_to_arena(e: Node3D, max_r: float) -> void:
	var p := e.global_position
	var h := Vector2(p.x, p.z)
	if h.length() > max_r:
		h = h.normalized() * max_r
		e.global_position = Vector3(h.x, p.y, h.y)


static func capsules_overlap(a0: Vector3, a1: Vector3, ra: float, b0: Vector3, b1: Vector3, rb: float) -> bool:
	var pts := Geometry3D.get_closest_points_between_segments(a0, a1, b0, b1)
	return pts[0].distance_to(pts[1]) <= ra + rb
