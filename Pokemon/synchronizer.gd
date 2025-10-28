extends Node
class_name Synchronizer

enum PROTOCOL {
	UDP,
	TCP
}

@onready var parent : Node = $".."
@export var protocol : PROTOCOL = PROTOCOL.UDP
@export var synch_transform : bool
@export var synch_properties : Array[String]
# --- NEW INTERPOLATION EXPORTS ---
@export var interpolate_transform : bool = true
# 100-150ms is a good starting point for the delay buffer
@export var interpolation_delay_ms : int = 150 
# --- END NEW EXPORTS ---

# This holds the unique, server-assigned integer ID (the NetID).
var network_object_id : int = -1

# --- NEW STATE VARIABLES FOR INTERPOLATION ---
# History buffer: Stores [timestamp_ms, Transform]
var transform_history : Array = [] 
const HISTORY_MAX_SIZE = 10
# --- END NEW STATE ---


func _ready() -> void:
	if NetPeer.current_mode == NetPeer.NetMode.HOST:
		network_object_id = NetPeer.register_synchronizer(self)
	else:
		# Clients only enable the _process loop if interpolation is required
		if interpolate_transform:
			set_process(true)
		pass


func _process(delta):
	# Only run on the Client for interpolated objects
	if NetPeer.current_mode != NetPeer.NetMode.CLIENT or not interpolate_transform:
		return
		
	if transform_history.size() < 2:
		# Need at least two history entries (A and B) to interpolate
		return

	# Calculate the target render time (Current time minus the fixed delay)
	var render_time_ms = Time.get_ticks_msec() - interpolation_delay_ms

	# Remove old frames that are no longer needed
	while transform_history.size() > 2 and transform_history[1][0] < render_time_ms:
		transform_history.pop_front()

	# If we still have at least two points (A and B)
	if transform_history.size() >= 2:
		var transform_A = transform_history[0][1] # Transform at older timestamp
		var time_A = float(transform_history[0][0])
		
		var transform_B = transform_history[1][1] # Transform at newer timestamp
		var time_B = float(transform_history[1][0])
		
		# Calculate the difference and the percentage completed (t)
		var total_time_diff = time_B - time_A
		var current_time_diff = render_time_ms - time_A
		
		# Avoid division by zero and potential time travel issues
		if total_time_diff <= 0.0: return
		
		# t is the interpolation factor (0.0 to 1.0)
		var t = clampf(current_time_diff / total_time_diff, 0.0, 1.0)
		
		# Smoothly apply the interpolated transform
		parent.global_transform = transform_A.interpolate_with(transform_B, t)
		


func send(target_peer: StreamPeerTCP = null):
	# (Send function remains the same)
	if network_object_id == -1: return

	var data_dic : Dictionary
	#------------ SYNCH TRANSFORM ----------#
	if synch_transform and parent.has_method("get_global_transform"):
		data_dic["global_transform"] = parent.global_transform
	
	#------------ SYNCH VARIABLES ----------#
	for property in synch_properties:
		var value = parent.get(property)
		data_dic[property] = value
	
	var binary_data : PackedByteArray = var_to_bytes(data_dic)
	
	NetPeer.send_synchronization_data(binary_data, network_object_id, target_peer, protocol)


func receive(received_data: PackedByteArray):
	var received_dic: Dictionary = bytes_to_var(received_data)
	
	if typeof(received_dic) != TYPE_DICTIONARY:
		push_error("Failed to deserialize received data into a Dictionary.")
		return
		
	# --------------- RECEIVE TRANSFORM ---------------#
	if synch_transform and received_dic.has("global_transform") and parent.has_method("set_global_transform"):
		var new_transform = received_dic["global_transform"]
		
		if NetPeer.current_mode == NetPeer.NetMode.CLIENT and interpolate_transform:
			# --- INTERPOLATION LOGIC (Client-side) ---
			var new_timestamp = Time.get_ticks_msec()
			
			# 1. Add the new keyframe to the history
			transform_history.push_back([new_timestamp, new_transform])
			
			# 2. Limit the size of the history buffer
			while transform_history.size() > HISTORY_MAX_SIZE:
				transform_history.pop_front()
				
			# print("Added frame. Size: ", transform_history.size(), " Latest Time: ", new_timestamp)
			# Do NOT apply the transform directly here; it will be applied in _process
			
		else:
			# --- NO INTERPOLATION (Host or Client not using interpolation) ---
			parent.global_transform = new_transform
			print("Synched global_transform (Snap)")
			
		# Remove it from the dictionary so it doesn't get processed in the loop below
		received_dic.erase("global_transform")
		
	# --------------- RECEIVE VARIABLES ---------------#
	# (This part remains the same)
	for property in received_dic:
		if property in synch_properties:
			parent.set(property, received_dic[property])
			print("Synched property " + property)
		else:
			push_warning("Received property not in synch_properties: " + property)
