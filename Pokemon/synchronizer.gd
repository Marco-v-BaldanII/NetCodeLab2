extends Node
class_name Synchronizer

enum PROTOCOL {
	UDP,
	TCP
}

# ⭐ CORRECT LOCATION: NetMode is defined here.
enum NetMode { DISCONNECTED, HOST, CLIENT }

@onready var parent : Node = $".."
@export var protocol : PROTOCOL = PROTOCOL.UDP
@export var synch_transform : bool
@export var synch_properties : Array[String]
# --- INTERPOLATION EXPORTS ---
@export var interpolate_transform : bool = true
@export var interpolation_delay_ms : int = 150
# ⭐ AUTHORITY MODE: Uses the locally defined NetMode.
@export var authority_mode : NetMode = NetMode.HOST
# --- END EXPORTS ---

var network_object_id : int = -1
var transform_history : Array = []
const HISTORY_MAX_SIZE = 10
var _client_send_timer: float = 0.0


func _ready() -> void:
	# We must assume NetPeer.current_mode is an integer that corresponds to this NetMode enum.
	if NetPeer.current_mode == NetMode.HOST: 
		network_object_id = NetPeer.register_synchronizer(self)
	
	elif NetPeer.current_mode == NetMode.CLIENT:
		# Enable _process if we need to receive (interpolation) OR if we need to send (client authority)
		if interpolate_transform or (authority_mode == NetMode.CLIENT):
			set_process(true)


func _process(delta):
	# ================= 1. INTERPOLATION LOGIC (RECEIVING) =================
	# Use NetMode.CLIENT directly in the condition
	if NetPeer.current_mode == NetMode.CLIENT and interpolate_transform:
		if transform_history.size() < 2:
			pass 
		else:
			# ... (Interpolation logic unchanged)
			var render_time_ms = Time.get_ticks_msec() - interpolation_delay_ms
			
			while transform_history.size() > 2 and transform_history[1][0] < render_time_ms:
				transform_history.pop_front()
			
			if transform_history.size() >= 2:
				var transform_A = transform_history[0][1]
				var time_A = float(transform_history[0][0])
				var transform_B = transform_history[1][1]
				var time_B = float(transform_history[1][0])
				
				var total_time_diff = time_B - time_A
				var current_time_diff = render_time_ms - time_A
				
				if total_time_diff <= 0.0: return
				
				var t = clampf(current_time_diff / total_time_diff, 0.0, 1.0)
				
				parent.global_transform = transform_A.interpolate_with(transform_B, t)
	
	# ================= 2. CLIENT SENDING LOGIC (OWNERSHIP) =================
	
	# The object sends if the current mode matches its authority mode.
	if NetPeer.current_mode == authority_mode:
		_client_send_timer += delta
		if _client_send_timer >= 1.0 / NetPeer.SYNC_RATE_PER_SECOND:
			send()
			_client_send_timer = 0.0


func send(target_peer: StreamPeerTCP = null):
	# 🔴 FIX C: Authority Check Logic uses local NetMode.
	
	if NetPeer.current_mode == NetMode.HOST:
		# Host: Skips sending if the authority is CLIENT.
		if authority_mode == NetMode.CLIENT:
			return 
	elif NetPeer.current_mode == NetMode.CLIENT:
		# Client: Skips sending if the authority is HOST.
		if authority_mode == NetMode.HOST:
			return 
	
	if network_object_id == -1: return

	# ... (Synch data packing unchanged) ...
	var data_dic : Dictionary
	if synch_transform and parent.has_method("get_global_transform"):
		data_dic["global_transform"] = parent.global_transform
	
	for property in synch_properties:
		var value = parent.get(property)
		data_dic[property] = value
	
	var binary_data : PackedByteArray = var_to_bytes(data_dic)
	
	NetPeer.send_synchronization_data(binary_data, network_object_id, target_peer, protocol)


func receive(received_data: PackedByteArray):
	# ... (Receive logic unchanged, uses NetMode.CLIENT locally) ...
	var received_dic: Dictionary = bytes_to_var(received_data)
	
	if typeof(received_dic) != TYPE_DICTIONARY:
		push_error("Failed to deserialize received data into a Dictionary.")
		return
		
	# --------------- RECEIVE TRANSFORM ---------------#
	if synch_transform and received_dic.has("global_transform") and parent.has_method("set_global_transform"):
		var new_transform = received_dic["global_transform"]
		
		if NetPeer.current_mode == NetMode.CLIENT and interpolate_transform:
			# Interpolation buffer logic
			var new_timestamp = Time.get_ticks_msec()
			transform_history.push_back([new_timestamp, new_transform])
			
			while transform_history.size() > HISTORY_MAX_SIZE:
				transform_history.pop_front()
		
		else:
			# Snap (Host or non-interpolated client object)
			parent.global_transform = new_transform
			print("Synched global_transform (Snap)")
			
		received_dic.erase("global_transform")
		
	# --------------- RECEIVE VARIABLES ---------------#
	for property in received_dic:
		if property in synch_properties:
			parent.set(property, received_dic[property])
			print("Synched property " + property)
		else:
			push_warning("Received property not in synch_properties: " + property)


func does_own_node() -> bool:
	return NetPeer.current_mode == authority_mode
