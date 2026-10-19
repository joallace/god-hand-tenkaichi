class_name NetTuning
extends Resource
## Online play (SPEC_ONLINE.md). Edit data/tuning/net.tres. Frames are sim
## ticks at 60 Hz. Starting picks, not playtested.

@export_group("Connection")
## UDP port a host binds by default (settings can override it).
@export_range(1024, 65535) var default_port: int = 7777
## Humans per session, across every machine.
@export_range(1, 8) var max_humans: int = 4
## Fighters per lobby (humans + CPUs).
@export_range(2, 8) var max_fighters: int = 4
## Local players one machine may bring into an online lobby (milestone 5
## raises it for couch + online).
@export_range(1, 4) var max_local_players_online: int = 1
## Packets larger than this are dropped unread.
@export_range(256, 65536) var max_packet_bytes: int = 4096
## Bulk (snapshot) payloads larger than this are dropped unread.
@export_range(1024, 16777216) var max_bulk_bytes: int = 4194304
## Longest profile name, in characters.
@export_range(1, 64) var name_max_len: int = 16
## A peer silent for this many frames is dropped.
@export_range(30, 3600) var disconnect_timeout_frames: int = 180
## Frames between PINGs on each link.
@export_range(1, 600) var ping_interval_frames: int = 30
## Round-trip samples averaged per link.
@export_range(1, 120) var rtt_samples: int = 8

@export_group("Rollback")
## Furthest the sim may run ahead of the oldest unconfirmed remote input.
@export_range(1, 30) var max_rollback_frames: int = 8
## Auto input delay bounds (frames).
@export_range(0, 10) var input_delay_min: int = 1
@export_range(0, 10) var input_delay_max: int = 6
## Frames of latency the auto input delay leaves to rollback.
@export_range(0, 10) var rollback_comfort: int = 3
## Ticks run in one frame at most when catching up after a hitch.
@export_range(1, 16) var max_catchup_ticks: int = 4
## Frames stalled before "Waiting for <name>…" shows.
@export_range(1, 600) var stall_warning_frames: int = 30

@export_group("Time sync")
## Frame-advantage samples averaged.
@export_range(1, 600) var timesync_window: int = 60
## Frames ahead of a peer (averaged) before this peer starts waiting.
@export_range(0.0, 10.0) var timesync_threshold: float = 1.5
## At most one wait frame every this many frames.
@export_range(1, 600) var timesync_interval: int = 20

@export_group("Desync")
## Confirmed ticks between state hash exchanges.
@export_range(1, 600) var checksum_interval: int = 30
## Resyncs allowed before the match ends with a desync error.
@export_range(0, 100) var max_resyncs_per_match: int = 3
## Confirmed checkpoints (state + hash) kept for comparison / resync.
@export_range(1, 60) var checkpoints_kept: int = 4
## Ticks of input kept in a desync dump.
@export_range(0, 6000) var desync_dump_input_ticks: int = 600

@export_group("Presentation")
## A cosmetic event first seen during a resim still plays if its tick is
## within this many frames of now.
@export_range(0, 30) var late_fx_window: int = 6
## Lobby countdown once every human is ready.
@export_range(0, 600) var lobby_countdown_frames: int = 180

@export_group("Storage")
## Rolling auto-saved replays kept (user://replays/last_<n>.ghr).
@export_range(0, 100) var replay_keep_count: int = 10
## Confirmed ticks between hashes stored in a replay.
@export_range(1, 600) var replay_hash_interval: int = 30
## Recent hosts remembered by the join screen.
@export_range(0, 50) var recent_hosts_max: int = 8
