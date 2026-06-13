class_name SoundBank
extends Node
## Tiny SFX player: loads the procedural radium-combat cues from assets/audio/
## and plays them by name. Pure presentation — a client of engine signals, it
## holds no rules state. Missing files degrade silently (the game stays playable
## with no audio), so the asset folder is optional.
##
## Add it as a child of a scene, then call play("fire" / "hit" / "explosion").
## A small pool of players per cue lets overlapping shots in a salvo all sound.

const CUES := {
	"fire": "res://assets/audio/fire.wav",
	"hit": "res://assets/audio/hit.wav",
	"explosion": "res://assets/audio/explosion.wav",
}
const POOL_PER_CUE := 4

var _streams: Dictionary = {}                 # name -> AudioStream
var _players: Dictionary = {}                 # name -> Array[AudioStreamPlayer]
var _enabled := true


func _ready() -> void:
	for cue: String in CUES:
		var path: String = CUES[cue]
		if not ResourceLoader.exists(path):
			continue
		var stream := load(path) as AudioStream
		if stream == null:
			continue
		_streams[cue] = stream
		var pool: Array[AudioStreamPlayer] = []
		for _i in POOL_PER_CUE:
			var p := AudioStreamPlayer.new()
			p.stream = stream
			add_child(p)
			pool.append(p)
		_players[cue] = pool


func set_enabled(on: bool) -> void:
	_enabled = on


## Play a cue by name on the next free pooled player (or steal the oldest), with
## an optional volume trim and slight pitch jitter so repeats don't sound canned.
func play(cue: String, volume_db: float = 0.0, pitch_jitter: float = 0.06) -> void:
	if not _enabled or not _players.has(cue):
		return
	var pool: Array = _players[cue]
	var chosen: AudioStreamPlayer = pool[0]
	for p: AudioStreamPlayer in pool:
		if not p.playing:
			chosen = p
			break
	chosen.volume_db = volume_db
	chosen.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	chosen.play()
